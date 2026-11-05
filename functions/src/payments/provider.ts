/**
 * The PaymentProvider abstraction.
 *
 * Every way of taking money (cash, a Clover terminal, a Stripe Terminal
 * reader) sits behind one interface, so orders, refunds and recovery are
 * written once. Rules every provider follows:
 *
 * - No card data, ever. A provider returns only its own reference for the
 *   charge (a payment ID on the processor's side).
 * - Idempotent on `idempotencyKey`. Charging twice with the same key must
 *   return the first charge, so a retry after a dropped connection never
 *   charges a guest twice.
 * - `lookup` answers "what happened to the charge I started with this key?"
 *   even if we never heard back. That's how interrupted payments recover.
 * - Amounts are whole cents in CAD.
 *
 * Card providers are server-driven: the Function asks the processor to have
 * a specific terminal collect, and the tablet only shows progress. Cash is
 * recorded by the POS directly (it must work offline) and only refunds of
 * cash go through here.
 */

export const PROVIDER_IDS = ["cash", "clover", "stripe_terminal", "fake_card", "stripe_online"] as const;
/** Providers a location can pick for its counter terminals. stripe_online is the ordering site's. */
export const TERMINAL_PROVIDER_IDS = ["clover", "stripe_terminal", "fake_card"] as const;
export type ProviderId = (typeof PROVIDER_IDS)[number];

export type ChargeStatus = "pending" | "succeeded" | "failed" | "canceled";

export interface ChargeRequest {
  orgId: string;
  locationId: string;
  orderId: string;
  paymentId: string;
  /** What the order is charged, before tip. */
  amountCents: number;
  tipCents: number;
  currency: "cad";
  idempotencyKey: string;
  /** The processor's ID for the terminal or reader, from the location's payment settings. */
  terminalRef: string | null;
}

export interface ChargeResult {
  status: ChargeStatus;
  providerRef: string | null;
  failureReason?: string | null;
}

export interface ChargeRef {
  idempotencyKey: string;
  providerRef: string | null;
  terminalRef?: string | null;
}

export interface RefundRequest {
  paymentId: string;
  providerRef: string | null;
  amountCents: number;
  idempotencyKey: string;
}

export interface RefundResult {
  status: "pending" | "succeeded" | "failed";
  providerRef: string | null;
  failureReason?: string | null;
}

export interface PaymentProvider {
  readonly id: ProviderId;
  charge(req: ChargeRequest): Promise<ChargeResult>;
  /** null when the provider has no record of a charge with this key. */
  lookup(ref: ChargeRef): Promise<ChargeResult | null>;
  /** Stops a charge that hasn't completed (the guest walked away). */
  cancel(ref: ChargeRef): Promise<ChargeResult>;
  refund(req: RefundRequest): Promise<RefundResult>;
}

/** Thrown by a provider that isn't set up for this location yet. */
export class ProviderNotConfigured extends Error {
  constructor(readonly provider: ProviderId, detail: string) {
    super(`${provider} isn't set up: ${detail}`);
  }
}

export type ProviderRegistry = (id: ProviderId) => PaymentProvider;
