import { getApps, initializeApp } from "firebase-admin/app";
import { getFirestore, Timestamp } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";
import { expect } from "vitest";
import { membershipData } from "../src/lib/tenant.js";
import type { Role } from "../src/lib/roles.js";

// A demo- project ID keeps the emulators from reaching any real project.
export const PROJECT_ID = "demo-pos";
export const PEPPER = "test-pepper";

if (!process.env.FIRESTORE_EMULATOR_HOST || !process.env.FIREBASE_AUTH_EMULATOR_HOST) {
  throw new Error("Run through `npm run test:functions` so the emulators are up.");
}
if (getApps().length === 0) initializeApp({ projectId: PROJECT_ID });

export const db = () => getFirestore();

export async function resetEmulators(): Promise<void> {
  const fs = process.env.FIRESTORE_EMULATOR_HOST;
  const au = process.env.FIREBASE_AUTH_EMULATOR_HOST;
  await Promise.all([
    fetch(`http://${fs}/emulator/v1/projects/${PROJECT_ID}/databases/(default)/documents`, { method: "DELETE" }),
    fetch(`http://${au}/emulator/v1/projects/${PROJECT_ID}/accounts`, { method: "DELETE" }),
  ]);
}

/** Exchanges a custom token for an ID token, as the tablet's sign-in would. */
export async function signInWithCustomToken(token: string): Promise<{ localId?: string; error?: unknown }> {
  const au = process.env.FIREBASE_AUTH_EMULATOR_HOST;
  const res = await fetch(
    `http://${au}/identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=fake`,
    { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ token, returnSecureToken: true }) },
  );
  const body = (await res.json()) as { idToken?: string; error?: unknown };
  if (!body.idToken) return { error: body.error };
  const lookup = await fetch(`http://${au}/identitytoolkit.googleapis.com/v1/accounts:lookup?key=fake`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ idToken: body.idToken }),
  });
  const users = (await lookup.json()) as { users?: { localId: string }[]; error?: unknown };
  return users.users ? { localId: users.users[0].localId } : { error: users.error };
}

export async function expectHttpsError(promise: Promise<unknown>, code: HttpsError["code"]): Promise<void> {
  const err = await promise.then(
    () => null,
    (e: unknown) => e,
  );
  expect(err, `expected ${code}`).toBeInstanceOf(HttpsError);
  expect((err as HttpsError).code).toBe(code);
}

export const PLATFORM_ADMIN = "platform-admin";
export const u = {
  ownerA: "a-owner",
  franchiseCam: "a-cam-franchise",
  managerCam: "a-cam-manager",
  cashierCam: "a-cam-cashier",
  kitchenCam: "a-cam-kitchen",
  managerTor: "a-tor-manager",
  ownerB: "b-owner",
};
export const email = (uid: string) => `${uid}@example.com`;
export const caller = (uid: string | null) => ({ uid, email: uid ? email(uid) : null });

const past = Timestamp.fromMillis(Date.UTC(2026, 0, 1));

/**
 * Org A (Cambridge, Toronto) and Org B (Halifax), with an owner and a
 * handful of location roles. The rules suite covers every role in depth;
 * these tests are about the Functions' own permission checks.
 */
export async function seed(): Promise<void> {
  const batch = db().batch();
  const set = (path: string, data: Record<string, unknown>) => batch.set(db().doc(path), data);
  const member = (orgId: string, uid: string, orgRole: "owner" | null, locationRoles: Record<string, Role>) =>
    set(`orgs/${orgId}/members/${uid}`, membershipData(orgId, uid, {
      kind: "user", orgRole, locationRoles, displayName: uid, email: email(uid),
    }));

  set(`platformAdmins/${PLATFORM_ADMIN}`, { createdAt: past });
  for (const [orgId, locs] of [["org-a", ["cambridge", "toronto"]], ["org-b", ["halifax"]]] as const) {
    set(`orgs/${orgId}`, { name: orgId, type: "franchise", status: "active", accessLevel: "full", plan: "professional" });
    for (const locId of locs) {
      set(`orgs/${orgId}/locations/${locId}`, {
        orgId, locationId: locId, name: locId, status: "active", timezone: "America/Toronto", province: "ON",
      });
    }
  }
  member("org-a", u.ownerA, "owner", {});
  member("org-a", u.franchiseCam, null, { cambridge: "franchise_owner" });
  member("org-a", u.managerCam, null, { cambridge: "store_manager" });
  member("org-a", u.cashierCam, null, { cambridge: "cashier" });
  member("org-a", u.kitchenCam, null, { cambridge: "kitchen" });
  member("org-a", u.managerTor, null, { toronto: "store_manager" });
  member("org-b", u.ownerB, "owner", {});
  await batch.commit();
}

export async function setOrg(orgId: string, fields: Record<string, unknown>): Promise<void> {
  await db().doc(`orgs/${orgId}`).update(fields);
}

export async function auditActions(orgId: string): Promise<string[]> {
  const snap = await db().collection(`orgs/${orgId}/auditLog`).get();
  return snap.docs.map((d) => d.get("action") as string).sort();
}
