/**
 * Cloud Functions entry point.
 *
 * Everything that changes who can do what is a Function, never a direct
 * client write (see firestore.rules). Each handler re-checks the caller's
 * membership from Firestore, never trusting an orgId or role in the request
 * beyond using it to look the membership up, and writes orgs/{orgId}/auditLog.
 *
 * Handlers live in handlers/ as plain async functions so the emulator tests
 * can call them directly; this file only wires them to callable endpoints.
 */
import { logger } from "firebase-functions";
import { defineSecret, defineString } from "firebase-functions/params";
import { setGlobalOptions } from "firebase-functions/v2";
import { type CallableRequest, onCall, onRequest } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
import Stripe from "stripe";
import { StripeBillingGateway } from "./billing/gateway.js";
import { AGGREGATOR_IDS, type AggregatorId, AggregatorNotConfigured, defaultAggregators } from "./delivery/aggregator.js";
import * as billing from "./handlers/billing.js";
import * as delivery from "./handlers/delivery.js";
import * as devices from "./handlers/devices.js";
import * as monitoring from "./handlers/monitoring.js";
import * as online from "./handlers/online.js";
import * as orgs from "./handlers/orgs.js";
import * as payments from "./handlers/payments.js";
import * as pins from "./handlers/pins.js";
import * as staff from "./handlers/staff.js";
import * as support from "./handlers/support.js";
import type { Caller } from "./lib/tenant.js";
import { recordIncident } from "./lib/platform.js";
import { StripeOnlineCheckoutGateway } from "./orders/checkout.js";
import { defaultRegistry } from "./payments/providers.js";

// Montreal, so tenant data and compute stay in Canada.
setGlobalOptions({ region: "northamerica-northeast1", maxInstances: 20 });

const PIN_PEPPER = defineSecret("PIN_PEPPER");
// Stripe Billing. Test-mode keys in dev and staging; set with
// `firebase functions:secrets:set` per project. Never committed.
const STRIPE_SECRET_KEY = defineSecret("STRIPE_SECRET_KEY");
const STRIPE_WEBHOOK_SECRET = defineSecret("STRIPE_WEBHOOK_SECRET");
// Where Stripe sends owners back to after Checkout or the portal.
const MANAGER_APP_URL = defineString("MANAGER_APP_URL", { default: "http://localhost:8080" });
// Online ordering: the ordering site's address (for Stripe's return links)
// and the Connect webhook secret for events from restaurants' Stripe accounts.
const ORDERING_SITE_URL = defineString("ORDERING_SITE_URL", { default: "http://localhost:8083" });
const STRIPE_CONNECT_WEBHOOK_SECRET = defineSecret("STRIPE_CONNECT_WEBHOOK_SECRET");

const providers = defaultRegistry();
const aggregators = defaultAggregators();
const gateway = () => new StripeBillingGateway(new Stripe(STRIPE_SECRET_KEY.value()));

function caller(req: CallableRequest): Caller {
  return { uid: req.auth?.uid ?? null, email: (req.auth?.token.email as string | undefined) ?? null };
}

type Handler<T> = (caller: Caller, data: unknown) => Promise<T>;
const callable = <T>(handler: Handler<T>) => onCall((req) => handler(caller(req), req.data));

// Onboarding
export const createOrganization = callable(orgs.createOrganization);
export const createLocation = callable(orgs.createLocation);
export const setLocationStatus = callable(orgs.setLocationStatus);

// Staff
export const inviteStaff = callable(staff.inviteStaff);
export const revokeInvite = callable(staff.revokeInvite);
export const acceptInvite = callable(staff.acceptInvite);
export const setMemberRole = callable(staff.setMemberRole);
export const setOwner = callable(staff.setOwner);

// Devices
export const createPairingCode = callable(devices.createPairingCode);
export const redeemPairingCode = callable(devices.redeemPairingCode);
export const revokeDevice = callable(devices.revokeDevice);

// Staff PINs on a paired device
export const setStaffPin = onCall({ secrets: [PIN_PEPPER] }, (req) =>
  pins.setStaffPin(caller(req), req.data, PIN_PEPPER.value()),
);
export const startStaffSession = onCall({ secrets: [PIN_PEPPER] }, (req) =>
  pins.startStaffSession(caller(req), req.data, PIN_PEPPER.value()),
);

// Support access and tenant status (platform admin)
export const grantSupportAccess = callable(support.grantSupportAccess);
export const revokeSupportAccess = callable(support.revokeSupportAccess);
export const setOrgStatus = callable(support.setOrgStatus);

// Billing
export const startCheckout = onCall({ secrets: [STRIPE_SECRET_KEY] }, (req) =>
  billing.startCheckout(caller(req), req.data, gateway(), { managerAppUrl: MANAGER_APP_URL.value() }),
);
export const openBillingPortal = onCall({ secrets: [STRIPE_SECRET_KEY] }, (req) =>
  billing.openBillingPortal(caller(req), req.data, gateway(), { managerAppUrl: MANAGER_APP_URL.value() }),
);
export const setManualPlan = callable(billing.setManualPlan);
export const extendTrial = callable(billing.extendTrial);

/**
 * Stripe calls this. The signature is checked against the raw body before
 * anything is read; an unsigned or tampered request gets a 400 and changes
 * nothing. A processing error returns 500 so Stripe retries (events are
 * idempotent, see handleStripeEvent).
 */
export const stripeWebhook = onRequest({ secrets: [STRIPE_WEBHOOK_SECRET] }, async (req, res) => {
  if (req.method !== "POST") {
    res.status(405).send("POST only");
    return;
  }
  let event: billing.StripeEventLike;
  try {
    event = billing.verifyStripeEvent(req.rawBody, req.get("stripe-signature") ?? "", STRIPE_WEBHOOK_SECRET.value());
  } catch {
    logger.warn("Rejected a Stripe webhook with a bad signature");
    res.status(400).send("Bad signature");
    return;
  }
  try {
    const outcome = await billing.handleStripeEvent(event);
    res.status(200).json({ received: true, outcome });
  } catch (err) {
    await recordIncident("stripe_webhook_failed", "Stripe webhook processing failed", {
      eventId: event.id,
      type: event.type,
      err: String(err),
    });
    res.status(500).send("Processing failed");
  }
});

export const enforceBillingAccess = onSchedule("every 60 minutes", async () => {
  await billing.enforceBillingAccess();
});

// Card payments, refunds and voids
export const startCardPayment = callable((c, d) => payments.startCardPayment(c, d, providers));
export const refreshPayment = callable((c, d) => payments.refreshPayment(c, d, providers));
export const cancelCardPayment = callable((c, d) => payments.cancelCardPayment(c, d, providers));
export const refundPayment = onCall({ secrets: [PIN_PEPPER] }, (req) =>
  payments.refundPayment(caller(req), req.data, providers, PIN_PEPPER.value()),
);
export const voidOrder = onCall({ secrets: [PIN_PEPPER] }, (req) =>
  payments.voidOrder(caller(req), req.data, PIN_PEPPER.value()),
);
export const recoverPendingPayments = onSchedule("every 10 minutes", async () => {
  await payments.recoverPendingPayments(providers);
});

// Monitoring
export const healthSweep = onSchedule("every 15 minutes", async () => {
  await monitoring.runHealthSweep();
});
export const resolveIncident = callable(monitoring.resolveIncident);

// Online ordering site. getStorefront, placeOnlineOrder and
// getOnlineOrderStatus are public: guests don't sign in. Turn on App Check
// and per-IP limits before launch (docs/orders.md).
export const updateOnlineOrdering = callable(online.updateOnlineOrdering);
export const getStorefront = onCall((req) => online.getStorefront(req.data));
export const placeOnlineOrder = onCall({ secrets: [STRIPE_SECRET_KEY] }, (req) =>
  online.placeOnlineOrder(
    req.data,
    new StripeOnlineCheckoutGateway(new Stripe(STRIPE_SECRET_KEY.value())),
    { siteUrl: ORDERING_SITE_URL.value() },
  ),
);
export const getOnlineOrderStatus = onCall((req) => online.getOnlineOrderStatus(req.data));

/** Checkout events from restaurants' connected Stripe accounts. Same signature rules as stripeWebhook. */
export const onlineCheckoutWebhook = onRequest({ secrets: [STRIPE_CONNECT_WEBHOOK_SECRET] }, async (req, res) => {
  if (req.method !== "POST") {
    res.status(405).send("POST only");
    return;
  }
  let event: online.CheckoutEventLike;
  try {
    event = billing.verifyStripeEvent(
      req.rawBody, req.get("stripe-signature") ?? "", STRIPE_CONNECT_WEBHOOK_SECRET.value(),
    ) as unknown as online.CheckoutEventLike;
  } catch {
    logger.warn("Rejected an online checkout webhook with a bad signature");
    res.status(400).send("Bad signature");
    return;
  }
  try {
    res.status(200).json({ received: true, outcome: await online.handleOnlineCheckoutEvent(event) });
  } catch (err) {
    await recordIncident("stripe_webhook_failed", "Online checkout webhook failed", { eventId: event.id, err: String(err) });
    res.status(500).send("Processing failed");
  }
});

// Delivery marketplaces through an aggregator
export const linkDeliveryStore = callable(delivery.linkDeliveryStore);
export const syncDeliveryMenu = callable((c, d) => delivery.syncDeliveryMenu(c, d, aggregators));

/**
 * POST /deliveryWebhook/{aggregator}. Verified before anything is read; an
 * aggregator that isn't set up gets a 503 so it retries later.
 */
export const deliveryWebhook = onRequest(async (req, res) => {
  const id = req.path.replace(/^\/+/, "").split("/")[0] as AggregatorId;
  if (req.method !== "POST" || !AGGREGATOR_IDS.includes(id)) {
    res.status(404).send("Not found");
    return;
  }
  let aggregator;
  try {
    aggregator = aggregators(id);
    aggregator.verifyWebhook(req.rawBody, req.headers as Record<string, string | undefined>);
  } catch (err) {
    const notSetUp = err instanceof AggregatorNotConfigured;
    logger.warn("Rejected a delivery webhook", { aggregator: id, err: String(err) });
    res.status(notSetUp ? 503 : 400).send(notSetUp ? "Not set up" : "Bad signature");
    return;
  }
  try {
    const order = aggregator.parseOrder(req.body);
    if (!order) {
      res.status(200).json({ received: true, outcome: "ignored" });
      return;
    }
    res.status(200).json({ received: true, ...(await delivery.ingestDeliveryOrder(id, order)) });
  } catch (err) {
    await recordIncident("delivery_webhook_failed", "Delivery webhook failed", { aggregator: id, err: String(err) });
    res.status(500).send("Processing failed");
  }
});
