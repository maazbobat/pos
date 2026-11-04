/**
 * Device pairing and revocation.
 *
 * A manager creates a short-lived pairing code for one location. The tablet
 * (signed out) redeems it and gets a custom token for a new auth account
 * whose uid is the device ID. That account is a member of the org with the
 * `device` role at exactly that location, so the existing rules decide what
 * it can touch. Revoking suspends the membership and disables the account.
 */
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { audit } from "../lib/audit.js";
import { fail } from "../lib/errors.js";
import { auth, db } from "../lib/firebase.js";
import {
  formatPairingCode,
  isPairingCode,
  newDeviceId,
  newPairingCode,
  normalizePairingCode,
  sha256,
} from "../lib/ids.js";
import { isManager } from "../lib/roles.js";
import {
  type Caller,
  membershipData,
  paths,
  requireActiveLocation,
  requireActiveMember,
  requireUid,
  requireWritableOrg,
  roleAt,
} from "../lib/tenant.js";
import { asInput, docId, oneOf, optStr, str } from "../lib/validate.js";

export const DEVICE_TYPES = ["pos", "kds"] as const;
export type DeviceType = (typeof DEVICE_TYPES)[number];

export const PAIRING_CODE_TTL_MS = 15 * 60 * 1000;

export interface CreatePairingCodeResult {
  code: string;
  expiresAt: string;
}

export async function createPairingCode(caller: Caller, data: unknown): Promise<CreatePairingCodeResult> {
  const uid = requireUid(caller);
  const input = asInput(data);
  const orgId = docId(input, "orgId");
  const locationId = docId(input, "locationId");
  const deviceType = oneOf(input, "deviceType", DEVICE_TYPES);
  const deviceName = str(input, "deviceName", { max: 60 });

  const code = newPairingCode();
  const expiresAt = Timestamp.fromMillis(Date.now() + PAIRING_CODE_TTL_MS);

  await db().runTransaction(async (tx) => {
    const member = await requireActiveMember(tx, orgId, uid);
    await requireWritableOrg(tx, orgId);
    await requireActiveLocation(tx, orgId, locationId);
    if (!isManager(roleAt(member, locationId))) throw fail.denied();

    tx.create(db().doc(paths.pairingCode(sha256(code))), {
      orgId,
      locationId,
      deviceType,
      deviceName,
      status: "pending",
      createdBy: uid,
      createdAt: FieldValue.serverTimestamp(),
      expiresAt,
    });
    audit(tx, orgId, {
      action: "device.pairing_code_created",
      actorUid: uid,
      locationId,
      target: { deviceType, deviceName },
    });
  });

  return { code: formatPairingCode(code), expiresAt: expiresAt.toDate().toISOString() };
}

export interface RedeemPairingCodeResult {
  customToken: string;
  orgId: string;
  locationId: string;
  deviceId: string;
  deviceType: DeviceType;
}

/** Called by a signed-out tablet. The code is the only credential. */
export async function redeemPairingCode(_caller: Caller, data: unknown): Promise<RedeemPairingCodeResult> {
  const input = asInput(data);
  const code = normalizePairingCode(str(input, "code", { max: 20 }));
  const appVersion = optStr(input, "appVersion", { max: 40 });
  const platform = optStr(input, "platform", { max: 40 });
  if (!isPairingCode(code)) throw fail.invalid("That pairing code isn't valid.");

  const deviceId = newDeviceId();
  const codeRef = db().doc(paths.pairingCode(sha256(code)));

  // The auth account exists before the membership so revocation always has
  // an account to disable. If the transaction fails it is deleted again.
  await auth().createUser({ uid: deviceId });

  let result: Omit<RedeemPairingCodeResult, "customToken">;
  try {
    result = await db().runTransaction(async (tx) => {
      const snap = await tx.get(codeRef);
      const pairing = snap.data();
      if (!snap.exists || !pairing || pairing.status !== "pending") {
        throw fail.notFound("That pairing code isn't valid.");
      }
      if ((pairing.expiresAt as Timestamp).toMillis() < Date.now()) {
        throw fail.precondition("That pairing code has expired. Ask a manager for a new one.");
      }
      const { orgId, locationId, deviceType, deviceName } = pairing as {
        orgId: string;
        locationId: string;
        deviceType: DeviceType;
        deviceName: string;
      };
      await requireWritableOrg(tx, orgId);
      await requireActiveLocation(tx, orgId, locationId);

      const now = FieldValue.serverTimestamp();
      tx.update(codeRef, { status: "redeemed", deviceId, redeemedAt: now });
      tx.set(
        db().doc(paths.member(orgId, deviceId)),
        membershipData(orgId, deviceId, {
          kind: "device",
          orgRole: null,
          locationRoles: { [locationId]: "device" },
          displayName: deviceName,
        }),
      );
      tx.set(db().doc(paths.device(orgId, locationId, deviceId)), {
        orgId,
        locationId,
        deviceId,
        type: deviceType,
        name: deviceName,
        status: "active",
        appVersion,
        platform,
        pairedBy: pairing.createdBy,
        pairedAt: now,
        lastSeenAt: now,
      });
      tx.set(db().doc(paths.user(deviceId)), { kind: "device", orgIds: [orgId], createdAt: now });
      audit(tx, orgId, {
        action: "device.paired",
        actorUid: pairing.createdBy as string,
        locationId,
        target: { deviceId, deviceType, deviceName },
      });
      return { orgId, locationId, deviceId, deviceType };
    });
  } catch (err) {
    await auth().deleteUser(deviceId).catch(() => undefined);
    throw err;
  }

  const customToken = await auth().createCustomToken(deviceId);
  return { ...result, customToken };
}

export async function revokeDevice(caller: Caller, data: unknown): Promise<{ revoked: true }> {
  const uid = requireUid(caller);
  const input = asInput(data);
  const orgId = docId(input, "orgId");
  const locationId = docId(input, "locationId");
  const deviceId = docId(input, "deviceId");

  await db().runTransaction(async (tx) => {
    const member = await requireActiveMember(tx, orgId, uid);
    if (!isManager(roleAt(member, locationId))) throw fail.denied();
    // Revoking works on a read-only org: removing access is always allowed.
    const deviceRef = db().doc(paths.device(orgId, locationId, deviceId));
    const memberRef = db().doc(paths.member(orgId, deviceId));
    const [deviceSnap, deviceMemberSnap] = await Promise.all([tx.get(deviceRef), tx.get(memberRef)]);
    if (!deviceSnap.exists || deviceMemberSnap.get("kind") !== "device") {
      throw fail.notFound("Device not found.");
    }
    const now = FieldValue.serverTimestamp();
    tx.update(memberRef, { status: "suspended", updatedAt: now });
    tx.update(deviceRef, { status: "revoked", revokedBy: uid, revokedAt: now });
    audit(tx, orgId, { action: "device.revoked", actorUid: uid, locationId, target: { deviceId } });
  });

  await auth().updateUser(deviceId, { disabled: true });
  await auth().revokeRefreshTokens(deviceId);
  return { revoked: true };
}
