import { Timestamp } from "firebase-admin/firestore";
import Stripe from "stripe";
import { beforeEach, describe, expect, it } from "vitest";
import { deriveAccess, GRACE_DAYS, TRIAL_DAYS } from "../src/billing/access.js";
import type { BillingGateway } from "../src/billing/gateway.js";
import {
  enforceBillingAccess,
  extendTrial,
  handleStripeEvent,
  openBillingPortal,
  setManualPlan,
  startCheckout,
  type StripeEventLike,
  verifyStripeEvent,
} from "../src/handlers/billing.js";
import { createLocation, createOrganization } from "../src/handlers/orgs.js";
import { auditActions, caller, db, expectHttpsError, PLATFORM_ADMIN, resetEmulators, seed, setOrg, u } from "./setup.js";

const DAY = 24 * 60 * 60 * 1000;

beforeEach(async () => {
  await resetEmulators();
  await seed();
});

class FakeGateway implements BillingGateway {
  customers: string[] = [];
  checkouts: { customerId: string; plan: string; successUrl: string }[] = [];
  async createCustomer(input: { orgId: string }) {
    const id = `cus_test_${input.orgId}`;
    this.customers.push(id);
    return id;
  }
  async createCheckoutSession(input: { customerId: string; plan: string; successUrl: string }) {
    this.checkouts.push(input);
    return { url: `https://checkout.stripe.test/${input.plan}` };
  }
  async createPortalSession(input: { customerId: string }) {
    return { url: `https://billing.stripe.test/${input.customerId}` };
  }
}
const urls = { managerAppUrl: "https://manager.example" };

const sub = () => db().doc("orgs/org-a/billing/subscription").get().then((s) => s.data()!);
const org = () => db().doc("orgs/org-a").get().then((s) => s.data()!);

/** Org A on a Stripe subscription with customer cus_a. */
async function linkStripe(fields: Record<string, unknown> = {}) {
  await db().doc("stripeCustomers/cus_a").set({ orgId: "org-a" });
  await db().doc("orgs/org-a/billing/subscription").set({
    orgId: "org-a", source: "stripe", status: "active", plan: "professional",
    stripeCustomerId: "cus_a", stripeSubscriptionId: "sub_1", ...fields,
  });
}

let eventNo = 0;
function subEvent(
  status: string,
  opts: { created?: number; type?: string; subId?: string; lookupKey?: string; orgId?: string; customer?: string } = {},
): StripeEventLike {
  const created = opts.created ?? Math.floor(Date.now() / 1000);
  return {
    id: `evt_${++eventNo}`,
    type: opts.type ?? "customer.subscription.updated",
    created,
    data: {
      object: {
        id: opts.subId ?? "sub_1",
        customer: opts.customer ?? "cus_a",
        status,
        cancel_at_period_end: false,
        metadata: { orgId: opts.orgId ?? "org-a" },
        items: {
          data: [{
            current_period_end: created + 30 * 86400,
            price: { id: "price_pro", lookup_key: opts.lookupKey ?? "pos_professional_monthly_cad" },
          }],
        },
      },
    },
  };
}

describe("deriveAccess", () => {
  const now = Date.UTC(2026, 10, 5);
  it("gives full access while trialing or active", () => {
    expect(deriveAccess({ source: "stripe", status: "active", trialEndsAt: null, lapsedAt: null }, now))
      .toMatchObject({ accessLevel: "full", inGoodStanding: true, accessReviewAt: null });
    expect(deriveAccess({ source: "trial", status: "trialing", trialEndsAt: now + DAY, lapsedAt: null }, now))
      .toMatchObject({ accessLevel: "full", accessReviewAt: now + DAY });
  });

  it("keeps full access through the grace period, then goes read-only", () => {
    const lapsed = { source: "stripe" as const, status: "past_due" as const, trialEndsAt: null, lapsedAt: now };
    expect(deriveAccess(lapsed, now + (GRACE_DAYS - 1) * DAY)).toMatchObject({
      accessLevel: "full", inGoodStanding: false, graceEndsAt: now + GRACE_DAYS * DAY,
    });
    expect(deriveAccess(lapsed, now + GRACE_DAYS * DAY)).toMatchObject({ accessLevel: "read_only", accessReviewAt: null });
  });

  it("starts the grace period when the trial ended, not when someone noticed", () => {
    const trial = { source: "trial" as const, status: "trialing" as const, trialEndsAt: now, lapsedAt: null };
    expect(deriveAccess(trial, now + 3 * DAY)).toMatchObject({ lapsedAt: now, graceEndsAt: now + GRACE_DAYS * DAY });
  });
});

describe("new orgs", () => {
  it("start on a free trial, with a platform summary and a platform audit entry", async () => {
    const before = Date.now();
    const { orgId } = await createOrganization(caller(PLATFORM_ADMIN), {
      name: "Harbour Grill", type: "independent", ownerEmail: "pat@harbour.example",
    });
    const billing = (await db().doc(`orgs/${orgId}/billing/subscription`).get()).data()!;
    expect(billing).toMatchObject({ source: "trial", status: "trialing", plan: "trial", accessLevel: "full" });
    const trialEnds = (billing.trialEndsAt as Timestamp).toMillis();
    expect(trialEnds - before).toBeGreaterThanOrEqual(TRIAL_DAYS * DAY - 1000);
    expect((billing.accessReviewAt as Timestamp).toMillis()).toBe(trialEnds);

    expect((await db().doc(`platformOrgs/${orgId}`).get()).data()).toMatchObject({
      name: "Harbour Grill", status: "active", plan: "trial", ownerEmail: "pat@harbour.example", locationCount: 0,
    });
    const platformLog = await db().collection("platformAuditLog").where("orgId", "==", orgId).get();
    expect(platformLog.docs.map((d) => d.get("action"))).toEqual(["org.created"]);
    expect(platformLog.docs[0].get("actorKind")).toBe("platform_admin");
  });

  it("count locations in the platform summary", async () => {
    await createLocation(caller(u.ownerA), { orgId: "org-a", name: "Waterloo", province: "ON", timezone: "America/Toronto" });
    expect((await db().doc("platformOrgs/org-a").get()).get("locationCount")).toBe(1);
  });
});

describe("enforceBillingAccess", () => {
  it("lets a lapsed trial run through grace, then makes the org read-only but readable", async () => {
    const trialEnded = Date.now() - DAY;
    await db().doc("orgs/org-a/billing/subscription").set({
      orgId: "org-a", source: "trial", status: "trialing", plan: "trial",
      trialEndsAt: Timestamp.fromMillis(trialEnded), accessReviewAt: Timestamp.fromMillis(trialEnded),
    });

    await enforceBillingAccess();
    expect(await sub()).toMatchObject({ accessLevel: "full" });
    expect((await sub()).graceEndsAt.toMillis()).toBe(trialEnded + GRACE_DAYS * DAY);
    expect((await org()).accessLevel).toBe("full");

    expect(await enforceBillingAccess(trialEnded + GRACE_DAYS * DAY + 1)).toBe(1);
    expect((await org()).accessLevel).toBe("read_only");
    expect(await sub()).toMatchObject({ accessLevel: "read_only", accessReviewAt: null });
    expect((await db().doc("platformOrgs/org-a").get()).get("accessLevel")).toBe("read_only");
    expect(await auditActions("org-a")).toContain("billing.read_only");

    // Writes through Functions stop too.
    await expectHttpsError(
      createLocation(caller(u.ownerA), { orgId: "org-a", name: "Guelph", province: "ON", timezone: "America/Toronto" }),
      "failed-precondition",
    );
  });

  it("leaves orgs alone until their review time", async () => {
    await linkStripe({ accessReviewAt: null });
    expect(await enforceBillingAccess()).toBe(0);
  });
});

describe("Stripe webhook", () => {
  const secret = "whsec_test_only";
  const stripe = new Stripe("sk_test_not_a_real_key");

  it("accepts only events signed with the webhook secret", () => {
    const payload = JSON.stringify(subEvent("active"));
    const good = stripe.webhooks.generateTestHeaderString({ payload, secret });
    expect(verifyStripeEvent(payload, good, secret).type).toBe("customer.subscription.updated");

    const forged = stripe.webhooks.generateTestHeaderString({ payload, secret: "whsec_attacker" });
    expect(() => verifyStripeEvent(payload, forged, secret)).toThrow();
    expect(() => verifyStripeEvent(payload.replace("active", "canceled"), good, secret)).toThrow();
    expect(() => verifyStripeEvent(payload, "", secret)).toThrow();
  });

  it("applies a subscription, and Stripe's retries are no-ops", async () => {
    await linkStripe({ status: "incomplete", plan: "trial" });
    await setOrg("org-a", { plan: "trial" });
    const event = subEvent("active");
    expect(await handleStripeEvent(event)).toBe("applied");
    expect(await sub()).toMatchObject({ source: "stripe", status: "active", plan: "professional", accessLevel: "full" });
    expect((await org()).plan).toBe("professional");
    expect(await handleStripeEvent(event)).toBe("duplicate");
    expect((await auditActions("org-a")).filter((a) => a === "billing.plan_changed")).toHaveLength(1);
  });

  it("ignores an event older than the last one applied", async () => {
    await linkStripe();
    const now = Math.floor(Date.now() / 1000);
    expect(await handleStripeEvent(subEvent("past_due", { created: now }))).toBe("applied");
    expect(await handleStripeEvent(subEvent("active", { created: now - 60 }))).toBe("stale");
    expect((await sub()).status).toBe("past_due");
  });

  it("gives a failed payment the grace period, then read-only, then restores on payment", async () => {
    await linkStripe();
    const t0 = Date.now();
    await handleStripeEvent(subEvent("past_due"), t0);
    expect(await sub()).toMatchObject({ status: "past_due", accessLevel: "full" });
    expect((await sub()).graceEndsAt.toMillis()).toBe(t0 + GRACE_DAYS * DAY);

    // Another retry email from Stripe doesn't restart the clock.
    await handleStripeEvent(subEvent("unpaid"), t0 + 5 * DAY);
    expect((await sub()).lapsedAt.toMillis()).toBe(t0);

    await enforceBillingAccess(t0 + GRACE_DAYS * DAY + 1);
    expect((await org()).accessLevel).toBe("read_only");

    await handleStripeEvent(subEvent("active", { created: Math.floor(Date.now() / 1000) + 10 }), t0 + 20 * DAY);
    expect(await sub()).toMatchObject({ accessLevel: "full", lapsedAt: null, graceEndsAt: null });
    expect((await org()).accessLevel).toBe("full");
    expect(await auditActions("org-a")).toEqual(expect.arrayContaining(["billing.read_only", "billing.access_restored"]));
  });

  it("treats a deleted subscription as cancelled", async () => {
    await linkStripe();
    await handleStripeEvent(subEvent("active", { type: "customer.subscription.deleted" }));
    expect(await sub()).toMatchObject({ status: "canceled", accessLevel: "full" });
    expect((await sub()).graceEndsAt).not.toBeNull();
  });

  it("doesn't let an old subscription's cancellation override the new one", async () => {
    await linkStripe({ stripeSubscriptionId: "sub_new" });
    expect(await handleStripeEvent(subEvent("canceled", { subId: "sub_old", type: "customer.subscription.deleted" })))
      .toBe("stale");
    expect((await sub()).status).toBe("active");
  });

  it("refuses events for unknown customers or naming another org, and records an incident", async () => {
    await linkStripe();
    expect(await handleStripeEvent(subEvent("active", { customer: "cus_unknown" }))).toBe("unmatched");
    expect(await handleStripeEvent(subEvent("canceled", { orgId: "org-b" }))).toBe("unmatched");
    expect((await sub()).status).toBe("active");
    const incidents = await db().collection("platformIncidents").get();
    expect(incidents.docs.map((d) => d.get("kind"))).toEqual(["stripe_webhook_unmatched", "stripe_webhook_unmatched"]);
  });

  it("records invoices without changing access", async () => {
    await linkStripe();
    const invoice: StripeEventLike = {
      id: "evt_inv", type: "invoice.payment_failed", created: Math.floor(Date.now() / 1000),
      data: { object: { id: "in_1", customer: "cus_a", amount_due: 14900 } },
    };
    expect(await handleStripeEvent(invoice)).toBe("applied");
    expect((await sub()).lastInvoice).toMatchObject({ id: "in_1", paid: false, amountDueCents: 14900 });
    expect((await org()).accessLevel).toBe("full");
    expect(await auditActions("org-a")).toEqual(["billing.payment_failed"]);
  });
});

describe("startCheckout and openBillingPortal", () => {
  it("are owner only", async () => {
    const gw = new FakeGateway();
    await expectHttpsError(startCheckout(caller(u.managerCam), { orgId: "org-a", plan: "starter" }, gw, urls), "permission-denied");
    await expectHttpsError(startCheckout(caller(u.ownerB), { orgId: "org-a", plan: "starter" }, gw, urls), "permission-denied");
    await expectHttpsError(openBillingPortal(caller(u.franchiseCam), { orgId: "org-a" }, gw, urls), "permission-denied");
  });

  it("creates one Stripe customer per org, linked server-side, with fixed return URLs", async () => {
    const gw = new FakeGateway();
    const { url } = await startCheckout(caller(u.ownerA), { orgId: "org-a", plan: "starter", successUrl: "https://evil.example" }, gw, urls);
    expect(url).toBe("https://checkout.stripe.test/starter");
    expect(gw.checkouts[0].successUrl).toBe("https://manager.example/billing?org=org-a&checkout=done");
    expect((await db().doc("stripeCustomers/cus_test_org-a").get()).get("orgId")).toBe("org-a");
    expect((await sub()).stripeCustomerId).toBe("cus_test_org-a");

    await startCheckout(caller(u.ownerA), { orgId: "org-a", plan: "professional" }, gw, urls);
    expect(gw.customers).toHaveLength(1);
    expect(await auditActions("org-a")).toEqual(["billing.checkout_started", "billing.checkout_started"]);
  });

  it("works while read-only, so a lapsed owner can pay", async () => {
    await setOrg("org-a", { accessLevel: "read_only" });
    await startCheckout(caller(u.ownerA), { orgId: "org-a", plan: "professional" }, new FakeGateway(), urls);
  });

  it("refuses a second subscription and franchise plans", async () => {
    const gw = new FakeGateway();
    await expectHttpsError(startCheckout(caller(u.ownerA), { orgId: "org-a", plan: "franchise" }, gw, urls), "invalid-argument");
    await linkStripe();
    await expectHttpsError(startCheckout(caller(u.ownerA), { orgId: "org-a", plan: "starter" }, gw, urls), "failed-precondition");
    expect((await openBillingPortal(caller(u.ownerA), { orgId: "org-a" }, gw, urls)).url).toBe("https://billing.stripe.test/cus_a");
  });
});

describe("platform admin billing tools", () => {
  it("setManualPlan is platform admin only and is audited in both logs", async () => {
    const input = { orgId: "org-a", plan: "franchise", active: true, reason: "Signed franchise deal" };
    await expectHttpsError(setManualPlan(caller(u.ownerA), input), "permission-denied");
    await setManualPlan(caller(PLATFORM_ADMIN), input);
    expect(await sub()).toMatchObject({ source: "manual", status: "active", plan: "franchise", accessLevel: "full" });
    expect((await org()).plan).toBe("franchise");
    expect(await auditActions("org-a")).toEqual(["billing.manual_plan_set", "billing.plan_changed"]);
    const platform = await db().collection("platformAuditLog").get();
    expect(platform.docs[0].data()).toMatchObject({ action: "billing.manual_plan_set", reason: "Signed franchise deal" });
  });

  it("setManualPlan won't override a live Stripe subscription", async () => {
    await linkStripe();
    await expectHttpsError(
      setManualPlan(caller(PLATFORM_ADMIN), { orgId: "org-a", plan: "starter", active: true, reason: "comp" }),
      "failed-precondition",
    );
  });

  it("extendTrial pushes the end out and forgives a lapse", async () => {
    const ended = Date.now() - 20 * DAY;
    await db().doc("orgs/org-a/billing/subscription").set({
      orgId: "org-a", source: "trial", status: "trialing", plan: "trial", trialEndsAt: Timestamp.fromMillis(ended),
      lapsedAt: Timestamp.fromMillis(ended),
    });
    await setOrg("org-a", { accessLevel: "read_only", plan: "trial" });
    await expectHttpsError(extendTrial(caller(u.ownerA), { orgId: "org-a", days: 14, reason: "pilot" }), "permission-denied");
    await expectHttpsError(extendTrial(caller(PLATFORM_ADMIN), { orgId: "org-a", days: 365, reason: "pilot" }), "invalid-argument");

    const { trialEndsAt } = await extendTrial(caller(PLATFORM_ADMIN), { orgId: "org-a", days: 14, reason: "pilot" });
    expect(trialEndsAt).toBeGreaterThan(Date.now() + 13 * DAY);
    expect(await sub()).toMatchObject({ accessLevel: "full", lapsedAt: null });
    expect((await org()).accessLevel).toBe("full");
  });
});
