/**
 * Card payment for online orders: Stripe Checkout on the restaurant's own
 * Stripe account (Stripe Connect), so the money goes to the restaurant, not
 * to the platform. Behind an interface so tests never use real keys.
 *
 * The restaurant connects its Stripe account once; until Connect onboarding
 * is built, an owner pastes the account ID (acct_…) into the online ordering
 * settings. Paid and expired sessions come back through the verified
 * onlineCheckoutWebhook (handlers/online.ts).
 */
import type Stripe from "stripe";
import { fail } from "../lib/errors.js";

export interface OnlineCheckoutRequest {
  orgId: string;
  locationId: string;
  orderId: string;
  /** The restaurant's connected Stripe account. */
  stripeAccountId: string;
  /** Shown on the Stripe page, for example "Order W-417 at Maple Tea Cambridge". */
  description: string;
  /** The order total with tax, in cents. Priced by the server. */
  totalCents: number;
  customerEmail: string | null;
  successUrl: string;
  cancelUrl: string;
  /** Our order ID, so a retry returns the same session. */
  idempotencyKey: string;
}

export interface OnlineCheckoutGateway {
  createCheckout(req: OnlineCheckoutRequest): Promise<{ url: string; sessionId: string }>;
}

/** Unpaid sessions expire after this, which cancels the order. */
export const CHECKOUT_EXPIRES_MINUTES = 30;

export class StripeOnlineCheckoutGateway implements OnlineCheckoutGateway {
  constructor(private readonly stripe: Stripe) {}

  async createCheckout(req: OnlineCheckoutRequest): Promise<{ url: string; sessionId: string }> {
    const session = await this.stripe.checkout.sessions.create(
      {
        mode: "payment",
        currency: "cad",
        // One line with the server's total, tax included, so what Stripe
        // charges is exactly what the order says.
        line_items: [{
          quantity: 1,
          price_data: { currency: "cad", unit_amount: req.totalCents, product_data: { name: req.description } },
        }],
        customer_email: req.customerEmail ?? undefined,
        client_reference_id: req.orderId,
        metadata: { orgId: req.orgId, locationId: req.locationId, orderId: req.orderId },
        payment_intent_data: {
          metadata: { orgId: req.orgId, locationId: req.locationId, orderId: req.orderId },
        },
        expires_at: Math.floor(Date.now() / 1000) + CHECKOUT_EXPIRES_MINUTES * 60,
        success_url: req.successUrl,
        cancel_url: req.cancelUrl,
      },
      { stripeAccount: req.stripeAccountId, idempotencyKey: `online-${req.idempotencyKey}` },
    );
    if (!session.url) throw fail.precondition("Stripe did not return a checkout link.");
    return { url: session.url, sessionId: session.id };
  }
}
