import { FieldValue, type Transaction } from "firebase-admin/firestore";
import { db } from "./firebase.js";

export interface AuditEvent {
  action: string;
  actorUid: string;
  locationId?: string | null;
  target?: Record<string, unknown>;
}

/**
 * Appends to orgs/{orgId}/auditLog, which clients can read (owners, and
 * franchise owners for their stores) but never write.
 */
export function audit(tx: Transaction, orgId: string, event: AuditEvent): void {
  const ref = db().collection(`orgs/${orgId}/auditLog`).doc();
  tx.set(ref, {
    orgId,
    locationId: event.locationId ?? null,
    action: event.action,
    actorUid: event.actorUid,
    target: event.target ?? {},
    createdAt: FieldValue.serverTimestamp(),
  });
}
