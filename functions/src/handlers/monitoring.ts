/**
 * Platform monitoring, for the admin portal's Health page.
 *
 * A sweep every 15 minutes counts what needs attention across tenants and
 * writes platformHealth/summary: devices that stopped checking in, printers
 * reporting a problem, card payments stuck pending, and open incidents
 * (platformIncidents, written by lib/platform.ts recordIncident). It reads
 * only counts and IDs, never order or menu contents.
 *
 * Paging lives in Cloud Monitoring, not here: alert on error-level logs with
 * an `incident` field and on Function error rates (docs/monitoring.md).
 */
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { auditPlatform } from "../lib/audit.js";
import { fail } from "../lib/errors.js";
import { db } from "../lib/firebase.js";
import { platformPaths } from "../lib/platform.js";
import { type Caller, isPlatformAdmin, requireUid } from "../lib/tenant.js";
import { asInput, docId, str } from "../lib/validate.js";
import { STUCK_AFTER_MS } from "./payments.js";

/** A device that hasn't reported for this long is offline. Devices report every few minutes. */
export const DEVICE_STALE_MS = 15 * 60 * 1000;
export const PRINTER_PROBLEMS = ["offline", "paper_out", "error"] as const;

export interface HealthSummary {
  staleDevices: number;
  staleDevicesByOrg: Record<string, number>;
  printerProblems: number;
  stuckPayments: number;
  openIncidents: number;
}

export async function runHealthSweep(now = Date.now()): Promise<HealthSummary> {
  const devices = db().collectionGroup("devices");
  const [stale, printers, stuck, incidents] = await Promise.all([
    devices
      .where("status", "==", "active")
      .where("lastSeenAt", "<", Timestamp.fromMillis(now - DEVICE_STALE_MS))
      .select("orgId")
      .limit(1000)
      .get(),
    devices.where("status", "==", "active").where("printerStatus", "in", [...PRINTER_PROBLEMS]).count().get(),
    db()
      .collectionGroup("payments")
      .where("status", "==", "pending")
      .where("updatedAt", "<=", Timestamp.fromMillis(now - STUCK_AFTER_MS))
      .count()
      .get(),
    db().collection(platformPaths.incidents).where("resolved", "==", false).count().get(),
  ]);

  const byOrg: Record<string, number> = {};
  for (const d of stale.docs) {
    const orgId = d.get("orgId") as string | undefined;
    if (orgId) byOrg[orgId] = (byOrg[orgId] ?? 0) + 1;
  }
  const summary: HealthSummary = {
    staleDevices: stale.size,
    staleDevicesByOrg: byOrg,
    printerProblems: printers.data().count,
    stuckPayments: stuck.data().count,
    openIncidents: incidents.data().count,
  };
  await db().doc(platformPaths.health).set({ ...summary, checkedAt: FieldValue.serverTimestamp() });
  return summary;
}

/** A platform admin marks an incident handled, with a note. */
export async function resolveIncident(caller: Caller, data: unknown): Promise<{ ok: true }> {
  const uid = requireUid(caller);
  if (!(await isPlatformAdmin(uid))) throw fail.denied();
  const input = asInput(data);
  const incidentId = docId(input, "incidentId");
  const note = str(input, "note", { min: 3, max: 300 });
  await db().runTransaction(async (tx) => {
    const ref = db().doc(`${platformPaths.incidents}/${incidentId}`);
    const snap = await tx.get(ref);
    if (!snap.exists) throw fail.notFound("Incident not found.");
    tx.update(ref, { resolved: true, resolvedBy: uid, resolutionNote: note, resolvedAt: FieldValue.serverTimestamp() });
    auditPlatform(tx, (snap.get("orgId") as string | null) ?? null, {
      action: "incident.resolved",
      actorUid: uid,
      reason: note,
      target: { incidentId, kind: snap.get("kind") },
    });
  });
  return { ok: true };
}
