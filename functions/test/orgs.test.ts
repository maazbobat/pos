import { beforeEach, describe, expect, it } from "vitest";
import { createLocation, createOrganization, defaultTaxSettings, setLocationStatus } from "../src/handlers/orgs.js";
import { createPairingCode } from "../src/handlers/devices.js";
import { acceptInvite } from "../src/handlers/staff.js";
import { auditActions, caller, db, expectHttpsError, PLATFORM_ADMIN, resetEmulators, seed, u } from "./setup.js";

beforeEach(async () => {
  await resetEmulators();
  await seed();
});

const newOrg = { name: "Harbour Grill", type: "independent", ownerEmail: "Owner@Harbour.example", ownerName: "Pat" };
const loc = { orgId: "org-a", name: "Waterloo", province: "ON", timezone: "America/Toronto" };

describe("createOrganization", () => {
  it("is for platform admins only", async () => {
    await expectHttpsError(createOrganization(caller(u.ownerA), newOrg), "permission-denied");
    await expectHttpsError(createOrganization(caller(null), newOrg), "unauthenticated");
  });

  it("creates an active org and an owner invite the owner can accept", async () => {
    const { orgId, ownerInvite } = await createOrganization(caller(PLATFORM_ADMIN), newOrg);
    expect((await db().doc(`orgs/${orgId}`).get()).data()).toMatchObject({
      name: "Harbour Grill", type: "independent", status: "active", accessLevel: "full", plan: "trial",
    });
    expect((await db().doc(`orgs/${orgId}/billing/subscription`).get()).get("status")).toBe("trialing");
    // The platform admin gets no membership.
    expect((await db().doc(`orgs/${orgId}/members/${PLATFORM_ADMIN}`).get()).exists).toBe(false);

    await acceptInvite({ uid: "pat", email: "owner@harbour.example" }, { orgId, ...ownerInvite });
    expect((await db().doc(`orgs/${orgId}/members/pat`).get()).get("orgRole")).toBe("owner");
    expect(await auditActions(orgId)).toEqual(["org.created", "staff.invited", "staff.joined"]);
  });
});

describe("createLocation", () => {
  it("lets the owner add a location with starting tax settings", async () => {
    const { locationId } = await createLocation(caller(u.ownerA), loc);
    expect((await db().doc(`orgs/org-a/locations/${locationId}`).get()).data()).toMatchObject({
      orgId: "org-a", locationId, name: "Waterloo", status: "active",
    });
    expect((await db().doc(`orgs/org-a/locations/${locationId}/settings/tax`).get()).data()).toMatchObject({
      orgId: "org-a", locationId, rates: [{ id: "hst", rate: 0.13 }], reviewed: false,
    });
    expect(await auditActions("org-a")).toEqual(["location.created"]);
  });

  it("is owner only", async () => {
    await expectHttpsError(createLocation(caller(u.franchiseCam), loc), "permission-denied");
    await expectHttpsError(createLocation(caller(u.ownerB), loc), "permission-denied");
  });

  it("validates province and timezone", async () => {
    await expectHttpsError(createLocation(caller(u.ownerA), { ...loc, province: "XX" }), "invalid-argument");
    await expectHttpsError(createLocation(caller(u.ownerA), { ...loc, timezone: "Mars/Base" }), "invalid-argument");
  });

  it("uses GST outside the HST provinces", () => {
    expect(defaultTaxSettings("AB").rates).toEqual([{ id: "gst", name: "GST", rate: 0.05 }]);
    expect(defaultTaxSettings("NS").rates[0]).toMatchObject({ id: "hst", rate: 0.14 });
  });
});

describe("setLocationStatus", () => {
  it("closes a location, which stops new device pairing there", async () => {
    await setLocationStatus(caller(u.ownerA), { orgId: "org-a", locationId: "cambridge", status: "closed" });
    await expectHttpsError(
      createPairingCode(caller(u.ownerA), { orgId: "org-a", locationId: "cambridge", deviceType: "pos", deviceName: "x" }),
      "failed-precondition",
    );
    await setLocationStatus(caller(u.ownerA), { orgId: "org-a", locationId: "cambridge", status: "active" });
    expect(await auditActions("org-a")).toEqual(["location.closed", "location.reopened"]);
  });

  it("is owner only", async () => {
    await expectHttpsError(
      setLocationStatus(caller(u.managerCam), { orgId: "org-a", locationId: "cambridge", status: "closed" }),
      "permission-denied",
    );
  });
});
