/**
 * Platform-level collections, read only by platform admins and written only
 * by Functions:
 *
 *   platformOrgs/{orgId}       summary of each tenant for the admin portal
 *   platformAuditLog/{id}      every platform admin action (see audit.ts)
 *   platformHealth/summary     latest monitoring sweep
 *   platformIncidents/{id}     problems a person should look at
 *
 * The summary lets the operator list and support tenants without standing
 * read access to any tenant's data (that still takes a support grant).
 */
import { FieldValue, type Timestamp, type Transaction } from "firebase-admin/firestore";
import { logger } from "firebase-functions";
import { db } from "./firebase.js";

export const platformPaths = {
  org: (orgId: string) => `platformOrgs/${orgId}`,
  health: "platformHealth/summary",
  incidents: "platformIncidents",
  stripeCustomer: (customerId: string) => `stripeCustomers/${customerId}`,
  stripeEvent: (eventId: string) => `stripeEvents/${eventId}`,
};

/** Fields the admin portal shows. Never menus, orders, staff or money. */
export interface PlatformOrgSummary {
  name?: string;
  type?: string;
  status?: string;
  accessLevel?: string;
  plan?: string;
  billingStatus?: string;
  billingSource?: string;
  graceEndsAt?: Timestamp | null;
  trialEndsAt?: Timestamp | null;
  ownerEmail?: string | null;
  locationCount?: FieldValue | number;
  createdAt?: FieldValue;
}

export function syncPlatformOrg(tx: Transaction, orgId: string, fields: PlatformOrgSummary): void {
  tx.set(
    db().doc(platformPaths.org(orgId)),
    { orgId, ...fields, updatedAt: FieldValue.serverTimestamp() },
    { merge: true },
  );
}

export type IncidentKind =
  | "stripe_webhook_unmatched"
  | "stripe_webhook_failed"
  | "payment_stuck"
  | "payment_mismatch";

/**
 * Records something a person should look at, and logs it at error level so a
 * Cloud Monitoring log-based alert can page on it (docs/monitoring.md).
 * Best effort: monitoring must never break the operation it watches.
 */
export async function recordIncident(
  kind: IncidentKind,
  message: string,
  details: Record<string, unknown> = {},
): Promise<void> {
  logger.error(message, { incident: kind, ...details });
  try {
    await db().collection(platformPaths.incidents).add({
      kind,
      message,
      details,
      orgId: typeof details.orgId === "string" ? details.orgId : null,
      resolved: false,
      createdAt: FieldValue.serverTimestamp(),
    });
  } catch (err) {
    logger.error("Could not record incident", { kind, err: String(err) });
  }
}
