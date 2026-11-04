/**
 * Staff PINs for switching users on a paired device.
 *
 * The tablet is signed in as the device. A staff member types only their
 * PIN; the device sends it here and gets back who they are, if they hold a
 * role at the device's location. PINs are unique within an org so a PIN
 * alone identifies one person, and they're stored as an HMAC keyed by the
 * PIN_PEPPER secret (see lib/ids.ts). Repeated wrong PINs lock the device's
 * PIN pad for a few minutes.
 *
 * resolveStaffPin is also what voids and refunds will use to check a
 * manager's PIN server-side (roadmap step 3).
 */
import { FieldValue, Timestamp, type Transaction } from "firebase-admin/firestore";
import { fail } from "../lib/errors.js";
import { db } from "../lib/firebase.js";
import { pinKey } from "../lib/ids.js";
import type { Role } from "../lib/roles.js";
import {
  type Caller,
  getMember,
  paths,
  requireActiveLocation,
  requireActiveMember,
  requireUid,
  roleAt,
} from "../lib/tenant.js";
import { asInput, docId, str } from "../lib/validate.js";

export const MAX_PIN_FAILURES = 5;
export const PIN_LOCKOUT_MS = 5 * 60 * 1000;

/** 4 to 8 digits, not all the same digit and not a straight run like 1234. */
export function checkPinStrength(pin: string): void {
  if (!/^\d{4,8}$/.test(pin)) throw fail.invalid("A PIN is 4 to 8 digits.");
  const digits = [...pin].map(Number);
  const steps = new Set(digits.slice(1).map((d, i) => d - digits[i]));
  if (steps.size === 1 && [0, 1, -1].includes([...steps][0])) {
    throw fail.invalid("That PIN is too easy to guess.");
  }
}

/** Sets or replaces the caller's own PIN for one org. */
export async function setStaffPin(caller: Caller, data: unknown, pepper: string): Promise<{ ok: true }> {
  const uid = requireUid(caller);
  const input = asInput(data);
  const orgId = docId(input, "orgId");
  const pin = str(input, "pin", { min: 4, max: 8 });
  checkPinStrength(pin);
  const key = pinKey(pepper, orgId, pin);

  await db().runTransaction(async (tx) => {
    const member = await requireActiveMember(tx, orgId, uid);
    if (member.kind !== "user") throw fail.denied();
    const indexRef = db().doc(paths.pinIndex(orgId, key));
    const secretRef = db().doc(paths.memberSecret(orgId, uid));
    const [index, secret] = await Promise.all([tx.get(indexRef), tx.get(secretRef)]);
    if (index.exists && index.get("uid") !== uid) {
      throw fail.conflict("Someone else here already uses that PIN. Pick another.");
    }
    const oldKey = secret.get("pinKey") as string | undefined;
    if (oldKey && oldKey !== key) tx.delete(db().doc(paths.pinIndex(orgId, oldKey)));
    const now = FieldValue.serverTimestamp();
    tx.set(indexRef, { uid, updatedAt: now });
    tx.set(secretRef, { pinKey: key, updatedAt: now });
    tx.update(db().doc(paths.member(orgId, uid)), { pinSetAt: now });
  });
  return { ok: true };
}

export interface StaffAtLocation {
  uid: string;
  displayName: string | null;
  role: Role;
}

/** The active person with this PIN and a role at the location, or null. */
export async function resolveStaffPin(
  tx: Transaction,
  orgId: string,
  locationId: string,
  pin: string,
  pepper: string,
): Promise<StaffAtLocation | null> {
  if (!/^\d{4,8}$/.test(pin)) return null;
  const index = await tx.get(db().doc(paths.pinIndex(orgId, pinKey(pepper, orgId, pin))));
  if (!index.exists) return null;
  const staff = await getMember(tx, orgId, index.get("uid") as string);
  if (!staff || staff.kind !== "user") return null;
  const role = roleAt(staff, locationId);
  if (!role) return null;
  return { uid: staff.uid, displayName: staff.displayName ?? null, role };
}

/** Called by a paired device when someone types their PIN. */
export async function startStaffSession(
  caller: Caller,
  data: unknown,
  pepper: string,
): Promise<StaffAtLocation> {
  const deviceId = requireUid(caller);
  const input = asInput(data);
  const orgId = docId(input, "orgId");
  const pin = typeof input.pin === "string" ? input.pin : "";

  const outcome = await db().runTransaction(async (tx) => {
    const device = await requireActiveMember(tx, orgId, deviceId);
    const locations = Object.keys(device.locationRoles);
    if (device.kind !== "device" || locations.length !== 1) throw fail.denied();
    const locationId = locations[0];
    await requireActiveLocation(tx, orgId, locationId);

    const guardRef = db().doc(paths.pinGuard(orgId, locationId, deviceId));
    const guard = await tx.get(guardRef);
    const lockedUntil = guard.get("lockedUntil") as Timestamp | undefined;
    if (lockedUntil && lockedUntil.toMillis() > Date.now()) {
      return { locked: true as const };
    }

    const staff = await resolveStaffPin(tx, orgId, locationId, pin, pepper);
    if (!staff) {
      const failures = ((guard.get("failures") as number | undefined) ?? 0) + 1;
      const lock = failures >= MAX_PIN_FAILURES;
      tx.set(guardRef, {
        failures: lock ? 0 : failures,
        lockedUntil: lock ? Timestamp.fromMillis(Date.now() + PIN_LOCKOUT_MS) : null,
        updatedAt: FieldValue.serverTimestamp(),
      });
      return { wrong: true as const };
    }
    if (guard.exists) tx.delete(guardRef);
    tx.update(db().doc(paths.device(orgId, locationId, deviceId)), {
      currentStaffUid: staff.uid,
      staffSince: FieldValue.serverTimestamp(),
    });
    return { staff };
  });

  // Throwing inside the transaction would roll back the failure count.
  if ("locked" in outcome) throw fail.exhausted("Too many wrong PINs. Try again in a few minutes.");
  if ("wrong" in outcome) throw fail.denied("That PIN didn't match anyone at this location.");
  return outcome.staff;
}
