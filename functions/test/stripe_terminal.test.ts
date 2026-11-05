import { Timestamp } from "firebase-admin/firestore";
import { beforeEach, describe, expect, it } from "vitest";
import {
  cancelCardPayment,
  cardPaymentId,
  recoverPendingPayments,
  refreshPayment,
  refundPayment,
  registerCardReader,
  startCardPayment,
} from "../src/handlers/payments.js";
import { setStaffPin } from "../src/handlers/pins.js";
import { membershipData } from "../src/lib/tenant.js";
import type { ProviderRegistry } from "../src/payments/provider.js";
import { CashProvider, StripeTerminalProvider } from "../src/payments/providers.js";
import { intentResult } from "../src/payments/stripe_terminal.js";
import { FakeReaderSetupApi, FakeTerminalApi } from "./fake_terminal.js";
import { auditActions, caller, db, expectHttpsError, PEPPER, resetEmulators, seed } from "./setup.js";
import { u } from "./setup.js";

const LOC = "orgs/org-a/locations/cambridge";
const ids = { orgId: "org-a", locationId: "cambridge" };
const ACCT = "acct_maple";
const READER = "tmr_front";
const KEY = "pos-key-0001";
const DEVICE = "dev_cam_pos";
const asDevice = { uid: DEVICE, email: null };

let stripe: FakeTerminalApi;
let registry: ProviderRegistry;

beforeEach(async () => {
  await resetEmulators();
  await seed();
  stripe = new FakeTerminalApi();
  const terminal = new StripeTerminalProvider(stripe);
  const cash = new CashProvider();
  registry = (id) => (id === "stripe_terminal" ? terminal : cash);
  await db().doc(`${LOC}/settings/payments`).set({
    ...ids, cardProvider: "stripe_terminal", terminals: { front: { ref: READER, name: "Front counter" } },
  });
  await db().doc(`${LOC}/settings/onlineOrdering`).set({ ...ids, stripeAccountId: ACCT });
  await db().doc(`${LOC}/orders/o1`).set({
    ...ids, status: "new", paymentStatus: "unpaid", items: [],
    totals: { subtotalCents: 1000, taxCents: 0, totalCents: 1000 }, createdBy: u.cashierCam, createdAt: Timestamp.now(),
  });
  await db().doc(`orgs/org-a/members/${DEVICE}`).set(
    membershipData("org-a", DEVICE, { kind: "device", orgRole: null, locationRoles: { cambridge: "device" } }),
  );
  await db().doc(`${LOC}/devices/${DEVICE}`).set({ ...ids, deviceId: DEVICE, status: "active", currentStaffUid: u.cashierCam });
});

const paymentId = cardPaymentId("o1", KEY);
const charge = (extra: Record<string, unknown> = {}) =>
  startCardPayment(asDevice, { ...ids, orderId: "o1", amountCents: 1000, tipCents: 150, idempotencyKey: KEY, terminalId: "front", ...extra }, registry);
const refresh = () => refreshPayment(asDevice, { ...ids, orderId: "o1", paymentId }, registry);
const payDoc = () => db().doc(`${LOC}/orders/o1/payments/${paymentId}`).get().then((s) => s.data()!);
const orderDoc = () => db().doc(`${LOC}/orders/o1`).get().then((s) => s.data()!);

describe("Stripe Terminal card payments", () => {
  it("sends the total plus tip to the counter's reader on the restaurant's account, then settles when the guest taps", async () => {
    expect(await charge()).toMatchObject({ paymentId, status: "pending" });
    const pi = stripe.intentFor(KEY)!;
    expect(pi).toMatchObject({ account: ACCT, amount: 1150, metadata: { orderId: "o1", paymentId, tipCents: "150" } });
    expect(stripe.onReader.get(READER)).toBe(pi.id);
    expect(await payDoc()).toMatchObject({ provider: "stripe_terminal", providerAccount: ACCT, providerRef: pi.id, status: "pending" });

    expect(await refresh()).toMatchObject({ status: "pending" });
    stripe.guest(READER, "tap");
    expect(await refresh()).toMatchObject({ status: "succeeded" });
    expect((await orderDoc()).paymentStatus).toBe("paid");
  });

  it("records a decline, and closes the intent so a late tap can't charge", async () => {
    await charge();
    stripe.guest(READER, "decline");
    expect(await refresh()).toMatchObject({ status: "failed", failureReason: "insufficient_funds" });
    expect(stripe.intentFor(KEY)!.status).toBe("canceled");
    expect((await orderDoc()).paymentStatus).toBe("unpaid");
  });

  it("fails at once when the reader is offline or busy, without leaving a live charge", async () => {
    stripe.readerState = "offline";
    expect(await charge()).toMatchObject({ status: "failed", failureReason: "reader_offline" });
    expect(stripe.intentFor(KEY)!.status).toBe("canceled");
    stripe.readerState = "busy";
    expect(await charge({ idempotencyKey: "pos-key-0002" })).toMatchObject({ status: "failed", failureReason: "reader_busy" });
  });

  it("keeps a timed-out charge pending, and the recovery job settles it by our key", async () => {
    stripe.readerState = "timeout";
    expect(await charge()).toMatchObject({ status: "pending" });
    stripe.guest(READER, "tap");
    // As if the Function crashed before saving Stripe's ID: lookup goes by the idempotency key.
    await db().doc(`${LOC}/orders/o1/payments/${paymentId}`).update({ providerRef: null, updatedAt: Timestamp.fromMillis(Date.now() - 5 * 60_000) });
    const report = await recoverPendingPayments(registry);
    expect(report.settled).toBe(1);
    expect(await payDoc()).toMatchObject({ status: "succeeded" });
  });

  it("is idempotent: a retry with the same key reuses the intent", async () => {
    await charge();
    await charge();
    expect(stripe.intents.size).toBe(1);
  });

  it("cancel clears the reader and cancels the intent", async () => {
    await charge();
    expect(await cancelCardPayment(asDevice, { ...ids, orderId: "o1", paymentId }, registry)).toMatchObject({ status: "canceled" });
    expect(stripe.onReader.has(READER)).toBe(false);
    expect(stripe.intentFor(KEY)!.status).toBe("canceled");
  });

  it("cancel after the guest tapped reports the real outcome", async () => {
    await charge();
    stripe.guest(READER, "tap");
    expect(await cancelCardPayment(asDevice, { ...ids, orderId: "o1", paymentId }, registry)).toMatchObject({ status: "succeeded" });
    expect((await orderDoc()).paymentStatus).toBe("paid");
  });

  it("fails clearly when the owner hasn't connected a Stripe account", async () => {
    await db().doc(`${LOC}/settings/onlineOrdering`).delete();
    await expectHttpsError(charge(), "failed-precondition");
    expect(await payDoc()).toMatchObject({ status: "failed", failureReason: "not_configured" });
  });

  it("fails clearly when the project has no Stripe key", async () => {
    const noKey = new StripeTerminalProvider(null);
    registry = () => noKey;
    await expectHttpsError(charge(), "failed-precondition");
  });
});

describe("Stripe Terminal refunds", () => {
  const refund = (extra: Record<string, unknown> = {}) =>
    refundPayment(caller(u.managerCam), {
      ...ids, orderId: "o1", paymentId, amountCents: 500, reason: "Wrong drink", idempotencyKey: "refund-key-01", ...extra,
    }, registry, PEPPER);

  it("refunds a card on the restaurant's account, once", async () => {
    await charge();
    stripe.guest(READER, "tap");
    await refresh();
    expect(await refund()).toMatchObject({ status: "succeeded" });
    expect(await refund()).toMatchObject({ status: "succeeded" });
    expect(stripe.refunds.size).toBe(1);
    expect([...stripe.refunds.values()][0]).toMatchObject({ intentId: stripe.intentFor(KEY)!.id, amountCents: 500 });
    expect((await orderDoc()).paymentStatus).toBe("partially_refunded");
  });

  it("needs a manager: a cashier can't, a device needs a manager's PIN", async () => {
    await charge();
    stripe.guest(READER, "tap");
    await refresh();
    await setStaffPin(caller(u.managerCam), { orgId: "org-a", pin: "2580" }, PEPPER);
    await expectHttpsError(refundPayment(caller(u.cashierCam), {
      ...ids, orderId: "o1", paymentId, amountCents: 500, reason: "Wrong drink", idempotencyKey: "refund-key-01",
    }, registry, PEPPER), "permission-denied");
    await expectHttpsError(refundPayment(asDevice, {
      ...ids, orderId: "o1", paymentId, amountCents: 500, reason: "Wrong drink", idempotencyKey: "refund-key-01",
    }, registry, PEPPER), "permission-denied");
    expect(await refundPayment(asDevice, {
      ...ids, orderId: "o1", paymentId, amountCents: 500, reason: "Wrong drink", idempotencyKey: "refund-key-01", managerPin: "2580",
    }, registry, PEPPER)).toMatchObject({ status: "succeeded" });
  });

  it("won't refund Interac debit without the card, and frees the amount again", async () => {
    await charge();
    stripe.guest(READER, "interac");
    await refresh();
    expect(await refund()).toMatchObject({ status: "failed" });
    expect(stripe.refunds.size).toBe(0);
    expect(await payDoc()).toMatchObject({ refundedCents: 0, refundPendingCents: 0 });
    const r = await db().collection(`${LOC}/orders/o1/refunds`).get();
    expect(r.docs[0].get("failureReason")).toBe("interac_needs_card");
  });
});

describe("registerCardReader", () => {
  let setup: FakeReaderSetupApi;
  const address = { addressLine1: "10 Main St", city: "Cambridge", postalCode: "n1r 5s2" };
  const register = (who: string, extra: Record<string, unknown> = {}) =>
    registerCardReader(caller(who), {
      ...ids, terminalId: "counter-2", name: "Drive-thru", registrationCode: "simulated-wpe", ...address, ...extra,
    }, setup);

  beforeEach(async () => {
    setup = new FakeReaderSetupApi();
    await db().doc(`${LOC}/settings/payments`).delete();
  });

  it("creates the store's Stripe location once, registers the reader and turns card payments on", async () => {
    expect(await register(u.managerCam)).toEqual({ terminalId: "counter-2", readerRef: "tmr_1", model: "stripe_s700" });
    expect(setup.locations).toEqual([{
      account: ACCT, name: "cambridge", address: { line1: "10 Main St", city: "Cambridge", province: "ON", postalCode: "N1R 5S2" },
    }]);
    const settings = (await db().doc(`${LOC}/settings/payments`).get()).data()!;
    expect(settings).toMatchObject({
      cardProvider: "stripe_terminal", stripeTerminalLocation: "tml_1",
      terminals: { "counter-2": { ref: "tmr_1", name: "Drive-thru", model: "stripe_s700" } },
    });
    await register(u.managerCam, { terminalId: "front", name: "Front", registrationCode: "quick-brown-fox" });
    expect(setup.locations).toHaveLength(1);
    expect(Object.keys((await db().doc(`${LOC}/settings/payments`).get()).get("terminals")).sort()).toEqual(["counter-2", "front"]);
    expect(await auditActions("org-a")).toContain("payment.reader_registered");
  });

  it("is for managers signed in as themselves", async () => {
    await expectHttpsError(register(u.cashierCam), "permission-denied");
    await expectHttpsError(register(u.managerTor), "permission-denied");
    await expectHttpsError(register(DEVICE), "permission-denied");
  });

  it("needs the owner's Stripe account, a valid code and a postal code", async () => {
    await expectHttpsError(register(u.managerCam, { registrationCode: "not a code!" }), "invalid-argument");
    await expectHttpsError(register(u.managerCam, { postalCode: "12345" }), "invalid-argument");
    await expectHttpsError(register(u.managerCam, { registrationCode: "wrong-words" }), "invalid-argument");
    // The Stripe location made on the failed try is kept for the next one.
    expect((await db().doc(`${LOC}/settings/payments`).get()).get("stripeTerminalLocation")).toBe("tml_1");
    await db().doc(`${LOC}/settings/onlineOrdering`).delete();
    await expectHttpsError(register(u.managerCam), "failed-precondition");
    await expectHttpsError(registerCardReader(caller(u.managerCam), { ...ids, terminalId: "x", name: "X", registrationCode: "a-b" }, null), "failed-precondition");
  });
});

describe("intentResult", () => {
  it("maps Stripe's statuses", () => {
    const pi = { id: "pi_1", amount: 1, metadata: {}, lastErrorCode: null, chargeMethod: null };
    expect(intentResult({ ...pi, status: "succeeded" }).status).toBe("succeeded");
    expect(intentResult({ ...pi, status: "processing" }).status).toBe("pending");
    expect(intentResult({ ...pi, status: "requires_payment_method" }).status).toBe("pending");
    expect(intentResult({ ...pi, status: "requires_payment_method", lastErrorCode: "card_declined" }))
      .toEqual({ status: "failed", providerRef: "pi_1", failureReason: "card_declined" });
    expect(intentResult({ ...pi, status: "canceled" }).status).toBe("canceled");
  });
});
