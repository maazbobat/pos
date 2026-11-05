/**
 * Outbound calls to Stripe Billing, behind an interface so the Functions are
 * tested with a fake and never with real keys. Inbound state only ever
 * arrives through the verified webhook (handlers/billing.ts).
 */
import type Stripe from "stripe";
import { fail } from "../lib/errors.js";
import { PRICE_LOOKUP_KEYS, type SelfServePlan } from "./access.js";

export interface BillingGateway {
  createCustomer(input: { orgId: string; name: string; email: string | null }): Promise<string>;
  createCheckoutSession(input: {
    customerId: string;
    orgId: string;
    plan: SelfServePlan;
    successUrl: string;
    cancelUrl: string;
  }): Promise<{ url: string }>;
  createPortalSession(input: { customerId: string; returnUrl: string }): Promise<{ url: string }>;
}

export class StripeBillingGateway implements BillingGateway {
  constructor(private readonly stripe: Stripe) {}

  async createCustomer(input: { orgId: string; name: string; email: string | null }): Promise<string> {
    const customer = await this.stripe.customers.create(
      { name: input.name, email: input.email ?? undefined, metadata: { orgId: input.orgId } },
      // One customer per org, even if the owner double-clicks.
      { idempotencyKey: `customer-${input.orgId}` },
    );
    return customer.id;
  }

  async createCheckoutSession(input: {
    customerId: string;
    orgId: string;
    plan: SelfServePlan;
    successUrl: string;
    cancelUrl: string;
  }): Promise<{ url: string }> {
    const prices = await this.stripe.prices.list({ lookup_keys: [PRICE_LOOKUP_KEYS[input.plan]], active: true });
    const price = prices.data[0];
    if (!price) throw fail.precondition(`No active Stripe price for the ${input.plan} plan.`);
    const session = await this.stripe.checkout.sessions.create({
      mode: "subscription",
      customer: input.customerId,
      client_reference_id: input.orgId,
      line_items: [{ price: price.id, quantity: 1 }],
      subscription_data: { metadata: { orgId: input.orgId } },
      success_url: input.successUrl,
      cancel_url: input.cancelUrl,
    });
    if (!session.url) throw fail.precondition("Stripe did not return a checkout link.");
    return { url: session.url };
  }

  async createPortalSession(input: { customerId: string; returnUrl: string }): Promise<{ url: string }> {
    const session = await this.stripe.billingPortal.sessions.create({
      customer: input.customerId,
      return_url: input.returnUrl,
    });
    return { url: session.url };
  }
}
