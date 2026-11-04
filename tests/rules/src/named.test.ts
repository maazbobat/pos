/**
 * Hand-written cases from the acceptance criteria and the security model,
 * so they read as a spec. The full role-by-operation grid is matrix.test.ts.
 */
import { assertFails, assertSucceeds, type RulesTestEnvironment } from "@firebase/rules-unit-testing";
import {
  collection,
  doc,
  getDoc,
  getDocs,
  query,
  serverTimestamp,
  setDoc,
  Timestamp,
  updateDoc,
  where,
} from "firebase/firestore";
import { afterAll, beforeAll, beforeEach, describe, expect, test } from "vitest";
import { asAdmin, createEnv, dbFor } from "./env.js";
import { cashSession, memberUid, ownerUid, PLATFORM_ADMIN, seed } from "./fixtures.js";

const A = "orgs/org-a";
const CAMBRIDGE = `${A}/locations/cambridge`;
const TORONTO = `${A}/locations/toronto`;
const B = "orgs/org-b";
const HALIFAX = `${B}/locations/halifax`;

let env: RulesTestEnvironment;

beforeAll(async () => {
  env = await createEnv();
});

beforeEach(async () => {
  await env.clearFirestore();
  await asAdmin(env, seed);
});

afterAll(async () => {
  await env?.cleanup();
});

const as = (uid: string | null) => dbFor(env, uid);

const newOrder = (uid: string, loc = "cambridge") => ({
  orgId: "org-a",
  locationId: loc,
  status: "new",
  paymentStatus: "paid",
  items: [{ itemId: "item-1", qty: 1, price: 5.5 }],
  totals: { subtotal: 5.5, tax: 0.72, total: 6.22 },
  discounts: [],
  createdBy: uid,
  createdAt: serverTimestamp(),
  deviceId: null,
  idempotencyKey: "k1",
});

describe("cross-tenant isolation", () => {
  test("Org A owner can't read Org B's orders", async () => {
    const db = as(ownerUid("org-a"));
    await assertFails(getDoc(doc(db, `${HALIFAX}/orders/order-1`)));
    await assertFails(getDocs(collection(db, `${HALIFAX}/orders`)));
  });

  test("Org A owner can't write into Org B, even with Org B's IDs in the data", async () => {
    const db = as(ownerUid("org-a"));
    await assertFails(setDoc(doc(db, `${HALIFAX}/orders/x`), {
      ...newOrder(ownerUid("org-a")), orgId: "org-b", locationId: "halifax",
    }));
  });

  test("a Cambridge cashier can't read Toronto cash sessions", async () => {
    await asAdmin(env, (db) => setDoc(
      doc(db, `${TORONTO}/cashSessions/s1`),
      cashSession({ orgId: "org-a", locationId: "toronto" }, memberUid("org-a", "toronto", "cashier"), "open"),
    ));
    const db = as(memberUid("org-a", "cambridge", "cashier"));
    await assertFails(getDoc(doc(db, `${TORONTO}/cashSessions/s1`)));
    await assertFails(getDocs(collection(db, `${TORONTO}/cashSessions`)));
  });

  test("a Cambridge cashier can't read Toronto orders", async () => {
    const db = as(memberUid("org-a", "cambridge", "cashier"));
    await assertFails(getDoc(doc(db, `${TORONTO}/orders/order-1`)));
  });
});

describe("privilege escalation", () => {
  test("a store manager can't change subscription status", async () => {
    const db = as(memberUid("org-a", "cambridge", "store_manager"));
    await assertFails(updateDoc(doc(db, `${A}/billing/subscription`), { status: "active" }));
    await assertFails(updateDoc(doc(db, A), { accessLevel: "full" }));
  });

  test("a store manager can't give themselves another location or role", async () => {
    const uid = memberUid("org-a", "cambridge", "store_manager");
    const db = as(uid);
    await assertFails(updateDoc(doc(db, `${A}/members/${uid}`), {
      "locationRoles.toronto": "store_manager",
    }));
    await assertFails(updateDoc(doc(db, `${A}/members/${uid}`), { orgRole: "owner" }));
  });

  test("an owner can't edit memberships directly either; invites go through Functions", async () => {
    const db = as(ownerUid("org-a"));
    await assertFails(setDoc(doc(db, `${A}/members/new-person`), {
      uid: "new-person", orgId: "org-a", status: "active", locationRoles: { cambridge: "cashier" },
    }));
  });

  test("a user can't add an org to their own org list", async () => {
    const uid = memberUid("org-a", "cambridge", "cashier");
    const db = as(uid);
    await assertSucceeds(setDoc(doc(db, `users/${uid}`), { displayName: "Sam" }));
    await assertFails(updateDoc(doc(db, `users/${uid}`), { orgIds: ["org-b"] }));
    await assertFails(getDoc(doc(db, `users/${ownerUid("org-a")}`)));
  });

  test("a member can read their own membership but not a colleague's", async () => {
    const uid = memberUid("org-a", "cambridge", "cashier");
    const db = as(uid);
    await assertSucceeds(getDoc(doc(db, `${A}/members/${uid}`)));
    await assertFails(getDoc(doc(db, `${A}/members/${memberUid("org-a", "cambridge", "kitchen")}`)));
  });

  test("kitchen staff can move prep status but not touch items or totals", async () => {
    const db = as(memberUid("org-a", "cambridge", "kitchen"));
    const ref = doc(db, `${CAMBRIDGE}/orders/order-1`);
    await assertSucceeds(updateDoc(ref, { status: "ready" }));
    await assertFails(updateDoc(ref, { items: [] }));
    await assertFails(updateDoc(ref, { discounts: [{ type: "percent", value: 100 }] }));
  });

  test("a cashier applies a discount without a manager PIN, but can't void or refund", async () => {
    const db = as(memberUid("org-a", "cambridge", "cashier"));
    const ref = doc(db, `${CAMBRIDGE}/orders/order-1`);
    await assertSucceeds(updateDoc(ref, { discounts: [{ type: "percent", value: 20 }] }));
    await assertFails(updateDoc(ref, { status: "voided" }));
    await assertFails(updateDoc(ref, { paymentStatus: "refunded" }));
  });
});

describe("tenant and account state", () => {
  test("a suspended member is denied everywhere", async () => {
    const uid = memberUid("org-a", "cambridge", "cashier");
    await asAdmin(env, (db) => updateDoc(doc(db, `${A}/members/${uid}`), { status: "suspended" }));
    const db = as(uid);
    await assertFails(getDoc(doc(db, A)));
    await assertFails(getDoc(doc(db, `${CAMBRIDGE}/orders/order-1`)));
    await assertFails(setDoc(doc(db, `${CAMBRIDGE}/orders/x`), newOrder(uid)));
  });

  test("a revoked device can't ring up sales", async () => {
    const uid = memberUid("org-a", "cambridge", "device");
    const db = as(uid);
    await assertSucceeds(setDoc(doc(db, `${CAMBRIDGE}/orders/before`), newOrder(uid)));
    await asAdmin(env, (admin) => updateDoc(doc(admin, `${A}/members/${uid}`), { status: "suspended" }));
    await assertFails(setDoc(doc(db, `${CAMBRIDGE}/orders/after`), newOrder(uid)));
  });

  test("a closed location is closed to staff, but its owner can still read history", async () => {
    await asAdmin(env, (db) => updateDoc(doc(db, CAMBRIDGE), { status: "closed" }));
    const cashier = as(memberUid("org-a", "cambridge", "cashier"));
    await assertFails(getDoc(doc(cashier, `${CAMBRIDGE}/orders/order-1`)));
    await assertFails(setDoc(
      doc(cashier, `${CAMBRIDGE}/orders/x`),
      newOrder(memberUid("org-a", "cambridge", "cashier")),
    ));
    const owner = as(ownerUid("org-a"));
    await assertSucceeds(getDoc(doc(owner, `${CAMBRIDGE}/orders/order-1`)));
    await assertFails(setDoc(doc(owner, `${CAMBRIDGE}/orders/x`), newOrder(ownerUid("org-a"))));
  });

  test("read-only billing blocks writes but keeps every member's reads", async () => {
    await asAdmin(env, (db) => updateDoc(doc(db, A), { accessLevel: "read_only" }));
    const uid = memberUid("org-a", "cambridge", "cashier");
    const db = as(uid);
    await assertSucceeds(getDoc(doc(db, `${CAMBRIDGE}/orders/order-1`)));
    await assertFails(setDoc(doc(db, `${CAMBRIDGE}/orders/x`), newOrder(uid)));
    const owner = as(ownerUid("org-a"));
    await assertSucceeds(getDocs(collection(owner, `${CAMBRIDGE}/orders`)));
    await assertFails(updateDoc(doc(owner, `${CAMBRIDGE}/settings/hardware`), { printerIp: "10.0.0.2" }));
  });

  test("a platform-suspended org is closed to staff but not to its owner", async () => {
    await asAdmin(env, (db) => updateDoc(doc(db, A), { status: "suspended" }));
    await assertFails(getDoc(doc(as(memberUid("org-a", "cambridge", "store_manager")), A)));
    await assertSucceeds(getDoc(doc(as(ownerUid("org-a")), `${CAMBRIDGE}/orders/order-1`)));
  });
});

describe("platform admin access", () => {
  const grant = (expiresAt: Date) => asAdmin(env, (db) => setDoc(
    doc(db, `${A}/supportGrants/${PLATFORM_ADMIN}`),
    { reason: "ticket 42", grantedBy: "functions", expiresAt: Timestamp.fromDate(expiresAt) },
  ));

  test("without a grant, a platform admin sees nothing", async () => {
    const db = as(PLATFORM_ADMIN);
    await assertFails(getDoc(doc(db, A)));
    await assertFails(getDoc(doc(db, `${CAMBRIDGE}/orders/order-1`)));
  });

  test("with an active grant, a platform admin can read that org only, and never write", async () => {
    await grant(new Date(Date.now() + 60 * 60 * 1000));
    const db = as(PLATFORM_ADMIN);
    await assertSucceeds(getDoc(doc(db, A)));
    await assertSucceeds(getDoc(doc(db, `${CAMBRIDGE}/orders/order-1`)));
    await assertSucceeds(getDoc(doc(db, `${A}/billing/subscription`)));
    await assertFails(getDoc(doc(db, `${HALIFAX}/orders/order-1`)));
    await assertFails(updateDoc(doc(db, `${CAMBRIDGE}/orders/order-1`), { status: "ready" }));
    await assertFails(updateDoc(doc(db, `${A}/billing/subscription`), { status: "canceled" }));
  });

  test("an expired grant gives no access", async () => {
    await grant(new Date(Date.now() - 60 * 1000));
    await assertFails(getDoc(doc(as(PLATFORM_ADMIN), A)));
  });

  test("a grant document does nothing for someone who isn't a platform admin", async () => {
    const uid = memberUid("org-b", "halifax", "store_manager");
    await asAdmin(env, (db) => setDoc(
      doc(db, `${A}/supportGrants/${uid}`),
      { reason: "x", expiresAt: Timestamp.fromDate(new Date(Date.now() + 3_600_000)) },
    ));
    await assertFails(getDoc(doc(as(uid), A)));
  });
});

describe("queries are designed with their rules", () => {
  test("a cashier's query for their own open sessions succeeds; listing all sessions fails", async () => {
    const uid = memberUid("org-a", "cambridge", "cashier");
    await asAdmin(env, async (db) => {
      await setDoc(doc(db, `${CAMBRIDGE}/cashSessions/mine`), cashSession({ orgId: "org-a", locationId: "cambridge" }, uid, "open"));
      await setDoc(doc(db, `${CAMBRIDGE}/cashSessions/theirs`), cashSession({ orgId: "org-a", locationId: "cambridge" }, "someone-else", "open"));
    });
    const db = as(uid);
    const mine = await assertSucceeds(getDocs(query(
      collection(db, `${CAMBRIDGE}/cashSessions`),
      where("openedBy", "==", uid),
      where("status", "==", "open"),
    )));
    expect(mine.docs.map((d) => d.id)).toEqual(["mine"]);
    await assertFails(getDocs(collection(db, `${CAMBRIDGE}/cashSessions`)));
  });

  test("a device lists open sessions at its store, not closed ones", async () => {
    const db = as(memberUid("org-a", "cambridge", "device"));
    await assertSucceeds(getDocs(query(collection(db, `${CAMBRIDGE}/cashSessions`), where("status", "==", "open"))));
    await assertFails(getDocs(collection(db, `${CAMBRIDGE}/cashSessions`)));
  });

  test("a franchise owner queries audit events for their store, not the whole org", async () => {
    const db = as(memberUid("org-a", "cambridge", "franchise_owner"));
    const events = await assertSucceeds(getDocs(query(collection(db, `${A}/auditLog`), where("locationId", "==", "cambridge"))));
    expect(events.size).toBe(1);
    await assertFails(getDocs(query(collection(db, `${A}/auditLog`), where("locationId", "==", "toronto"))));
    await assertFails(getDocs(collection(db, `${A}/auditLog`)));
  });

  test("an inventory manager can read inventory reports but not sales reports", async () => {
    const db = as(memberUid("org-a", "cambridge", "inventory_manager"));
    await assertSucceeds(getDocs(query(collection(db, `${CAMBRIDGE}/reports`), where("kind", "==", "inventory"))));
    await assertFails(getDocs(collection(db, `${CAMBRIDGE}/reports`)));
  });
});

test("a signed-out caller is denied", async () => {
  const db = as(null);
  await assertFails(getDoc(doc(db, A)));
  await assertFails(getDoc(doc(db, `${CAMBRIDGE}/settings/hardware`)));
  await assertFails(getDoc(doc(db, `platformAdmins/${PLATFORM_ADMIN}`)));
});
