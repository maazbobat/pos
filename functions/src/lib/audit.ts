import { FieldValue, type Transaction } from "firebase-admin/firestore";
import { db } from "./firebase.js";

/**
 * Who did it. `platform_admin` is the SaaS operator acting on a tenant,
 * `billing` is a verified Stripe webhook, `system` is a scheduled job.
 */
export type ActorKind = "user" | "device" | "platform_admin" | "billing" | "system";

export interface AuditEvent {
  action: string;
  actorUid: string;
  actorKind?: ActorKind;
  locationId?: string | null;
  /** The staff member signed in on a device when a device acts for them. */
  staffUid?: string | null;
  /** Why, when a person gave a reason (support access, refunds, voids). */
  reason?: string | null;
  target?: Record<string, unknown>;
}

function entry(orgId: string | null, event: AuditEvent) {
  return {
    orgId,
    locationId: event.locationId ?? null,
    action: event.action,
    actorUid: event.actorUid,
    actorKind: event.actorKind ?? "user",
    staffUid: event.staffUid ?? null,
    reason: event.reason ?? null,
    target: event.target ?? {},
    createdAt: FieldValue.serverTimestamp(),
  };
}

/**
 * Appends to orgs/{orgId}/auditLog, which clients can read (owners, and
 * franchise owners for their stores) but never write.
 */
export function audit(tx: Transaction, orgId: string, event: AuditEvent): void {
  tx.set(db().collection(`orgs/${orgId}/auditLog`).doc(), entry(orgId, event));
}

/**
 * Anything a platform admin does is written twice: to the tenant's own log,
 * so the owner sees what the platform did to their org, and to
 * platformAuditLog, which only platform admins read.
 */
export function auditPlatform(tx: Transaction, orgId: string | null, event: AuditEvent): void {
  const e = { ...event, actorKind: event.actorKind ?? ("platform_admin" as const) };
  if (orgId) audit(tx, orgId, e);
  tx.set(db().collection("platformAuditLog").doc(), entry(orgId, e));
}
