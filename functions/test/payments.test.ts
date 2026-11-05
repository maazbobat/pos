import { Timestamp } from "firebase-admin/firestore";
import { beforeEach, describe, expect, it } from "vitest";
import {
  cancelCardPayment,
  cardPaymentId,
  recoverPendingPayments,
  refreshPayment,
  refundPayment,
  startCardPayment,
  voidOrder,
} from "../src/handlers/payments.js";
import { setStaffPin } from "../src/handlers/pins.js";
import { type Caller, membershipData } from "../src/lib/tenant.js";
import type { ProviderRegistry } from "../src/payments/provider.js";
import { CashProvider, CloverProvider, FakeCardProvider, StripeOnlineProvider, StripeTerminalProvider } from "../src/payments/providers.js";
import { auditActions, caller, db, expectHttpsError, PEPPER, resetEmulators, seed, setOrg, u } from "./setup.js";

const LOC = "orgs/org-a/locations/cambridge";
const DEVICE = "dev_cam_pos";
const ids = { orgId: "org-a", locationId: "cambridge" };

let fake: FakeCardProvider;
let registry: ProviderRegistry;

beforeEach(async () => {
  await resetEmulators();
  await seed();
  fake = new FakeCardProvider();
  const cash = new CashProvider();
  const clover = new CloverProvider();
  const terminal = new StripeTerminalProvider();
  registry = (id) => ({ cash, clover, stripe_terminal: terminal, fake_card: fake, stripe_online: new StripeOnlineProvider() })[id];

  await db().doc(`${LOC}/settings/payments`).set({
    ...ids, cardProvider: "fake_card", terminals: { front: { ref: "tmr_front", name: "Front counter" } },
  });
  await order("o1", 1000);
  // A paired POS tablet at Cambridge.
  await db().doc(`orgs/org-a/members/${DEVICE}`).set(
    membershipData("org-a", DEVICE, { kind: "device", orgRole: null, locationRoles: { cambridge: "device" } }),
  );
  await db().doc(`${LOC}/devices/${DEVICE}`).set({ ...ids, deviceId: DEVICE, status: "active", currentStaffUid: u.cashierCam });
});

async function order(orderId: string, totalCents: number, paymentStatus = "unpaid") {
  await db().doc(`${LOC}/orders/${orderId}`).set({
    ...ids, status: "new", paymentStatus, items: [], totals: { subtotalCents: totalCents, taxCents: 0, totalCents },
    createdBy: u.cashierCam, createdAt: Timestamp.now(),
  });
}

const orderDoc = (orderId = "o1") => db().doc(`${LOC}/orders/${orderId}`).get().then((s) => s.data()!);
const payDoc = (paymentId: string, orderId = "o1") =>
  db().doc(`${LOC}/orders/${orderId}/payments/${paymentId}`).get().then((s) => s.data()!);

const charge = (who: string, extra: Record<string, unknown> = {}) =>
  startCardPayment(caller(who), { ...ids, orderId: "o1", amountCents: 1000, tipCents: 150, idempotencyKey: "pos-key-0001", terminalId: "front", ...extra }, registry);

const asDevice = { uid: DEVICE, email: null };

describe("startCardPayment", () => {
  it("charges through the location's provider and marks the order paid, without card data", async () => {
    const result = await charge(u.cashierCam);
    expect(result).toMatchObject({ status: "succeeded", paymentId: cardPaymentId("o1", "pos-key-0001") });
    const pay = await payDoc(result.paymentId);
    expect(pay).toMatchObject({
      method: "card", provider: "fake_card", amountCents: 1000, tipCents: 150, terminalRef: "tmr_front", status: "succeeded",
    });
    expect(Object.keys(pay).some((k) => /card(Number|number)|pan|cvc|expiry/.test(k))).toBe(false);
    expect((await orderDoc()).paymentStatus).toBe("paid");
  });

  it("is idempotent: a retry with the same key never charges twice", async () => {
    const first = await charge(u.cashierCam);
    const again = await startCardPayment(asDevice, { ...ids, orderId: "o1", amountCents: 1000, idempotencyKey: "pos-key-0001" }, registry);
    expect(again.paymentId).toBe(first.paymentId);
    expect(fake.charges.size).toBe(1);
  });

  it("records a decline and leaves the order unpaid", async () => {
    fake.mode = "decline";
    expect(await charge(u.cashierCam)).toMatchObject({ status: "failed", failureReason: "card_declined" });
    expect((await orderDoc()).paymentStatus).toBe("unpaid");
  });

  it("recovers a charge whose answer was lost, by asking the provider", async () => {
    fake.mode = "offline";
    const { paymentId, status } = await charge(u.cashierCam);
    expect(status).toBe("pending");
    expect((await orderDoc()).paymentStatus).toBe("unpaid");
    expect(await refreshPayment(asDevice, { ...ids, orderId: "o1", paymentId }, registry)).toMatchObject({ status: "succeeded" });
    expect((await orderDoc()).paymentStatus).toBe("paid");
  });

  it("can be cancelled while the guest hasn't tapped", async () => {
    fake.mode = "pending";
    const { paymentId } = await charge(u.cashierCam);
    expect(await cancelCardPayment(caller(u.cashierCam), { ...ids, orderId: "o1", paymentId }, registry)).toMatchObject({ status: "canceled" });
  });

  it("won't take more than is due, including payments in progress", async () => {
    fake.mode = "pending";
    await charge(u.cashierCam, { amountCents: 600 });
    await expectHttpsError(charge(u.cashierCam, { amountCents: 500, idempotencyKey: "pos-key-0002" }), "invalid-argument");
  });

  it("is for sellers at that location in a writable org", async () => {
    await expectHttpsError(charge(u.kitchenCam), "permission-denied");
    await expectHttpsError(charge(u.managerTor), "permission-denied");
    await expectHttpsError(charge(u.ownerB), "permission-denied");
    await setOrg("org-a", { accessLevel: "read_only" });
    await expectHttpsError(charge(u.cashierCam), "failed-precondition");
  });

  it("validates cents, keys and terminals", async () => {
    await expectHttpsError(charge(u.cashierCam, { amountCents: 10.5 }), "invalid-argument");
    await expectHttpsError(charge(u.cashierCam, { tipCents: -1 }), "invalid-argument");
    await expectHttpsError(charge(u.cashierCam, { idempotencyKey: "short" }), "invalid-argument");
    await expectHttpsError(charge(u.cashierCam, { terminalId: "back" }), "not-found");
  });

  it("fails clearly at a location set to Clover before Clover is certified", async () => {
    await db().doc(`${LOC}/settings/payments`).set({ ...ids, cardProvider: "clover", terminals: {} });
    await expectHttpsError(charge(u.cashierCam, { terminalId: null }), "failed-precondition");
    expect((await payDoc(cardPaymentId("o1", "pos-key-0001"))).status).toBe("failed");
  });

  it("refuses when card payments aren't set up", async () => {
    await db().doc(`${LOC}/settings/payments`).delete();
    await expectHttpsError(charge(u.cashierCam), "failed-precondition");
  });
});

describe("recoverPendingPayments", () => {
  it("settles payments the provider finished, and fails ones it never saw", async () => {
    fake.mode = "pending";
    const { paymentId } = await charge(u.cashierCam);
    fake.settle("pos-key-0001", "succeeded");

    // A payment the provider has no record of, started 20 minutes ago.
    await order("o2", 500);
    const old = Timestamp.fromMillis(Date.now() - 20 * 60 * 1000);
    await db().doc(`${LOC}/orders/o2/payments/card_lost`).set({
      ...ids, orderId: "o2", method: "card", provider: "fake_card", amountCents: 500, tipCents: 0,
      status: "pending", idempotencyKey: "never-sent", createdAt: old, updatedAt: old,
    });

    const report = await recoverPendingPayments(registry, Date.now() + 3 * 60 * 1000);
    expect(report).toMatchObject({ checked: 2, settled: 1, abandoned: 1 });
    expect((await payDoc(paymentId)).status).toBe("succeeded");
    expect((await orderDoc()).paymentStatus).toBe("paid");
    expect((await payDoc("card_lost", "o2"))).toMatchObject({ status: "failed", failureReason: "not_received" });
  });

  it("raises an incident for a charge stuck at the provider", async () => {
    fake.mode = "pending";
    await charge(u.cashierCam);
    const later = Date.now() + 31 * 60 * 1000;
    await db().doc(`${LOC}/orders/o1/payments/${cardPaymentId("o1", "pos-key-0001")}`)
      .update({ createdAt: Timestamp.fromMillis(Date.now() - 31 * 60 * 1000) });
    expect((await recoverPendingPayments(registry, later)).stuck).toBe(1);
    expect((await recoverPendingPayments(registry, later)).stuck).toBe(0);
    const incidents = await db().collection("platformIncidents").get();
    expect(incidents.docs.map((d) => d.get("kind"))).toEqual(["payment_stuck"]);
  });
});

describe("refundPayment", () => {
  const refund = (who: Caller, extra: Record<string, unknown> = {}) =>
    refundPayment(who, {
      ...ids, orderId: "o1", paymentId: cardPaymentId("o1", "pos-key-0001"), amountCents: 400,
      reason: "Wrong drink", idempotencyKey: "refund-key-01", ...extra,
    }, registry, PEPPER);

  beforeEach(async () => {
    await charge(u.cashierCam);
    await setStaffPin(caller(u.managerCam), { orgId: "org-a", pin: "2580" }, PEPPER);
    await setStaffPin(caller(u.cashierCam), { orgId: "org-a", pin: "1470" }, PEPPER);
  });

  it("is refused to a cashier signed in as themselves", async () => {
    await expectHttpsError(refund(caller(u.cashierCam)), "permission-denied");
    await expectHttpsError(refund(caller(u.managerTor)), "permission-denied");
  });

  it("lets a manager refund part of a payment, audited with the reason", async () => {
    expect(await refund(caller(u.managerCam))).toMatchObject({ status: "succeeded" });
    expect(await payDoc(cardPaymentId("o1", "pos-key-0001"))).toMatchObject({ refundedCents: 400, refundPendingCents: 0 });
    expect((await orderDoc()).paymentStatus).toBe("partially_refunded");
    const log = await db().collection("orgs/org-a/auditLog").where("action", "==", "payment.refund_requested").get();
    expect(log.docs[0].data()).toMatchObject({ actorUid: u.managerCam, reason: "Wrong drink", locationId: "cambridge" });
  });

  it("on a device, needs a manager's PIN, and a cashier's PIN counts as wrong", async () => {
    await expectHttpsError(refund(asDevice), "permission-denied");
    await expectHttpsError(refund(asDevice, { managerPin: "1470" }), "permission-denied");
    const guard = await db().doc(`${LOC}/devices/${DEVICE}/private/pinGuard`).get();
    expect(guard.get("failures")).toBe(1);

    expect(await refund(asDevice, { managerPin: "2580" })).toMatchObject({ status: "succeeded" });
    const log = await db().collection("orgs/org-a/auditLog").where("action", "==", "payment.refund_requested").get();
    expect(log.docs[0].data()).toMatchObject({ actorUid: DEVICE, actorKind: "device", staffUid: u.managerCam });
  });

  it("is idempotent and never refunds more than was paid, tip included", async () => {
    const first = await refund(caller(u.managerCam));
    expect((await refund(caller(u.managerCam))).refundId).toBe(first.refundId);
    expect(fake.refunds.size).toBe(1);
    await expectHttpsError(refund(caller(u.managerCam), { amountCents: 751, idempotencyKey: "refund-key-02" }), "invalid-argument");
    await refund(caller(u.managerCam), { amountCents: 750, idempotencyKey: "refund-key-03" });
    expect((await orderDoc()).paymentStatus).toBe("refunded");
  });

  it("refunds cash the POS recorded", async () => {
    await order("o3", 300);
    await db().doc(`${LOC}/orders/o3/payments/cash-key-1`).set({
      ...ids, orderId: "o3", method: "cash", provider: "cash", amountCents: 300, tipCents: 0,
      status: "succeeded", idempotencyKey: "cash-key-1", createdBy: u.cashierCam, createdAt: Timestamp.now(),
    });
    const result = await refundPayment(caller(u.managerCam), {
      ...ids, orderId: "o3", paymentId: "cash-key-1", amountCents: 300, reason: "Left before pickup", idempotencyKey: "refund-cash-1",
    }, registry, PEPPER);
    expect(result.status).toBe("succeeded");
    expect((await orderDoc("o3")).paymentStatus).toBe("refunded");
  });
});

describe("voidOrder", () => {
  it("voids an unpaid order with a manager's approval and an audit entry", async () => {
    await expectHttpsError(voidOrder(caller(u.cashierCam), { ...ids, orderId: "o1", reason: "Test order" }, PEPPER), "permission-denied");
    await voidOrder(caller(u.managerCam), { ...ids, orderId: "o1", reason: "Test order" }, PEPPER);
    expect(await orderDoc()).toMatchObject({ status: "voided", voidedBy: u.managerCam, voidReason: "Test order" });
    expect(await auditActions("org-a")).toEqual(["order.voided"]);
  });

  it("won't void a paid order until it's refunded", async () => {
    await charge(u.cashierCam);
    await expectHttpsError(voidOrder(caller(u.managerCam), { ...ids, orderId: "o1", reason: "Oops" }, PEPPER), "failed-precondition");
    await refundPayment(caller(u.managerCam), {
      ...ids, orderId: "o1", paymentId: cardPaymentId("o1", "pos-key-0001"), amountCents: 1150, reason: "Oops", idempotencyKey: "refund-all-1",
    }, registry, PEPPER);
    await voidOrder(caller(u.managerCam), { ...ids, orderId: "o1", reason: "Oops" }, PEPPER);
    expect((await orderDoc()).status).toBe("voided");
    // And a voided order can't be charged.
    await expectHttpsError(charge(u.cashierCam, { idempotencyKey: "pos-key-0009" }), "failed-precondition");
  });
});
