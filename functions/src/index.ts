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
import * as billing from "./handlers/billing.js";
import * as devices from "./handlers/devices.js";
import * as monitoring from "./handlers/monitoring.js";
import * as orgs from "./handlers/orgs.js";
import * as payments from "./handlers/payments.js";
import * as pins from "./handlers/pins.js";
import * as staff from "./handlers/staff.js";
import * as support from "./handlers/support.js";
import type { Caller } from "./lib/tenant.js";
import { recordIncident } from "./lib/platform.js";
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

const providers = defaultRegistry();
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
