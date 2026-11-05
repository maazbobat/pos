import { randomUUID } from "node:crypto";
import {
  type ChargeRef,
  type ChargeRequest,
  type ChargeResult,
  type PaymentProvider,
  ProviderNotConfigured,
  type ProviderRegistry,
  type RefundRequest,
  type RefundResult,
} from "./provider.js";

/** Cash changes hands at the counter, so every call succeeds at once. */
export class CashProvider implements PaymentProvider {
  readonly id = "cash" as const;
  async charge(req: ChargeRequest): Promise<ChargeResult> {
    return { status: "succeeded", providerRef: `cash_${req.idempotencyKey}` };
  }
  async lookup(ref: ChargeRef): Promise<ChargeResult | null> {
    return { status: "succeeded", providerRef: ref.providerRef ?? `cash_${ref.idempotencyKey}` };
  }
  async cancel(ref: ChargeRef): Promise<ChargeResult> {
    return { status: "canceled", providerRef: ref.providerRef };
  }
  async refund(req: RefundRequest): Promise<RefundResult> {
    return { status: "succeeded", providerRef: `cash_refund_${req.idempotencyKey}` };
  }
}

/**
 * Clover. Needs Clover's developer agreement and app certification before it
 * can be distributed, and a merchant's API token per location, all of which
 * Maaz is arranging. Until then this throws, so a location set to Clover
 * fails clearly instead of pretending to charge.
 *
 * The adapter will use Clover's REST Pay Display API to send a sale to the
 * location's Clover Flex, with our idempotency key as Clover's external
 * payment ID, so `lookup` can find a sale we never heard back about.
 */
export class CloverProvider implements PaymentProvider {
  readonly id = "clover" as const;
  private fail(): never {
    throw new ProviderNotConfigured("clover", "Clover integration is waiting on Clover's certification.");
  }
  charge(): Promise<ChargeResult> { this.fail(); }
  lookup(): Promise<ChargeResult | null> { this.fail(); }
  cancel(): Promise<ChargeResult> { this.fail(); }
  refund(): Promise<RefundResult> { this.fail(); }
}

/**
 * Stripe Terminal, for smart readers driven from the server: create a
 * card_present PaymentIntent with our idempotency key (and the key in its
 * metadata for `lookup`), then ask the reader to process it. Needs a Stripe
 * Terminal location and registered readers per store.
 */
export class StripeTerminalProvider implements PaymentProvider {
  readonly id = "stripe_terminal" as const;
  private fail(): never {
    throw new ProviderNotConfigured("stripe_terminal", "Stripe Terminal readers aren't registered yet.");
  }
  charge(): Promise<ChargeResult> { this.fail(); }
  lookup(): Promise<ChargeResult | null> { this.fail(); }
  cancel(): Promise<ChargeResult> { this.fail(); }
  refund(): Promise<RefundResult> { this.fail(); }
}

/**
 * Card payments made on the ordering site through Stripe Checkout on the
 * restaurant's connected Stripe account (orders/checkout.ts). Charges start
 * from Checkout, not from here. Refunds will call Stripe's refund API on the
 * connected account; until that is wired up and tested with a real test-mode
 * account, refund online orders from the Stripe dashboard.
 */
export class StripeOnlineProvider implements PaymentProvider {
  readonly id = "stripe_online" as const;
  private fail(): never {
    throw new ProviderNotConfigured("stripe_online", "online refunds aren't wired up yet; refund in Stripe.");
  }
  charge(): Promise<ChargeResult> { this.fail(); }
  lookup(): Promise<ChargeResult | null> { this.fail(); }
  cancel(): Promise<ChargeResult> { this.fail(); }
  refund(): Promise<RefundResult> { this.fail(); }
}

/**
 * A pretend card terminal for tests and the local emulators. Never
 * available in a deployed project (see defaultRegistry).
 *
 *   mode "approve"   charges succeed at once
 *   mode "decline"   charges fail
 *   mode "pending"   charges wait until settle() is called (a guest tapping slowly)
 *   mode "offline"   the call throws after the processor recorded it, like a
 *                    dropped connection: only lookup() learns the outcome
 */
export class FakeCardProvider implements PaymentProvider {
  readonly id = "fake_card" as const;
  mode: "approve" | "decline" | "pending" | "offline" = "approve";
  readonly charges = new Map<string, ChargeResult & { amountCents: number }>();
  readonly refunds = new Map<string, RefundResult & { amountCents: number }>();

  async charge(req: ChargeRequest): Promise<ChargeResult> {
    const existing = this.charges.get(req.idempotencyKey);
    if (existing) return { status: existing.status, providerRef: existing.providerRef };
    const providerRef = `fake_${randomUUID()}`;
    const status = this.mode === "approve" ? "succeeded"
      : this.mode === "decline" ? "failed"
      : this.mode === "offline" ? "succeeded"
      : "pending";
    this.charges.set(req.idempotencyKey, {
      status,
      providerRef,
      amountCents: req.amountCents + req.tipCents,
      failureReason: status === "failed" ? "card_declined" : null,
    });
    if (this.mode === "offline") throw new Error("connection reset");
    return { status, providerRef, failureReason: status === "failed" ? "card_declined" : null };
  }

  async lookup(ref: ChargeRef): Promise<ChargeResult | null> {
    const c = this.charges.get(ref.idempotencyKey);
    return c ? { status: c.status, providerRef: c.providerRef, failureReason: c.failureReason ?? null } : null;
  }

  async cancel(ref: ChargeRef): Promise<ChargeResult> {
    const c = this.charges.get(ref.idempotencyKey);
    if (c && c.status === "pending") c.status = "canceled";
    return { status: c?.status ?? "canceled", providerRef: c?.providerRef ?? ref.providerRef };
  }

  async refund(req: RefundRequest): Promise<RefundResult> {
    const existing = this.refunds.get(req.idempotencyKey);
    if (existing) return existing;
    const result = { status: "succeeded" as const, providerRef: `fake_refund_${randomUUID()}`, amountCents: req.amountCents };
    this.refunds.set(req.idempotencyKey, result);
    return result;
  }

  /** Finishes a pending charge, as if the guest tapped their card. */
  settle(idempotencyKey: string, status: "succeeded" | "failed"): void {
    const c = this.charges.get(idempotencyKey);
    if (c) c.status = status;
  }
}

/**
 * The providers a deployed Function uses. The fake terminal exists only
 * under the emulator, so a location can never be pointed at it in production.
 */
export function defaultRegistry(): ProviderRegistry {
  const cash = new CashProvider();
  const clover = new CloverProvider();
  const terminal = new StripeTerminalProvider();
  const online = new StripeOnlineProvider();
  const fake = process.env.FUNCTIONS_EMULATOR === "true" ? new FakeCardProvider() : null;
  return (id) => {
    switch (id) {
      case "cash": return cash;
      case "clover": return clover;
      case "stripe_terminal": return terminal;
      case "stripe_online": return online;
      case "fake_card":
        if (fake) return fake;
        throw new ProviderNotConfigured("fake_card", "the test terminal only runs on the emulator.");
    }
  };
}
