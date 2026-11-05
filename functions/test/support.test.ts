import { Timestamp } from "firebase-admin/firestore";
import { beforeEach, describe, expect, it } from "vitest";
import { grantSupportAccess, MAX_SUPPORT_HOURS, revokeSupportAccess, setOrgStatus } from "../src/handlers/support.js";
import { auditActions, caller, db, expectHttpsError, PLATFORM_ADMIN, resetEmulators, seed, u } from "./setup.js";

beforeEach(async () => {
  await resetEmulators();
  await seed();
});

const grantPath = `orgs/org-a/supportGrants/${PLATFORM_ADMIN}`;
const platformActions = async () =>
  (await db().collection("platformAuditLog").get()).docs.map((d) => d.get("action") as string).sort();

describe("grantSupportAccess", () => {
  it("is platform admin only", async () => {
    const input = { orgId: "org-a", reason: "Ticket 42: menu sync" };
    await expectHttpsError(grantSupportAccess(caller(u.ownerA), input), "permission-denied");
    await expectHttpsError(grantSupportAccess(caller(null), input), "unauthenticated");
  });

  it("needs a reason and is time-boxed", async () => {
    await expectHttpsError(grantSupportAccess(caller(PLATFORM_ADMIN), { orgId: "org-a" }), "invalid-argument");
    await expectHttpsError(
      grantSupportAccess(caller(PLATFORM_ADMIN), { orgId: "org-a", reason: "Ticket 42", hours: MAX_SUPPORT_HOURS + 1 }),
      "invalid-argument",
    );
    await expectHttpsError(grantSupportAccess(caller(PLATFORM_ADMIN), { orgId: "nope", reason: "Ticket 42" }), "not-found");
  });

  it("opens read access with an expiry, audited where the owner can see it and in the platform log", async () => {
    const now = Date.now();
    const { expiresAt } = await grantSupportAccess(caller(PLATFORM_ADMIN), { orgId: "org-a", reason: "Ticket 42", hours: 2 }, now);
    expect(expiresAt).toBe(now + 2 * 60 * 60 * 1000);
    const grant = (await db().doc(grantPath).get()).data()!;
    expect(grant).toMatchObject({ adminUid: PLATFORM_ADMIN, reason: "Ticket 42", access: "read" });
    expect((grant.expiresAt as Timestamp).toMillis()).toBe(expiresAt);

    const orgLog = await db().collection("orgs/org-a/auditLog").get();
    expect(orgLog.docs[0].data()).toMatchObject({
      action: "support.access_granted", actorUid: PLATFORM_ADMIN, actorKind: "platform_admin", reason: "Ticket 42",
    });
    expect(await platformActions()).toEqual(["support.access_granted"]);
  });
});

describe("revokeSupportAccess", () => {
  beforeEach(async () => {
    await grantSupportAccess(caller(PLATFORM_ADMIN), { orgId: "org-a", reason: "Ticket 42" });
  });

  it("lets the owner end a grant early", async () => {
    await revokeSupportAccess(caller(u.ownerA), { orgId: "org-a", adminUid: PLATFORM_ADMIN });
    expect((await db().doc(grantPath).get()).exists).toBe(false);
    expect(await auditActions("org-a")).toEqual(["support.access_granted", "support.access_revoked"]);
  });

  it("lets the admin end their own grant", async () => {
    await revokeSupportAccess(caller(PLATFORM_ADMIN), { orgId: "org-a" });
    expect((await db().doc(grantPath).get()).exists).toBe(false);
    expect(await platformActions()).toEqual(["support.access_granted", "support.access_revoked"]);
  });

  it("is refused to managers and other orgs' owners", async () => {
    await expectHttpsError(revokeSupportAccess(caller(u.managerCam), { orgId: "org-a", adminUid: PLATFORM_ADMIN }), "permission-denied");
    await expectHttpsError(revokeSupportAccess(caller(u.ownerB), { orgId: "org-a", adminUid: PLATFORM_ADMIN }), "permission-denied");
    expect((await db().doc(grantPath).get()).exists).toBe(true);
  });
});

describe("setOrgStatus", () => {
  it("suspends and reactivates with a reason, audited in both logs", async () => {
    await expectHttpsError(setOrgStatus(caller(u.ownerA), { orgId: "org-a", status: "suspended", reason: "Fraud check" }), "permission-denied");
    await expectHttpsError(setOrgStatus(caller(PLATFORM_ADMIN), { orgId: "org-a", status: "suspended" }), "invalid-argument");

    await setOrgStatus(caller(PLATFORM_ADMIN), { orgId: "org-a", status: "suspended", reason: "Fraud check" });
    expect((await db().doc("orgs/org-a").get()).get("status")).toBe("suspended");
    expect((await db().doc("platformOrgs/org-a").get()).get("status")).toBe("suspended");

    await setOrgStatus(caller(PLATFORM_ADMIN), { orgId: "org-a", status: "active", reason: "Cleared" });
    expect(await auditActions("org-a")).toEqual(["org.reactivated", "org.suspended"]);
    expect(await platformActions()).toEqual(["org.reactivated", "org.suspended"]);
  });
});
