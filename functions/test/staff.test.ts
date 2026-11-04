import { Timestamp } from "firebase-admin/firestore";
import { beforeEach, describe, expect, it } from "vitest";
import { acceptInvite, inviteStaff, revokeInvite, setMemberRole, setOwner } from "../src/handlers/staff.js";
import { auditActions, caller, db, email, expectHttpsError, resetEmulators, seed, setOrg, u } from "./setup.js";

const NEW = "new-person";
const invite = (by: string, role: string, locationId: string | null = "cambridge", to = NEW) =>
  inviteStaff(caller(by), { orgId: "org-a", locationId, role, email: email(to).toUpperCase(), displayName: "Sam" });
const accept = (uid: string, inv: { inviteId: string; token: string }) =>
  acceptInvite(caller(uid), { orgId: "org-a", inviteId: inv.inviteId, token: inv.token });

beforeEach(async () => {
  await resetEmulators();
  await seed();
});

describe("who can invite whom", () => {
  const cases: [string, string, boolean][] = [
    [u.managerCam, "cashier", true],
    [u.managerCam, "kitchen", true],
    [u.managerCam, "inventory_manager", true],
    [u.managerCam, "accountant", false],
    [u.managerCam, "store_manager", false],
    [u.managerCam, "franchise_owner", false],
    [u.franchiseCam, "store_manager", true],
    [u.franchiseCam, "accountant", true],
    [u.franchiseCam, "franchise_owner", false],
    [u.ownerA, "franchise_owner", true],
    [u.ownerA, "store_manager", true],
    [u.cashierCam, "cashier", false],
    [u.kitchenCam, "kitchen", false],
    [u.managerTor, "cashier", false],
    [u.ownerB, "cashier", false],
  ];
  for (const [by, role, ok] of cases) {
    it(`${by} ${ok ? "can" : "can't"} invite a ${role} at Cambridge`, async () => {
      if (ok) await invite(by, role);
      else await expectHttpsError(invite(by, role), "permission-denied");
    });
  }

  it("only owners invite owners", async () => {
    await invite(u.ownerA, "owner", null);
    await expectHttpsError(invite(u.franchiseCam, "owner", null), "permission-denied");
  });

  it("devices are paired, never invited", async () => {
    await expectHttpsError(invite(u.ownerA, "device"), "invalid-argument");
  });

  it("refuses read-only orgs", async () => {
    await setOrg("org-a", { accessLevel: "read_only" });
    await expectHttpsError(invite(u.ownerA, "cashier"), "failed-precondition");
  });
});

describe("acceptInvite", () => {
  it("creates the membership, staff entry and org list entry", async () => {
    const inv = await invite(u.managerCam, "cashier");
    expect(await accept(NEW, inv)).toEqual({ orgId: "org-a", locationId: "cambridge", role: "cashier" });

    expect((await db().doc(`orgs/org-a/members/${NEW}`).get()).data()).toMatchObject({
      kind: "user", status: "active", orgRole: null, locationRoles: { cambridge: "cashier" },
      roles: ["cashier"], displayName: "Sam", email: email(NEW),
    });
    expect((await db().doc(`orgs/org-a/locations/cambridge/staff/${NEW}`).get()).get("role")).toBe("cashier");
    expect((await db().doc(`users/${NEW}`).get()).get("orgIds")).toEqual(["org-a"]);
    expect((await db().doc(`orgs/org-a/invites/${inv.inviteId}`).get()).get("status")).toBe("accepted");
    expect(await auditActions("org-a")).toEqual(["staff.invited", "staff.joined"]);
  });

  it("adds a second location to an existing membership", async () => {
    await accept(NEW, await invite(u.managerCam, "cashier"));
    await accept(NEW, await invite(u.ownerA, "store_manager", "toronto"));
    const member = (await db().doc(`orgs/org-a/members/${NEW}`).get()).data();
    expect(member?.locationRoles).toEqual({ cambridge: "cashier", toronto: "store_manager" });
    expect(member?.roles).toEqual(["cashier", "store_manager"]);
  });

  it("makes an owner from an owner invite", async () => {
    await accept(NEW, await invite(u.ownerA, "owner", null));
    expect((await db().doc(`orgs/org-a/members/${NEW}`).get()).get("orgRole")).toBe("owner");
  });

  it("needs the matching email, the right token and an unexpired, unused invite", async () => {
    const inv = await invite(u.managerCam, "cashier");
    await expectHttpsError(accept("someone-else", inv), "permission-denied");
    await expectHttpsError(accept(NEW, { ...inv, token: "wrong" }), "not-found");
    await expectHttpsError(acceptInvite(caller(null), { orgId: "org-a", ...inv }), "unauthenticated");

    await db().doc(`orgs/org-a/invites/${inv.inviteId}`).update({ expiresAt: Timestamp.fromMillis(Date.now() - 1) });
    await expectHttpsError(accept(NEW, inv), "failed-precondition");

    const fresh = await invite(u.managerCam, "cashier");
    await accept(NEW, fresh);
    await expectHttpsError(accept(NEW, fresh), "not-found");
  });

  it("can't be used against another org", async () => {
    const inv = await invite(u.managerCam, "cashier");
    await expectHttpsError(acceptInvite(caller(NEW), { orgId: "org-b", ...inv }), "not-found");
  });

  it("stores only a hash of the token", async () => {
    const inv = await invite(u.managerCam, "cashier");
    const stored = (await db().doc(`orgs/org-a/invites/${inv.inviteId}`).get()).data();
    expect(JSON.stringify(stored)).not.toContain(inv.token);
    expect(stored?.email).toBe(email(NEW));
  });
});

describe("revokeInvite", () => {
  it("stops the invite from being accepted", async () => {
    const inv = await invite(u.managerCam, "cashier");
    await revokeInvite(caller(u.managerCam), { orgId: "org-a", inviteId: inv.inviteId });
    await expectHttpsError(accept(NEW, inv), "not-found");
  });

  it("follows the same role limits as inviting", async () => {
    const inv = await invite(u.franchiseCam, "store_manager");
    await expectHttpsError(
      revokeInvite(caller(u.managerCam), { orgId: "org-a", inviteId: inv.inviteId }),
      "permission-denied",
    );
  });
});

describe("setMemberRole", () => {
  const change = (by: string, uid: string, role: string | null, locationId = "cambridge") =>
    setMemberRole(caller(by), { orgId: "org-a", locationId, uid, role });

  it("lets a manager move a cashier to the kitchen", async () => {
    await change(u.managerCam, u.cashierCam, "kitchen");
    expect((await db().doc(`orgs/org-a/members/${u.cashierCam}`).get()).get("roles")).toEqual(["kitchen"]);
    expect((await db().doc(`orgs/org-a/locations/cambridge/staff/${u.cashierCam}`).get()).get("role")).toBe("kitchen");
    expect(await auditActions("org-a")).toEqual(["staff.role_changed"]);
  });

  it("won't let a manager promote anyone to manager or touch another manager", async () => {
    await expectHttpsError(change(u.managerCam, u.cashierCam, "store_manager"), "permission-denied");
    await expectHttpsError(change(u.managerCam, u.franchiseCam, "cashier"), "permission-denied");
    await expectHttpsError(change(u.managerTor, u.cashierCam, "kitchen"), "permission-denied");
    await expectHttpsError(change(u.managerTor, u.cashierCam, null), "permission-denied");
  });

  it("won't let anyone change their own access", async () => {
    await expectHttpsError(change(u.managerCam, u.managerCam, "franchise_owner"), "permission-denied");
    await expectHttpsError(change(u.ownerA, u.ownerA, null), "permission-denied");
  });

  it("removes the person from the org when their last role goes", async () => {
    await change(u.managerCam, u.cashierCam, null);
    expect((await db().doc(`orgs/org-a/members/${u.cashierCam}`).get()).exists).toBe(false);
    expect((await db().doc(`orgs/org-a/locations/cambridge/staff/${u.cashierCam}`).get()).exists).toBe(false);
    expect(await auditActions("org-a")).toEqual(["staff.removed"]);
  });

  it("allows removal but not new grants on a read-only org", async () => {
    await setOrg("org-a", { accessLevel: "read_only" });
    await expectHttpsError(change(u.ownerA, u.cashierCam, "kitchen"), "failed-precondition");
    await change(u.ownerA, u.cashierCam, null);
  });

  it("leaves owners to setOwner", async () => {
    await expectHttpsError(change(u.ownerA, u.ownerB, "cashier"), "not-found");
    await accept(NEW, await invite(u.ownerA, "owner", null));
    await expectHttpsError(change(u.ownerA, NEW, "cashier"), "permission-denied");
  });
});

describe("setOwner", () => {
  it("is for owners only, never on yourself", async () => {
    await setOwner(caller(u.ownerA), { orgId: "org-a", uid: u.managerCam, owner: true });
    const m = (await db().doc(`orgs/org-a/members/${u.managerCam}`).get()).data();
    expect(m?.orgRole).toBe("owner");
    expect(m?.roles).toEqual(["owner", "store_manager"]);

    await expectHttpsError(setOwner(caller(u.franchiseCam), { orgId: "org-a", uid: u.cashierCam, owner: true }), "permission-denied");
    await expectHttpsError(setOwner(caller(u.ownerA), { orgId: "org-a", uid: u.ownerA, owner: false }), "permission-denied");
    await setOwner(caller(u.managerCam), { orgId: "org-a", uid: u.ownerA, owner: false });
    expect((await db().doc(`orgs/org-a/members/${u.ownerA}`).get()).exists).toBe(false);
  });
});
