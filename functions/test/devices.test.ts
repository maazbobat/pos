import { Timestamp } from "firebase-admin/firestore";
import { getAuth } from "firebase-admin/auth";
import { beforeEach, describe, expect, it } from "vitest";
import { createPairingCode, redeemPairingCode, revokeDevice } from "../src/handlers/devices.js";
import { sha256 } from "../src/lib/ids.js";
import {
  auditActions, caller, db, expectHttpsError, resetEmulators, seed, setOrg, signInWithCustomToken, u,
} from "./setup.js";

const cam = { orgId: "org-a", locationId: "cambridge" };
const newCode = (uid = u.managerCam, loc = cam) =>
  createPairingCode(caller(uid), { ...loc, deviceType: "pos", deviceName: "Front counter" });

beforeEach(async () => {
  await resetEmulators();
  await seed();
});

describe("createPairingCode", () => {
  it("lets each manager role create a code for their location", async () => {
    for (const uid of [u.ownerA, u.franchiseCam, u.managerCam]) {
      const { code, expiresAt } = await newCode(uid);
      expect(code).toMatch(/^[2-9A-Z]{4}-[2-9A-Z]{4}$/);
      expect(Date.parse(expiresAt)).toBeGreaterThan(Date.now());
    }
  });

  it("stores only a hash of the code", async () => {
    const { code } = await newCode();
    const raw = code.replace("-", "");
    expect((await db().doc(`pairingCodes/${raw}`).get()).exists).toBe(false);
    const stored = await db().doc(`pairingCodes/${sha256(raw)}`).get();
    expect(stored.data()).toMatchObject({ ...cam, status: "pending", createdBy: u.managerCam });
  });

  it("denies non-managers, other locations, other orgs and signed-out callers", async () => {
    await expectHttpsError(newCode(u.cashierCam), "permission-denied");
    await expectHttpsError(newCode(u.kitchenCam), "permission-denied");
    await expectHttpsError(newCode(u.managerTor), "permission-denied");
    await expectHttpsError(newCode(u.ownerB), "permission-denied");
    await expectHttpsError(
      createPairingCode(caller(null), { ...cam, deviceType: "pos", deviceName: "x" }),
      "unauthenticated",
    );
  });

  it("refuses read-only orgs and closed locations", async () => {
    await setOrg("org-a", { accessLevel: "read_only" });
    await expectHttpsError(newCode(), "failed-precondition");
    await setOrg("org-a", { accessLevel: "full" });
    await db().doc("orgs/org-a/locations/cambridge").update({ status: "closed" });
    await expectHttpsError(newCode(u.ownerA), "failed-precondition");
  });

  it("validates input", async () => {
    await expectHttpsError(
      createPairingCode(caller(u.managerCam), { ...cam, deviceType: "toaster", deviceName: "x" }),
      "invalid-argument",
    );
    await expectHttpsError(
      createPairingCode(caller(u.managerCam), { orgId: "org-a/../org-b", locationId: "cambridge", deviceType: "pos", deviceName: "x" }),
      "invalid-argument",
    );
  });
});

describe("redeemPairingCode", () => {
  it("creates a device member at that one location and a token that signs in", async () => {
    const { code } = await newCode();
    const res = await redeemPairingCode(caller(null), { code: code.toLowerCase(), appVersion: "0.2.0" });
    expect(res).toMatchObject({ ...cam, deviceType: "pos" });

    const member = (await db().doc(`orgs/org-a/members/${res.deviceId}`).get()).data();
    expect(member).toMatchObject({
      kind: "device", status: "active", orgRole: null, locationRoles: { cambridge: "device" }, roles: ["device"],
    });
    const device = (await db().doc(`orgs/org-a/locations/cambridge/devices/${res.deviceId}`).get()).data();
    expect(device).toMatchObject({ ...cam, type: "pos", status: "active", name: "Front counter", appVersion: "0.2.0" });
    expect((await db().doc(`users/${res.deviceId}`).get()).get("orgIds")).toEqual(["org-a"]);

    const signIn = await signInWithCustomToken(res.customToken);
    expect(signIn.localId).toBe(res.deviceId);
    expect(await auditActions("org-a")).toEqual(["device.paired", "device.pairing_code_created"]);
  });

  it("is single use", async () => {
    const { code } = await newCode();
    await redeemPairingCode(caller(null), { code });
    await expectHttpsError(redeemPairingCode(caller(null), { code }), "not-found");
  });

  it("rejects unknown, malformed and expired codes without leaving an account behind", async () => {
    await expectHttpsError(redeemPairingCode(caller(null), { code: "ABCD-EFGH" }), "not-found");
    await expectHttpsError(redeemPairingCode(caller(null), { code: "0000-1111" }), "invalid-argument");

    const { code } = await newCode();
    await db().doc(`pairingCodes/${sha256(code.replace("-", ""))}`).update({ expiresAt: Timestamp.fromMillis(Date.now() - 1000) });
    await expectHttpsError(redeemPairingCode(caller(null), { code }), "failed-precondition");
    const users = await getAuth().listUsers();
    expect(users.users).toHaveLength(0);
  });

  it("rejects a code once the org is suspended", async () => {
    const { code } = await newCode();
    await setOrg("org-a", { status: "suspended" });
    await expectHttpsError(redeemPairingCode(caller(null), { code }), "failed-precondition");
  });
});

describe("revokeDevice", () => {
  async function pair() {
    const { code } = await newCode();
    return redeemPairingCode(caller(null), { code });
  }

  it("suspends the membership and disables the account", async () => {
    const { deviceId, customToken } = await pair();
    await revokeDevice(caller(u.managerCam), { ...cam, deviceId });

    expect((await db().doc(`orgs/org-a/members/${deviceId}`).get()).get("status")).toBe("suspended");
    expect((await db().doc(`orgs/org-a/locations/cambridge/devices/${deviceId}`).get()).get("status")).toBe("revoked");
    expect((await getAuth().getUser(deviceId)).disabled).toBe(true);
    expect((await signInWithCustomToken(customToken)).localId).toBeUndefined();
    expect(await auditActions("org-a")).toContain("device.revoked");
  });

  it("works on a read-only org, since removing access is always allowed", async () => {
    const { deviceId } = await pair();
    await setOrg("org-a", { accessLevel: "read_only" });
    await revokeDevice(caller(u.managerCam), { ...cam, deviceId });
  });

  it("denies cashiers, other locations and other orgs", async () => {
    const { deviceId } = await pair();
    await expectHttpsError(revokeDevice(caller(u.cashierCam), { ...cam, deviceId }), "permission-denied");
    await expectHttpsError(revokeDevice(caller(u.managerTor), { ...cam, deviceId }), "permission-denied");
    // A Toronto manager naming their own location can't reach a Cambridge device either.
    await expectHttpsError(
      revokeDevice(caller(u.managerTor), { orgId: "org-a", locationId: "toronto", deviceId }),
      "not-found",
    );
    await expectHttpsError(revokeDevice(caller(u.ownerB), { ...cam, deviceId }), "permission-denied");
  });

  it("won't revoke a person", async () => {
    await expectHttpsError(revokeDevice(caller(u.ownerA), { ...cam, deviceId: u.cashierCam }), "not-found");
  });
});
