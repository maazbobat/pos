/**
 * Card payments, refunds and voids, through the PaymentProvider abstraction
 * (payments/provider.ts).
 *
 * Payment documents live at orders/{orderId}/payments/{paymentId}. The POS
 * writes cash payments directly so they work offline (firestore.rules checks
 * their shape); everything here is server-only:
 *
 *   startCardPayment   creates a pending payment, then asks the provider to charge
 *   refreshPayment     asks the provider what happened (the POS polls this)
 *   cancelCardPayment  stops a charge that hasn't completed
 *   refundPayment      manager only, or a manager's PIN on a device; audited
 *   voidOrder          manager only, or a manager's PIN on a device; audited
 *   recoverPendingPayments  scheduled: settles payments we never heard back about
 *
 * The payment ID is derived from the order and the POS's idempotency key, so
 * a retry after a dropped connection finds the first attempt instead of
 * charging again. Amounts are whole cents; no card data is ever stored.
 */
import { FieldValue, Timestamp, type DocumentData, type Transaction } from "firebase-admin/firestore";
import { logger } from "firebase-functions";
import { audit } from "../lib/audit.js";
import { fail } from "../lib/errors.js";
import { db } from "../lib/firebase.js";
import { sha256 } from "../lib/ids.js";
import { recordIncident } from "../lib/platform.js";
import { isManager, type Role } from "../lib/roles.js";
import {
  type Caller,
  paths,
  requireActiveLocation,
  requireActiveMember,
  requireUid,
  requireWritableOrg,
  roleAt,
} from "../lib/tenant.js";
import { asInput, docId, type Input, str } from "../lib/validate.js";
import {
  type ChargeResult,
  type ChargeStatus,
  type ProviderId,
  ProviderNotConfigured,
  type ProviderRegistry,
  TERMINAL_PROVIDER_IDS,
} from "../payments/provider.js";
import { verifyManagerPin } from "./pins.js";

const SELLERS: readonly Role[] = ["owner", "franchise_owner", "store_manager", "cashier", "device"];
const MAX_CENTS = 10_000_000;

export const paymentPaths = {
  order: (o: string, l: string, orderId: string) => `${paths.location(o, l)}/orders/${orderId}`,
  payments: (o: string, l: string, orderId: string) => `${paths.location(o, l)}/orders/${orderId}/payments`,
  payment: (o: string, l: string, orderId: string, id: string) =>
    `${paths.location(o, l)}/orders/${orderId}/payments/${id}`,
  refund: (o: string, l: string, orderId: string, id: string) =>
    `${paths.location(o, l)}/orders/${orderId}/refunds/${id}`,
  settings: (o: string, l: string) => `${paths.location(o, l)}/settings/payments`,
};

export const cardPaymentId = (orderId: string, key: string) => `card_${sha256(`${orderId}:${key}`).slice(0, 32)}`;
export const refundId = (paymentId: string, key: string) => `refund_${sha256(`${paymentId}:${key}`).slice(0, 32)}`;

function cents(input: Input, key: string, opts: { min: number; optional?: boolean }): number {
  const v = input[key];
  if (v === undefined && opts.optional) return 0;
  if (typeof v !== "number" || !Number.isInteger(v) || v < opts.min || v > MAX_CENTS) {
    throw fail.invalid(`${key} must be whole cents from ${opts.min} to ${MAX_CENTS}.`);
  }
  return v;
}

function idempotencyKey(input: Input): string {
  const v = str(input, "idempotencyKey", { min: 8, max: 100 });
  if (!/^[A-Za-z0-9_-]+$/.test(v)) throw fail.invalid("idempotencyKey must be letters, digits, - or _.");
  return v;
}

interface OrderRef {
  orgId: string;
  locationId: string;
  orderId: string;
}

function orderRef(input: Input): OrderRef {
  return { orgId: docId(input, "orgId"), locationId: docId(input, "locationId"), orderId: docId(input, "orderId") };
}

/** A seller at this location, in a writable org at an open location. Returns who's acting. */
async function requireSeller(tx: Transaction, ref: OrderRef, uid: string) {
  const member = await requireActiveMember(tx, ref.orgId, uid);
  const role = roleAt(member, ref.locationId);
  if (!role || !SELLERS.includes(role)) throw fail.denied();
  await requireWritableOrg(tx, ref.orgId);
  await requireActiveLocation(tx, ref.orgId, ref.locationId);
  let staffUid: string | null = null;
  if (member.kind === "device") {
    const device = await tx.get(db().doc(paths.device(ref.orgId, ref.locationId, uid)));
    staffUid = (device.get("currentStaffUid") as string | undefined) ?? null;
  }
  return { member, role, staffUid };
}

function totalCentsOf(order: DocumentData): number {
  const total = order.totals?.totalCents;
  if (typeof total !== "number" || !Number.isInteger(total) || total < 0) {
    throw fail.precondition("This order has no total in cents.");
  }
  return total;
}

interface PaymentSums {
  succeeded: number;
  pending: number;
  refunded: number;
}

/** Sums of amountCents (tips excluded) over an order's payments. */
async function sumPayments(tx: Transaction, ref: OrderRef): Promise<PaymentSums> {
  const snap = await tx.get(db().collection(paymentPaths.payments(ref.orgId, ref.locationId, ref.orderId)));
  const sums: PaymentSums = { succeeded: 0, pending: 0, refunded: 0 };
  for (const d of snap.docs) {
    const amount = (d.get("amountCents") as number | undefined) ?? 0;
    const status = d.get("status") as string | undefined;
    if (status === "succeeded") sums.succeeded += amount;
    if (status === "pending") sums.pending += amount;
    sums.refunded += (d.get("refundedCents") as number | undefined) ?? 0;
  }
  return sums;
}

function paymentStatusFor(sums: PaymentSums, totalCents: number): "unpaid" | "paid" | "partially_refunded" | "refunded" {
  if (sums.refunded > 0) return sums.refunded >= sums.succeeded ? "refunded" : "partially_refunded";
  return sums.succeeded >= totalCents && totalCents > 0 ? "paid" : "unpaid";
}

async function providerFor(tx: Transaction, ref: OrderRef, terminalId: string | null) {
  const settings = (await tx.get(db().doc(paymentPaths.settings(ref.orgId, ref.locationId)))).data() ?? {};
  const provider = settings.cardProvider as ProviderId | undefined;
  if (!provider || !(TERMINAL_PROVIDER_IDS as readonly string[]).includes(provider)) {
    throw fail.precondition("Card payments aren't set up at this location.");
  }
  const terminals = (settings.terminals ?? {}) as Record<string, { ref?: string }>;
  let terminalRef: string | null = null;
  if (terminalId) {
    terminalRef = terminals[terminalId]?.ref ?? null;
    if (!terminalRef) throw fail.notFound("That terminal isn't set up at this location.");
  }
  return { provider, terminalRef };
}

/**
 * Records a provider's answer on a pending payment and recomputes the
 * order's payment status. A payment that already left pending is not changed.
 */
async function settlePayment(ref: OrderRef, paymentId: string, result: ChargeResult): Promise<ChargeStatus> {
  return db().runTransaction(async (tx) => {
    const payRef = db().doc(paymentPaths.payment(ref.orgId, ref.locationId, ref.orderId, paymentId));
    const orderDocRef = db().doc(paymentPaths.order(ref.orgId, ref.locationId, ref.orderId));
    const [pay, order, sums] = await Promise.all([tx.get(payRef), tx.get(orderDocRef), sumPayments(tx, ref)]);
    if (!pay.exists) throw fail.notFound("Payment not found.");
    const current = pay.get("status") as ChargeStatus;
    if (current !== "pending" || result.status === "pending") {
      if (result.providerRef && !pay.get("providerRef")) tx.update(payRef, { providerRef: result.providerRef });
      return current;
    }
    tx.update(payRef, {
      status: result.status,
      providerRef: result.providerRef ?? pay.get("providerRef") ?? null,
      failureReason: result.failureReason ?? null,
      settledAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    if (result.status === "succeeded" && order.exists) {
      const amount = pay.get("amountCents") as number;
      const next = { ...sums, succeeded: sums.succeeded + amount, pending: sums.pending - amount };
      const total = totalCentsOf(order.data()!);
      const status = paymentStatusFor(next, total);
      if (status !== order.get("paymentStatus")) {
        tx.update(orderDocRef, { paymentStatus: status, updatedAt: FieldValue.serverTimestamp() });
      }
      if (next.succeeded > total) {
        logger.warn("Order overpaid", { ...ref, total, succeeded: next.succeeded });
      }
    }
    return result.status;
  });
}

export interface PaymentResult {
  paymentId: string;
  status: ChargeStatus;
  failureReason?: string | null;
}

export async function startCardPayment(
  caller: Caller,
  data: unknown,
  registry: ProviderRegistry,
): Promise<PaymentResult> {
  const uid = requireUid(caller);
  const input = asInput(data);
  const ref = orderRef(input);
  const amountCents = cents(input, "amountCents", { min: 1 });
  const tipCents = cents(input, "tipCents", { min: 0, optional: true });
  const key = idempotencyKey(input);
  const terminalId = input.terminalId === undefined || input.terminalId === null ? null : docId(input, "terminalId");
  const paymentId = cardPaymentId(ref.orderId, key);
  const payRef = db().doc(paymentPaths.payment(ref.orgId, ref.locationId, ref.orderId, paymentId));

  const start = await db().runTransaction(async (tx) => {
    const { staffUid } = await requireSeller(tx, ref, uid);
    const existing = await tx.get(payRef);
    if (existing.exists) return { existing: existing.data()! } as const;

    const order = await tx.get(db().doc(paymentPaths.order(ref.orgId, ref.locationId, ref.orderId)));
    if (!order.exists) throw fail.notFound("Order not found.");
    if (order.get("status") === "voided") throw fail.precondition("This order was voided.");
    if (order.get("paymentStatus") !== "unpaid") throw fail.precondition("This order is already paid.");
    const total = totalCentsOf(order.data()!);
    const sums = await sumPayments(tx, ref);
    const due = total - sums.succeeded - sums.pending;
    if (amountCents > due) throw fail.invalid(`Only ${due} cents are left to pay on this order.`);
    const { provider, terminalRef } = await providerFor(tx, ref, terminalId);

    tx.create(payRef, {
      orgId: ref.orgId,
      locationId: ref.locationId,
      orderId: ref.orderId,
      method: "card",
      provider,
      terminalId,
      terminalRef,
      amountCents,
      tipCents,
      refundedCents: 0,
      status: "pending",
      providerRef: null,
      failureReason: null,
      idempotencyKey: key,
      createdBy: uid,
      staffUid,
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    return { provider, terminalRef, existing: undefined };
  });

  if (start.existing) {
    return {
      paymentId,
      status: start.existing.status as ChargeStatus,
      failureReason: (start.existing.failureReason as string | null) ?? null,
    };
  }

  let result: ChargeResult;
  try {
    result = await registry(start.provider).charge({
      ...ref,
      paymentId,
      amountCents,
      tipCents,
      currency: "cad",
      idempotencyKey: key,
      terminalRef: start.terminalRef,
    });
  } catch (err) {
    if (err instanceof ProviderNotConfigured) {
      await settlePayment(ref, paymentId, { status: "failed", providerRef: null, failureReason: "not_configured" });
      throw fail.precondition(err.message);
    }
    // Unknown outcome: the charge may have gone through. Leave it pending
    // for refreshPayment or the recovery job to ask the provider.
    logger.warn("Card charge interrupted", { ...ref, paymentId, err: String(err) });
    await payRef.update({ lastError: String(err).slice(0, 300), updatedAt: FieldValue.serverTimestamp() });
    return { paymentId, status: "pending" };
  }
  const status = await settlePayment(ref, paymentId, result);
  return { paymentId, status, failureReason: result.failureReason ?? null };
}

async function readPaymentForSeller(caller: Caller, data: unknown) {
  const uid = requireUid(caller);
  const input = asInput(data);
  const ref = orderRef(input);
  const paymentId = docId(input, "paymentId");
  const pay = await db().runTransaction(async (tx) => {
    // Reading needs only an active seller; a read-only org can still finish
    // a charge that started before it lapsed.
    const member = await requireActiveMember(tx, ref.orgId, uid);
    const role = roleAt(member, ref.locationId);
    if (!role || !SELLERS.includes(role)) throw fail.denied();
    const snap = await tx.get(db().doc(paymentPaths.payment(ref.orgId, ref.locationId, ref.orderId, paymentId)));
    if (!snap.exists) throw fail.notFound("Payment not found.");
    return snap.data()!;
  });
  return { uid, ref, paymentId, pay };
}

export async function refreshPayment(caller: Caller, data: unknown, registry: ProviderRegistry): Promise<PaymentResult> {
  const { ref, paymentId, pay } = await readPaymentForSeller(caller, data);
  if (pay.status !== "pending") {
    return { paymentId, status: pay.status as ChargeStatus, failureReason: pay.failureReason ?? null };
  }
  const result = await registry(pay.provider as ProviderId).lookup({
    idempotencyKey: pay.idempotencyKey,
    providerRef: pay.providerRef ?? null,
    terminalRef: pay.terminalRef ?? null,
  });
  if (!result) return { paymentId, status: "pending" };
  const status = await settlePayment(ref, paymentId, result);
  return { paymentId, status, failureReason: result.failureReason ?? null };
}

export async function cancelCardPayment(caller: Caller, data: unknown, registry: ProviderRegistry): Promise<PaymentResult> {
  const { ref, paymentId, pay } = await readPaymentForSeller(caller, data);
  if (pay.status !== "pending") return { paymentId, status: pay.status as ChargeStatus };
  const result = await registry(pay.provider as ProviderId).cancel({
    idempotencyKey: pay.idempotencyKey,
    providerRef: pay.providerRef ?? null,
    terminalRef: pay.terminalRef ?? null,
  });
  // The guest may have tapped just before the cancel arrived.
  const status = await settlePayment(ref, paymentId, result);
  return { paymentId, status };
}

// ---------------------------------------------------------------------------
// Elevated: refunds and voids
// ---------------------------------------------------------------------------

/**
 * Who approves an elevated action: a manager signed in as themselves, or a
 * paired device where a manager typed their PIN. Anyone else is refused.
 */
async function requireElevated(
  ref: OrderRef,
  uid: string,
  input: Input,
  pepper: string,
): Promise<{ approvedBy: string; actorKind: "user" | "device" }> {
  const member = await requireActiveMember(null, ref.orgId, uid);
  if (member.kind === "user") {
    if (!isManager(roleAt(member, ref.locationId))) throw fail.denied("A manager has to do that.");
    return { approvedBy: uid, actorKind: "user" };
  }
  if (roleAt(member, ref.locationId) !== "device") throw fail.denied();
  const pin = typeof input.managerPin === "string" ? input.managerPin : "";
  if (!pin) throw fail.denied("A manager's PIN is needed.");
  const { staff, locationId } = await verifyManagerPin(ref.orgId, uid, pin, pepper);
  if (locationId !== ref.locationId) throw fail.denied();
  return { approvedBy: staff.uid, actorKind: "device" };
}

export interface RefundOutcome {
  refundId: string;
  status: "pending" | "succeeded" | "failed";
}

export async function refundPayment(
  caller: Caller,
  data: unknown,
  registry: ProviderRegistry,
  pepper: string,
): Promise<RefundOutcome> {
  const uid = requireUid(caller);
  const input = asInput(data);
  const ref = orderRef(input);
  const paymentId = docId(input, "paymentId");
  const amountCents = cents(input, "amountCents", { min: 1 });
  const reason = str(input, "reason", { min: 3, max: 200 });
  const key = idempotencyKey(input);
  const id = refundId(paymentId, key);
  const { approvedBy, actorKind } = await requireElevated(ref, uid, input, pepper);

  const payRef = db().doc(paymentPaths.payment(ref.orgId, ref.locationId, ref.orderId, paymentId));
  const refundRef = db().doc(paymentPaths.refund(ref.orgId, ref.locationId, ref.orderId, id));

  const started = await db().runTransaction(async (tx) => {
    await requireWritableOrg(tx, ref.orgId);
    const [existing, pay] = await Promise.all([tx.get(refundRef), tx.get(payRef)]);
    if (existing.exists) return { existing: existing.data()! } as const;
    if (!pay.exists) throw fail.notFound("Payment not found.");
    if (pay.get("status") !== "succeeded") throw fail.precondition("Only a completed payment can be refunded.");
    const refundable = (pay.get("amountCents") as number) + ((pay.get("tipCents") as number | undefined) ?? 0)
      - ((pay.get("refundedCents") as number | undefined) ?? 0)
      - ((pay.get("refundPendingCents") as number | undefined) ?? 0);
    if (amountCents > refundable) throw fail.invalid(`At most ${refundable} cents can be refunded.`);
    const provider = ((pay.get("provider") as ProviderId | undefined) ?? "cash");
    tx.create(refundRef, {
      orgId: ref.orgId,
      locationId: ref.locationId,
      orderId: ref.orderId,
      paymentId,
      provider,
      amountCents,
      reason,
      status: "pending",
      providerRef: null,
      idempotencyKey: key,
      requestedBy: uid,
      approvedBy,
      createdAt: FieldValue.serverTimestamp(),
    });
    tx.update(payRef, { refundPendingCents: FieldValue.increment(amountCents) });
    audit(tx, ref.orgId, {
      action: "payment.refund_requested",
      actorUid: uid,
      actorKind,
      staffUid: approvedBy === uid ? null : approvedBy,
      locationId: ref.locationId,
      reason,
      target: { orderId: ref.orderId, paymentId, refundId: id, amountCents },
    });
    return { provider, providerRef: (pay.get("providerRef") as string | null) ?? null, existing: undefined };
  });
  if (started.existing) return { refundId: id, status: started.existing.status };

  let status: RefundOutcome["status"];
  let providerRef: string | null = null;
  let failureReason: string | null = null;
  try {
    const r = await registry(started.provider).refund({ paymentId, providerRef: started.providerRef, amountCents, idempotencyKey: key });
    status = r.status;
    providerRef = r.providerRef;
    failureReason = r.failureReason ?? null;
  } catch (err) {
    logger.error("Refund call failed", { ...ref, paymentId, refundId: id, err: String(err) });
    status = "failed";
    failureReason = err instanceof ProviderNotConfigured ? "not_configured" : "provider_error";
  }

  await db().runTransaction(async (tx) => {
    const orderDocRef = db().doc(paymentPaths.order(ref.orgId, ref.locationId, ref.orderId));
    const [order, sums] = await Promise.all([tx.get(orderDocRef), sumPayments(tx, ref)]);
    tx.update(refundRef, { status, providerRef, failureReason, settledAt: FieldValue.serverTimestamp() });
    if (status === "pending") return;
    tx.update(payRef, {
      refundPendingCents: FieldValue.increment(-amountCents),
      ...(status === "succeeded" ? { refundedCents: FieldValue.increment(amountCents) } : {}),
      updatedAt: FieldValue.serverTimestamp(),
    });
    if (status === "succeeded" && order.exists) {
      const next = { ...sums, refunded: sums.refunded + amountCents };
      tx.update(orderDocRef, {
        paymentStatus: paymentStatusFor(next, totalCentsOf(order.data()!)),
        updatedAt: FieldValue.serverTimestamp(),
      });
    }
    audit(tx, ref.orgId, {
      action: status === "succeeded" ? "payment.refunded" : "payment.refund_failed",
      actorUid: uid,
      actorKind,
      locationId: ref.locationId,
      target: { orderId: ref.orderId, paymentId, refundId: id, amountCents, failureReason },
    });
  });
  return { refundId: id, status };
}

/** Voids an order that has no money on it. Paid orders are refunded first. */
export async function voidOrder(caller: Caller, data: unknown, pepper: string): Promise<{ ok: true }> {
  const uid = requireUid(caller);
  const input = asInput(data);
  const ref = orderRef(input);
  const reason = str(input, "reason", { min: 3, max: 200 });
  const { approvedBy, actorKind } = await requireElevated(ref, uid, input, pepper);

  await db().runTransaction(async (tx) => {
    await requireWritableOrg(tx, ref.orgId);
    const orderDocRef = db().doc(paymentPaths.order(ref.orgId, ref.locationId, ref.orderId));
    const [order, sums] = await Promise.all([tx.get(orderDocRef), sumPayments(tx, ref)]);
    if (!order.exists) throw fail.notFound("Order not found.");
    if (order.get("status") === "voided") return;
    if (sums.pending > 0) throw fail.precondition("A card payment on this order is still in progress.");
    if (sums.succeeded - sums.refunded > 0) throw fail.precondition("Refund this order's payments before voiding it.");
    tx.update(orderDocRef, {
      status: "voided",
      voidedBy: approvedBy,
      voidReason: reason,
      voidedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    audit(tx, ref.orgId, {
      action: "order.voided",
      actorUid: uid,
      actorKind,
      staffUid: approvedBy === uid ? null : approvedBy,
      locationId: ref.locationId,
      reason,
      target: { orderId: ref.orderId },
    });
  });
  return { ok: true };
}

// ---------------------------------------------------------------------------
// Scheduled recovery
// ---------------------------------------------------------------------------

/** Ask the provider about payments left pending longer than this. */
export const RECOVER_AFTER_MS = 2 * 60 * 1000;
/** A charge the provider never saw is failed after this. */
export const ABANDON_AFTER_MS = 15 * 60 * 1000;
/** Still pending at the provider after this needs a person. */
export const STUCK_AFTER_MS = 30 * 60 * 1000;

export interface RecoveryReport {
  checked: number;
  settled: number;
  abandoned: number;
  stuck: number;
}

/**
 * Settles card payments interrupted by a dropped connection, a closed app or
 * a crashed Function. Runs every 10 minutes.
 */
export async function recoverPendingPayments(registry: ProviderRegistry, now = Date.now()): Promise<RecoveryReport> {
  const report: RecoveryReport = { checked: 0, settled: 0, abandoned: 0, stuck: 0 };
  const due = await db()
    .collectionGroup("payments")
    .where("status", "==", "pending")
    .where("updatedAt", "<=", Timestamp.fromMillis(now - RECOVER_AFTER_MS))
    .limit(200)
    .get();
  for (const doc of due.docs) {
    report.checked++;
    const pay = doc.data();
    const ref: OrderRef = { orgId: pay.orgId, locationId: pay.locationId, orderId: pay.orderId };
    const age = now - ((pay.createdAt as Timestamp | undefined)?.toMillis() ?? now);
    try {
      const result = await registry(pay.provider as ProviderId).lookup({
        idempotencyKey: pay.idempotencyKey,
        providerRef: pay.providerRef ?? null,
        terminalRef: pay.terminalRef ?? null,
      });
      if (result && result.status !== "pending") {
        await settlePayment(ref, doc.id, result);
        report.settled++;
      } else if (!result && age >= ABANDON_AFTER_MS) {
        await settlePayment(ref, doc.id, { status: "failed", providerRef: null, failureReason: "not_received" });
        report.abandoned++;
      } else if (age >= STUCK_AFTER_MS && !pay.stuckReported) {
        await doc.ref.update({ stuckReported: true });
        await recordIncident("payment_stuck", "Card payment still pending at the provider", { ...ref, paymentId: doc.id });
        report.stuck++;
      }
    } catch (err) {
      logger.error("Payment recovery failed", { ...ref, paymentId: doc.id, err: String(err) });
    }
  }
  if (report.checked > 0) logger.info("Payment recovery", { ...report });
  return report;
}
