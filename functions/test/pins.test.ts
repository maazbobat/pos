import { beforeEach, describe, expect, it } from "vitest";
import { createPairingCode, redeemPairingCode, revokeDevice } from "../src/handlers/devices.js";
import { checkPinStrength, MAX_PIN_FAILURES, setStaffPin, startStaffSession } from "../src/handlers/pins.js";
import { caller, db, expectHttpsError, PEPPER, resetEmulators, seed, u } from "./setup.js";

const setPin = (uid: string, pin: string, orgId = "org-a") => setStaffPin(caller(uid), { orgId, pin }, PEPPER);
const start = (deviceId: string, pin: string) =>
  startStaffSession({ uid: deviceId, email: null }, { orgId: "org-a", pin }, PEPPER);

async function pairDevice(locationId = "cambridge") {
  const by = locationId === "cambridge" ? u.managerCam : u.managerTor;
  const { code } = await createPairingCode(caller(by), { orgId: "org-a", locationId, deviceType: "pos", deviceName: "Till" });
  return (await redeemPairingCode(caller(null), { code })).deviceId;
}

beforeEach(async () => {
  await resetEmulators();
  await seed();
});

describe("checkPinStrength", () => {
  it("accepts 4-8 digit PINs that aren't trivial", () => {
    for (const pin of ["2580", "1357", "90210", "48151623"]) expect(() => checkPinStrength(pin)).not.toThrow();
  });
  it("rejects short, long, non-digit, repeated and straight-run PINs", () => {
    for (const pin of ["123", "123456789", "12a4", "0000", "1234", "9876", "456789"]) {
      expect(() => checkPinStrength(pin), pin).toThrow();
    }
  });
});

describe("setStaffPin", () => {
  it("keeps PINs unique within an org but not across orgs", async () => {
    await setPin(u.cashierCam, "2580");
    await expectHttpsError(setPin(u.kitchenCam, "2580"), "already-exists");
    await setPin(u.ownerB, "2580", "org-b");
  });

  it("frees the old PIN when someone changes theirs", async () => {
    await setPin(u.cashierCam, "2580");
    await setPin(u.cashierCam, "1397");
    await setPin(u.kitchenCam, "2580");
  });

  it("stores no PIN in the clear and needs membership", async () => {
    await setPin(u.cashierCam, "2580");
    const index = await db().collection("orgs/org-a/pinIndex").get();
    expect(index.docs.map((d) => d.id).join()).not.toContain("2580");
    await expectHttpsError(setPin(u.ownerB, "4826"), "permission-denied");
    await expectHttpsError(setStaffPin(caller(null), { orgId: "org-a", pin: "4826" }, PEPPER), "unauthenticated");
  });

  it("isn't available to devices", async () => {
    const deviceId = await pairDevice();
    await expectHttpsError(setStaffPin({ uid: deviceId }, { orgId: "org-a", pin: "4826" }, PEPPER), "permission-denied");
  });
});

describe("startStaffSession", () => {
  it("identifies staff who work at the device's location", async () => {
    await setPin(u.cashierCam, "2580");
    await setPin(u.ownerA, "4826");
    const deviceId = await pairDevice();
    expect(await start(deviceId, "2580")).toEqual({ uid: u.cashierCam, displayName: u.cashierCam, role: "cashier" });
    expect(await start(deviceId, "4826")).toMatchObject({ uid: u.ownerA, role: "owner" });
    const device = await db().doc(`orgs/org-a/locations/cambridge/devices/${deviceId}`).get();
    expect(device.get("currentStaffUid")).toBe(u.ownerA);
  });

  it("doesn't let staff from another location in", async () => {
    await setPin(u.managerTor, "2580");
    const deviceId = await pairDevice();
    await expectHttpsError(start(deviceId, "2580"), "permission-denied");
  });

  it(`locks the PIN pad after ${MAX_PIN_FAILURES} wrong PINs`, async () => {
    await setPin(u.cashierCam, "2580");
    const deviceId = await pairDevice();
    for (let i = 0; i < MAX_PIN_FAILURES; i++) await expectHttpsError(start(deviceId, "9999"), "permission-denied");
    await expectHttpsError(start(deviceId, "2580"), "resource-exhausted");
  });

  it("resets the failure count after a correct PIN", async () => {
    await setPin(u.cashierCam, "2580");
    const deviceId = await pairDevice();
    for (let i = 0; i < MAX_PIN_FAILURES - 1; i++) await expectHttpsError(start(deviceId, "9999"), "permission-denied");
    await start(deviceId, "2580");
    await expectHttpsError(start(deviceId, "9999"), "permission-denied");
    await start(deviceId, "2580");
  });

  it("is only for active devices", async () => {
    await setPin(u.cashierCam, "2580");
    await expectHttpsError(start(u.managerCam, "2580"), "permission-denied");
    const deviceId = await pairDevice();
    await revokeDevice(caller(u.managerCam), { orgId: "org-a", locationId: "cambridge", deviceId });
    await expectHttpsError(start(deviceId, "2580"), "permission-denied");
  });

  it("ignores suspended staff", async () => {
    await setPin(u.cashierCam, "2580");
    const deviceId = await pairDevice();
    await db().doc(`orgs/org-a/members/${u.cashierCam}`).update({ status: "suspended" });
    await expectHttpsError(start(deviceId, "2580"), "permission-denied");
  });
});
