/**
 * Subscriptions: Stripe Checkout and the customer portal for owners, the
 * verified Stripe webhook that moves subscription state, manual plans and
 * trial extensions for the platform admin, and the hourly job that ends
 * grace periods.
 *
 * orgs/{orgId}/billing/subscription is written only here. Every change goes
 * through applyBilling, which derives org.accessLevel (billing/access.ts),
 * mirrors it to platformOrgs for the admin portal and audits any change of
 * plan or access.
 */
import { FieldValue, Timestamp, type DocumentData, type Transaction } from "firebase-admin/firestore";
import { logger } from "firebase-functions";
import Stripe from "stripe";
import {
  type BillingSource,
  type BillingStatus,
  deriveAccess,
  type Plan,
  PLANS,
  planForLookupKey,
  SELF_SERVE_PLANS,
  trialEnd,
} from "../billing/access.js";
import type { BillingGateway } from "../billing/gateway.js";
import { type ActorKind, audit, auditPlatform } from "../lib/audit.js";
import { fail } from "../lib/errors.js";
import { db } from "../lib/firebase.js";
import { platformPaths, recordIncident, syncPlatformOrg } from "../lib/platform.js";
import { type Caller, isPlatformAdmin, paths, requireActiveMember, requireUid } from "../lib/tenant.js";
import { asInput, docId, oneOf, str } from "../lib/validate.js";

export const subscriptionPath = (orgId: string) => `orgs/${orgId}/billing/subscription`;

const ms = (t: unknown): number | null => (t instanceof Timestamp ? t.toMillis() : null);
const ts = (n: number | null) => (n === null ? null : Timestamp.fromMillis(n));

interface BillingPatch {
  source?: BillingSource;
  status?: BillingStatus;
  plan?: Plan;
  trialEndsAt?: number | null;
  [field: string]: unknown;
}

interface Actor {
  uid: string;
  kind: ActorKind;
  reason?: string | null;
}

/**
 * Writes the subscription with its derived access, and the org's
 * accessLevel and plan. Callers read `prev` and `org` inside the same
 * transaction first (Firestore wants every read before any write).
 */
function applyBilling(
  tx: Transaction,
  orgId: string,
  prev: DocumentData,
  org: DocumentData,
  patch: BillingPatch,
  now: number,
  actor: Actor,
): { accessChanged: boolean } {
  const source = patch.source ?? (prev.source as BillingSource | undefined) ?? "trial";
  const status = patch.status ?? (prev.status as BillingStatus | undefined) ?? "trialing";
  const plan = patch.plan ?? (prev.plan as Plan | undefined) ?? "trial";
  const trialEndsAt = patch.trialEndsAt !== undefined ? patch.trialEndsAt : ms(prev.trialEndsAt);
  const access = deriveAccess({ source, status, trialEndsAt, lapsedAt: ms(prev.lapsedAt) }, now);

  const { trialEndsAt: _ignored, ...rest } = patch;
  tx.set(
    db().doc(subscriptionPath(orgId)),
    {
      ...rest,
      orgId,
      source,
      status,
      plan,
      trialEndsAt: ts(trialEndsAt),
      accessLevel: access.accessLevel,
      lapsedAt: ts(access.lapsedAt),
      graceEndsAt: ts(access.graceEndsAt),
      accessReviewAt: ts(access.accessReviewAt),
      updatedAt: FieldValue.serverTimestamp(),
    },
    { merge: true },
  );

  const changes: Record<string, unknown> = {};
  if (org.accessLevel !== access.accessLevel) changes.accessLevel = access.accessLevel;
  if (org.plan !== plan) changes.plan = plan;
  if (Object.keys(changes).length > 0) {
    tx.update(db().doc(paths.org(orgId)), { ...changes, updatedAt: FieldValue.serverTimestamp() });
  }
  syncPlatformOrg(tx, orgId, {
    accessLevel: access.accessLevel,
    plan,
    billingStatus: status,
    billingSource: source,
    graceEndsAt: ts(access.graceEndsAt),
    trialEndsAt: ts(trialEndsAt),
  });

  const event = {
    actorUid: actor.uid,
    actorKind: actor.kind,
    reason: actor.reason ?? null,
  };
  if (changes.plan !== undefined) {
    audit(tx, orgId, { ...event, action: "billing.plan_changed", target: { from: org.plan ?? null, to: plan } });
  }
  if (changes.accessLevel !== undefined) {
    audit(tx, orgId, {
      ...event,
      action: access.accessLevel === "read_only" ? "billing.read_only" : "billing.access_restored",
      target: { status, graceEndsAt: ts(access.graceEndsAt) },
    });
  }
  return { accessChanged: changes.accessLevel !== undefined };
}

/** New orgs start on the platform trial. Used by createOrganization. */
export function initialBilling(orgId: string, now: number) {
  const trialEndsAt = trialEnd(now);
  const access = deriveAccess({ source: "trial", status: "trialing", trialEndsAt, lapsedAt: null }, now);
  return {
    orgId,
    source: "trial" as const,
    status: "trialing" as const,
    plan: "trial" as const,
    trialEndsAt: Timestamp.fromMillis(trialEndsAt),
    accessLevel: access.accessLevel,
    lapsedAt: null,
    graceEndsAt: null,
    accessReviewAt: ts(access.accessReviewAt),
    stripeCustomerId: null,
    stripeSubscriptionId: null,
    createdAt: FieldValue.serverTimestamp(),
  };
}

async function readOrgAndBilling(tx: Transaction, orgId: string) {
  const [org, sub] = await Promise.all([
    tx.get(db().doc(paths.org(orgId))),
    tx.get(db().doc(subscriptionPath(orgId))),
  ]);
  if (!org.exists) throw fail.notFound("Organization not found.");
  return { org: org.data()!, sub: sub.data() ?? {} };
}

// ---------------------------------------------------------------------------
// Owner: Checkout and the billing portal
// ---------------------------------------------------------------------------

/** Where Stripe sends the owner back to. Fixed server-side, never taken from the request. */
export interface ReturnUrls {
  managerAppUrl: string;
}

async function requireBillingOwner(tx: Transaction, orgId: string, uid: string): Promise<DocumentData> {
  const member = await requireActiveMember(tx, orgId, uid);
  if (member.orgRole !== "owner") throw fail.denied("Only an owner can manage billing.");
  const { org, sub } = await readOrgAndBilling(tx, orgId);
  // Read-only orgs can still pay; suspension is a platform decision.
  if (org.status !== "active") throw fail.precondition("This organization is suspended.");
  return { org, sub };
}

/**
 * Starts Stripe Checkout for a self-serve plan. Allowed while read-only, so
 * a lapsed owner can pay their way back.
 */
export async function startCheckout(
  caller: Caller,
  data: unknown,
  gateway: BillingGateway,
  urls: ReturnUrls,
): Promise<{ url: string }> {
  const uid = requireUid(caller);
  const input = asInput(data);
  const orgId = docId(input, "orgId");
  const plan = oneOf(input, "plan", SELF_SERVE_PLANS);

  const { org, sub } = await db().runTransaction((tx) => requireBillingOwner(tx, orgId, uid));
  if (sub.source === "manual" && sub.status === "active") {
    throw fail.precondition("This plan is managed by the platform. Contact support to change it.");
  }
  if (sub.source === "stripe" && ["active", "trialing", "past_due"].includes(sub.status as string)) {
    throw fail.precondition("You already have a subscription. Change it from the billing portal.");
  }

  let customerId = sub.stripeCustomerId as string | null | undefined;
  if (!customerId) {
    customerId = await gateway.createCustomer({ orgId, name: org.name as string, email: caller.email ?? null });
    const id = customerId;
    await db().runTransaction(async (tx) => {
      tx.set(db().doc(platformPaths.stripeCustomer(id)), { orgId, createdAt: FieldValue.serverTimestamp() });
      tx.set(db().doc(subscriptionPath(orgId)), { stripeCustomerId: id }, { merge: true });
    });
  }

  const base = urls.managerAppUrl.replace(/\/$/, "");
  const session = await gateway.createCheckoutSession({
    customerId,
    orgId,
    plan,
    successUrl: `${base}/billing?org=${orgId}&checkout=done`,
    cancelUrl: `${base}/billing?org=${orgId}&checkout=cancelled`,
  });
  await db().runTransaction(async (tx) => {
    audit(tx, orgId, { action: "billing.checkout_started", actorUid: uid, target: { plan } });
  });
  return session;
}

export async function openBillingPortal(
  caller: Caller,
  data: unknown,
  gateway: BillingGateway,
  urls: ReturnUrls,
): Promise<{ url: string }> {
  const uid = requireUid(caller);
  const orgId = docId(asInput(data), "orgId");
  const { sub } = await db().runTransaction((tx) => requireBillingOwner(tx, orgId, uid));
  const customerId = sub.stripeCustomerId as string | null | undefined;
  if (!customerId) throw fail.precondition("There's no subscription to manage yet.");
  const base = urls.managerAppUrl.replace(/\/$/, "");
  return gateway.createPortalSession({ customerId, returnUrl: `${base}/billing?org=${orgId}` });
}

// ---------------------------------------------------------------------------
// Stripe webhook
// ---------------------------------------------------------------------------

/** The parts of a Stripe event we read. Verified by the caller (index.ts) before it gets here. */
export interface StripeEventLike {
  id: string;
  type: string;
  created: number;
  data: { object: Record<string, unknown> };
}

interface StripeSubscriptionLike {
  id: string;
  customer: string | { id: string };
  status: BillingStatus;
  cancel_at_period_end?: boolean;
  current_period_end?: number;
  metadata?: Record<string, string>;
  items?: { data?: { current_period_end?: number; price?: { id?: string; lookup_key?: string | null } }[] };
}

/**
 * Checks Stripe's signature over the raw request body. Throws on a missing,
 * wrong or expired (over 5 minutes old) signature.
 */
export function verifyStripeEvent(rawBody: Buffer | string, signature: string, secret: string): StripeEventLike {
  return Stripe.webhooks.constructEvent(rawBody, signature, secret) as unknown as StripeEventLike;
}

export type WebhookOutcome = "applied" | "duplicate" | "ignored" | "stale" | "unmatched";

const HANDLED = new Set([
  "checkout.session.completed",
  "customer.subscription.created",
  "customer.subscription.updated",
  "customer.subscription.deleted",
  "customer.subscription.paused",
  "customer.subscription.resumed",
  "invoice.paid",
  "invoice.payment_failed",
]);

const customerIdOf = (c: unknown): string | null =>
  typeof c === "string" ? c : c && typeof c === "object" && typeof (c as { id?: unknown }).id === "string"
    ? (c as { id: string }).id
    : null;

const GOOD = new Set<BillingStatus>(["active", "trialing"]);

/**
 * Applies one verified Stripe event. Idempotent: each event ID is recorded
 * in the same transaction that applies it, so Stripe's retries are no-ops.
 * Events can arrive out of order, so an event older than the last one
 * applied to the same subscription is skipped.
 */
export async function handleStripeEvent(event: StripeEventLike, now = Date.now()): Promise<WebhookOutcome> {
  if (!HANDLED.has(event.type)) return "ignored";
  const obj = event.data.object;
  const customerId = customerIdOf(obj.customer);
  if (!customerId) return "ignored";

  type Result = { outcome: WebhookOutcome; incident?: [string, Record<string, unknown>] };
  const result = await db().runTransaction<Result>(async (tx) => {
    const marker = db().doc(platformPaths.stripeEvent(event.id));
    const [seen, mapping] = await Promise.all([
      tx.get(marker),
      tx.get(db().doc(platformPaths.stripeCustomer(customerId))),
    ]);
    if (seen.exists) return { outcome: "duplicate" };
    const orgId = mapping.get("orgId") as string | undefined;
    if (!orgId) {
      return {
        outcome: "unmatched",
        incident: ["Stripe event for a customer no org is linked to", { eventId: event.id, customerId, type: event.type }],
      };
    }
    const { org, sub } = await readOrgAndBilling(tx, orgId);
    const actor: Actor = { uid: `stripe:${event.id}`, kind: "billing" };
    const markApplied = () =>
      tx.create(marker, { orgId, type: event.type, created: event.created, processedAt: FieldValue.serverTimestamp() });

    if (event.type === "checkout.session.completed") {
      const ref = obj.client_reference_id;
      if (typeof ref === "string" && ref !== orgId) {
        return {
          outcome: "unmatched",
          incident: ["Checkout org doesn't match the customer's org", { eventId: event.id, orgId, ref }],
        };
      }
      markApplied();
      const subscriptionId = customerIdOf(obj.subscription);
      if (subscriptionId && !sub.stripeSubscriptionId) {
        tx.set(db().doc(subscriptionPath(orgId)), { stripeSubscriptionId: subscriptionId }, { merge: true });
      }
      return { outcome: "applied" };
    }

    if (event.type.startsWith("invoice.")) {
      markApplied();
      tx.set(
        db().doc(subscriptionPath(orgId)),
        {
          lastInvoice: {
            id: obj.id ?? null,
            paid: event.type === "invoice.paid",
            amountDueCents: typeof obj.amount_due === "number" ? obj.amount_due : null,
            at: Timestamp.fromMillis(event.created * 1000),
          },
        },
        { merge: true },
      );
      if (event.type === "invoice.payment_failed") {
        audit(tx, orgId, {
          action: "billing.payment_failed",
          actorUid: actor.uid,
          actorKind: actor.kind,
          target: { invoiceId: obj.id ?? null },
        });
      }
      return { outcome: "applied" };
    }

    // customer.subscription.*
    const s = obj as unknown as StripeSubscriptionLike;
    if (s.metadata?.orgId && s.metadata.orgId !== orgId) {
      return {
        outcome: "unmatched",
        incident: ["Subscription metadata names a different org", { eventId: event.id, orgId, metadataOrg: s.metadata.orgId }],
      };
    }
    const sameSubscription = !sub.stripeSubscriptionId || sub.stripeSubscriptionId === s.id;
    const status: BillingStatus = event.type === "customer.subscription.deleted" ? "canceled" : s.status;
    // An old subscription's late events must not override a newer one.
    if (!sameSubscription && !GOOD.has(status)) {
      markApplied();
      return { outcome: "stale" };
    }
    if (sameSubscription && typeof sub.lastStripeEventCreated === "number" && event.created < sub.lastStripeEventCreated) {
      markApplied();
      return { outcome: "stale" };
    }

    const item = s.items?.data?.[0];
    const plan = planForLookupKey(item?.price?.lookup_key);
    const periodEnd = s.current_period_end ?? item?.current_period_end ?? null;
    markApplied();
    applyBilling(
      tx,
      orgId,
      sameSubscription ? sub : { ...sub, lapsedAt: null },
      org,
      {
        source: "stripe",
        status,
        ...(plan ? { plan } : {}),
        trialEndsAt: null,
        stripeSubscriptionId: s.id,
        cancelAtPeriodEnd: s.cancel_at_period_end ?? false,
        currentPeriodEnd: periodEnd ? Timestamp.fromMillis(periodEnd * 1000) : null,
        lastStripeEventCreated: event.created,
      },
      now,
      actor,
    );
    return {
      outcome: "applied",
      ...(plan ? {} : { incident: ["Subscription price has no known lookup key", { eventId: event.id, orgId, price: item?.price?.id ?? null }] }),
    };
  });

  if (result.incident) {
    await recordIncident(
      result.outcome === "unmatched" ? "stripe_webhook_unmatched" : "stripe_webhook_failed",
      result.incident[0],
      result.incident[1],
    );
  }
  logger.info("Stripe event", { eventId: event.id, type: event.type, outcome: result.outcome });
  return result.outcome;
}

// ---------------------------------------------------------------------------
// Platform admin: custom plans and trials
// ---------------------------------------------------------------------------

async function requirePlatformAdmin(caller: Caller): Promise<string> {
  const uid = requireUid(caller);
  if (!(await isPlatformAdmin(uid))) throw fail.denied();
  return uid;
}

/**
 * Sets a plan by hand (franchise deals, pilots, comped accounts). `active:
 * false` ends it, which starts the normal grace period.
 */
export async function setManualPlan(caller: Caller, data: unknown, now = Date.now()): Promise<{ ok: true }> {
  const uid = await requirePlatformAdmin(caller);
  const input = asInput(data);
  const orgId = docId(input, "orgId");
  const plan = oneOf(input, "plan", PLANS.filter((p) => p !== "trial"));
  if (typeof input.active !== "boolean") throw fail.invalid("active must be true or false.");
  const reason = str(input, "reason", { min: 3, max: 300 });

  await db().runTransaction(async (tx) => {
    const { org, sub } = await readOrgAndBilling(tx, orgId);
    if (sub.source === "stripe" && GOOD.has(sub.status as BillingStatus)) {
      throw fail.precondition("This org pays through Stripe. Cancel that subscription first.");
    }
    applyBilling(tx, orgId, sub, org, {
      source: "manual",
      status: input.active ? "active" : "canceled",
      plan,
      trialEndsAt: null,
    }, now, { uid, kind: "platform_admin", reason });
    auditPlatform(tx, orgId, { action: "billing.manual_plan_set", actorUid: uid, reason, target: { plan, active: input.active } });
  });
  return { ok: true };
}

export async function extendTrial(caller: Caller, data: unknown, now = Date.now()): Promise<{ trialEndsAt: number }> {
  const uid = await requirePlatformAdmin(caller);
  const input = asInput(data);
  const orgId = docId(input, "orgId");
  const days = input.days;
  if (typeof days !== "number" || !Number.isInteger(days) || days < 1 || days > 90) {
    throw fail.invalid("days must be a whole number from 1 to 90.");
  }
  const reason = str(input, "reason", { min: 3, max: 300 });

  return db().runTransaction(async (tx) => {
    const { org, sub } = await readOrgAndBilling(tx, orgId);
    if (sub.source !== undefined && sub.source !== "trial") {
      throw fail.precondition("Only orgs on the free trial can have it extended.");
    }
    const from = Math.max(now, ms(sub.trialEndsAt) ?? now);
    const trialEndsAt = trialEnd(from, days);
    // Extending forgives the lapse, so a fresh grace period applies next time.
    applyBilling(tx, orgId, { ...sub, lapsedAt: null }, org, {
      source: "trial",
      status: "trialing",
      plan: "trial",
      trialEndsAt,
    }, now, { uid, kind: "platform_admin", reason });
    auditPlatform(tx, orgId, { action: "billing.trial_extended", actorUid: uid, reason, target: { days } });
    return { trialEndsAt };
  });
}

// ---------------------------------------------------------------------------
// Scheduled: end trials and grace periods on time
// ---------------------------------------------------------------------------

/**
 * Re-derives access for every subscription whose accessReviewAt has passed
 * (a trial ending, a grace period running out). Runs hourly.
 */
export async function enforceBillingAccess(now = Date.now()): Promise<number> {
  const due = await db()
    .collectionGroup("billing")
    .where("accessReviewAt", "<=", Timestamp.fromMillis(now))
    .limit(500)
    .get();
  let changed = 0;
  for (const doc of due.docs) {
    const orgId = doc.get("orgId") as string | undefined;
    if (!orgId || doc.id !== "subscription") continue;
    await db().runTransaction(async (tx) => {
      const { org, sub } = await readOrgAndBilling(tx, orgId);
      const { accessChanged } = applyBilling(tx, orgId, sub, org, {}, now, { uid: "system:billing", kind: "system" });
      if (accessChanged) changed++;
    });
  }
  if (changed > 0) logger.info("Billing access changed", { changed });
  return changed;
}
