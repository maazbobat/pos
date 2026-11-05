/**
 * Stripe Terminal, server-driven: the Function creates a card_present
 * PaymentIntent on the restaurant's own Stripe account (Stripe Connect,
 * the same account its online orders are paid into) and asks the reader
 * registered for the counter to collect it. The tablet never talks to the
 * reader; it polls refreshPayment while the guest taps, inserts or swipes.
 *
 * Works with Stripe's internet-connected smart readers (Stripe Reader S700,
 * BBPOS WisePOS E), which take Visa, Mastercard, Amex and Interac debit.
 *
 * Idempotency: the PaymentIntent is created with our idempotency key, and
 * the key is in its metadata so `lookup` can find a charge whose answer we
 * never got, even without Stripe's payment ID.
 *
 * Interac refunds have to be done with the guest's card on the reader
 * (Interac's rule), so `refund` refuses them with "interac_needs_card"; the
 * manager refunds those from the Stripe dashboard or the reader for now.
 */
import Stripe from "stripe";
import {
  type ChargeRef,
  type ChargeRequest,
  type ChargeResult,
  type PaymentProvider,
  ProviderNotConfigured,
  type RefundRequest,
  type RefundResult,
} from "./provider.js";

/** The parts of a PaymentIntent we read. */
export interface TerminalIntent {
  id: string;
  status: Stripe.PaymentIntent.Status;
  amount: number;
  metadata: Record<string, string>;
  lastErrorCode: string | null;
  /** The card type of the charge that went through: "card_present" or "interac_present". */
  chargeMethod: string | null;
}

export interface CreateIntent {
  amountCents: number;
  metadata: Record<string, string>;
  description: string;
}

/**
 * The Stripe calls this provider makes, on one connected account. Narrow on
 * purpose, so tests swap in a fake and never touch a real Stripe account.
 */
export interface TerminalApi {
  createIntent(account: string, req: CreateIntent, idempotencyKey: string): Promise<TerminalIntent>;
  retrieveIntent(account: string, id: string): Promise<TerminalIntent>;
  findIntentByKey(account: string, key: string): Promise<TerminalIntent | null>;
  cancelIntent(account: string, id: string): Promise<TerminalIntent>;
  processOnReader(account: string, readerId: string, intentId: string): Promise<void>;
  cancelReaderAction(account: string, readerId: string): Promise<void>;
  refund(account: string, intentId: string, amountCents: number, idempotencyKey: string): Promise<{ id: string; status: string | null }>;
}

/** Reader errors that mean the reader never started collecting: safe to call the charge failed. */
const READER_NEVER_STARTED = new Set(["terminal_reader_offline", "terminal_reader_busy"]);

export class TerminalError extends Error {
  constructor(readonly code: string, message: string) {
    super(message);
  }
}

export function intentResult(pi: TerminalIntent): ChargeResult {
  switch (pi.status) {
    case "succeeded":
      return { status: "succeeded", providerRef: pi.id };
    case "canceled":
      return { status: "canceled", providerRef: pi.id };
    case "requires_payment_method":
      // A decline leaves the intent waiting for another card, with the error on it.
      return pi.lastErrorCode
        ? { status: "failed", providerRef: pi.id, failureReason: pi.lastErrorCode }
        : { status: "pending", providerRef: pi.id };
    default:
      // processing, requires_confirmation, requires_action, requires_capture
      return { status: "pending", providerRef: pi.id };
  }
}

export class StripeTerminalProvider implements PaymentProvider {
  readonly id = "stripe_terminal" as const;

  /** `api` is null when STRIPE_SECRET_KEY isn't set for this project. */
  constructor(private readonly api: TerminalApi | null) {}

  private need(account: string | null | undefined): { api: TerminalApi; account: string } {
    if (!this.api) throw new ProviderNotConfigured("stripe_terminal", "Stripe isn't set up for this project.");
    if (!account) {
      throw new ProviderNotConfigured("stripe_terminal", "the owner hasn't connected the restaurant's Stripe account.");
    }
    return { api: this.api, account };
  }

  async charge(req: ChargeRequest): Promise<ChargeResult> {
    const { api, account } = this.need(req.account);
    if (!req.terminalRef) throw new ProviderNotConfigured("stripe_terminal", "pick a card reader.");
    const pi = await api.createIntent(account, {
      amountCents: req.amountCents + req.tipCents,
      description: `Order ${req.orderId}`,
      metadata: {
        orgId: req.orgId,
        locationId: req.locationId,
        orderId: req.orderId,
        paymentId: req.paymentId,
        idempotencyKey: req.idempotencyKey,
        tipCents: String(req.tipCents),
      },
    }, `terminal-${req.idempotencyKey}`);
    // A retry of an attempt that already finished gets the finished answer.
    const known = intentResult(pi);
    if (known.status !== "pending") return known;
    try {
      await api.processOnReader(account, req.terminalRef, pi.id);
    } catch (err) {
      if (err instanceof TerminalError && READER_NEVER_STARTED.has(err.code)) {
        await api.cancelIntent(account, pi.id).catch(() => undefined);
        return { status: "failed", providerRef: pi.id, failureReason: err.code.replace("terminal_", "") };
      }
      // Timeouts and dropped connections: the reader may be collecting.
      throw err;
    }
    return { status: "pending", providerRef: pi.id };
  }

  async lookup(ref: ChargeRef): Promise<ChargeResult | null> {
    const { api, account } = this.need(ref.account);
    const pi = ref.providerRef
      ? await api.retrieveIntent(account, ref.providerRef)
      : await api.findIntentByKey(account, ref.idempotencyKey);
    if (!pi) return null;
    const result = intentResult(pi);
    if (result.status === "failed") {
      // Close the intent so a later tap can't charge an attempt we've called failed.
      await api.cancelIntent(account, pi.id).catch(() => undefined);
    }
    return result;
  }

  async cancel(ref: ChargeRef): Promise<ChargeResult> {
    const { api, account } = this.need(ref.account);
    const pi = ref.providerRef
      ? await api.retrieveIntent(account, ref.providerRef)
      : await api.findIntentByKey(account, ref.idempotencyKey);
    if (!pi) return { status: "canceled", providerRef: null };
    const now = intentResult(pi);
    if (now.status === "succeeded" || now.status === "canceled") return now;
    if (ref.terminalRef) await api.cancelReaderAction(account, ref.terminalRef).catch(() => undefined);
    try {
      return intentResult(await api.cancelIntent(account, pi.id));
    } catch {
      // The guest tapped just before the cancel: report what really happened.
      return intentResult(await api.retrieveIntent(account, pi.id));
    }
  }

  async refund(req: RefundRequest): Promise<RefundResult> {
    const { api, account } = this.need(req.account);
    if (!req.providerRef) return { status: "failed", providerRef: null, failureReason: "no_charge" };
    const pi = await api.retrieveIntent(account, req.providerRef);
    if (pi.chargeMethod === "interac_present") {
      return { status: "failed", providerRef: null, failureReason: "interac_needs_card" };
    }
    const r = await api.refund(account, pi.id, req.amountCents, `refund-${req.idempotencyKey}`);
    const status = r.status === "succeeded" ? "succeeded" : r.status === "pending" ? "pending" : "failed";
    return { status, providerRef: r.id, failureReason: status === "failed" ? (r.status ?? "refund_failed") : null };
  }
}

// ---------------------------------------------------------------------------
// The real Stripe calls
// ---------------------------------------------------------------------------

function toIntent(pi: Stripe.PaymentIntent): TerminalIntent {
  const charge = typeof pi.latest_charge === "object" && pi.latest_charge !== null ? pi.latest_charge : null;
  return {
    id: pi.id,
    status: pi.status,
    amount: pi.amount,
    metadata: (pi.metadata ?? {}) as Record<string, string>,
    lastErrorCode: pi.last_payment_error?.decline_code ?? pi.last_payment_error?.code ?? null,
    chargeMethod: charge?.payment_method_details?.type ?? null,
  };
}

function wrapReaderError(err: unknown): never {
  if (err instanceof Stripe.errors.StripeError && err.code?.startsWith("terminal_reader")) {
    throw new TerminalError(err.code, err.message);
  }
  throw err;
}

export function stripeTerminalApi(stripe: Stripe): TerminalApi {
  const on = (account: string) => ({ stripeAccount: account });
  const expand = ["latest_charge"];
  return {
    async createIntent(account, req, idempotencyKey) {
      const pi = await stripe.paymentIntents.create({
        amount: req.amountCents,
        currency: "cad",
        // Interac debit is how most Canadians pay at the counter.
        allowed_payment_method_types: ["card_present", "interac_present"],
        capture_method: "automatic",
        description: req.description,
        metadata: req.metadata,
        expand,
      }, { ...on(account), idempotencyKey });
      return toIntent(pi);
    },
    async retrieveIntent(account, id) {
      return toIntent(await stripe.paymentIntents.retrieve(id, { expand }, on(account)));
    },
    async findIntentByKey(account, key) {
      // Keys are letters, digits, - and _ (checked in handlers/payments.ts), so this can't break the query.
      const found = await stripe.paymentIntents.search({ query: `metadata['idempotencyKey']:'${key}'`, limit: 1 }, on(account));
      const pi = found.data[0];
      return pi ? this.retrieveIntent(account, pi.id) : null;
    },
    async cancelIntent(account, id) {
      return toIntent(await stripe.paymentIntents.cancel(id, { expand }, on(account)));
    },
    async processOnReader(account, readerId, intentId) {
      await stripe.terminal.readers.processPaymentIntent(readerId, { payment_intent: intentId }, on(account))
        .catch(wrapReaderError);
    },
    async cancelReaderAction(account, readerId) {
      await stripe.terminal.readers.cancelAction(readerId, {}, on(account)).catch(wrapReaderError);
    },
    async refund(account, intentId, amountCents, idempotencyKey) {
      const r = await stripe.refunds.create({ payment_intent: intentId, amount: amountCents }, { ...on(account), idempotencyKey });
      return { id: r.id, status: r.status };
    },
  };
}

// ---------------------------------------------------------------------------
// Registering readers
// ---------------------------------------------------------------------------

export interface ReaderAddress {
  line1: string;
  city: string;
  province: string;
  postalCode: string;
}

/** Setting up readers, used by the registerCardReader Function. */
export interface ReaderSetupApi {
  createLocation(account: string, name: string, address: ReaderAddress): Promise<string>;
  registerReader(account: string, registrationCode: string, label: string, stripeLocationId: string):
    Promise<{ id: string; deviceType: string }>;
}

export function stripeReaderSetupApi(stripe: Stripe): ReaderSetupApi {
  return {
    async createLocation(account, name, address) {
      const loc = await stripe.terminal.locations.create({
        display_name: name,
        address: { line1: address.line1, city: address.city, state: address.province, postal_code: address.postalCode, country: "CA" },
      }, { stripeAccount: account });
      return loc.id;
    },
    async registerReader(account, registrationCode, label, stripeLocationId) {
      const reader = await stripe.terminal.readers.create(
        { registration_code: registrationCode, label, location: stripeLocationId },
        { stripeAccount: account },
      );
      return { id: reader.id, deviceType: reader.device_type };
    },
  };
}
