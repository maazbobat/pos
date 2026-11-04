/**
 * Cloud Functions entry point.
 *
 * Everything that changes who can do what is a Function, never a direct
 * client write (see firestore.rules): staff invites and role changes, device
 * pairing and revocation, voids and refunds (server-checked manager PIN),
 * card payments, cash-session adjustments, location create/close, platform
 * support grants, and billing state from verified Stripe webhooks. Each one
 * re-checks the caller's membership and writes orgs/{orgId}/auditLog.
 *
 * None are implemented yet; they arrive with roadmap step 2 (onboarding).
 */
import { initializeApp } from "firebase-admin/app";

initializeApp();
