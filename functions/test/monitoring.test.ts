import { Timestamp } from "firebase-admin/firestore";
import { beforeEach, describe, expect, it } from "vitest";
import { DEVICE_STALE_MS, resolveIncident, runHealthSweep } from "../src/handlers/monitoring.js";
import { recordIncident } from "../src/lib/platform.js";
import { caller, db, expectHttpsError, PLATFORM_ADMIN, resetEmulators, seed, u } from "./setup.js";

beforeEach(async () => {
  await resetEmulators();
  await seed();
});

async function device(orgId: string, locId: string, id: string, fields: Record<string, unknown>) {
  await db().doc(`orgs/${orgId}/locations/${locId}/devices/${id}`).set({ orgId, locationId: locId, deviceId: id, status: "active", ...fields });
}

describe("runHealthSweep", () => {
  it("counts offline devices per org, printer problems, stuck payments and open incidents", async () => {
    const now = Date.now();
    const stale = Timestamp.fromMillis(now - DEVICE_STALE_MS - 60_000);
    const fresh = Timestamp.fromMillis(now - 60_000);
    await device("org-a", "cambridge", "d1", { lastSeenAt: stale });
    await device("org-a", "toronto", "d2", { lastSeenAt: stale, printerStatus: "paper_out" });
    await device("org-b", "halifax", "d3", { lastSeenAt: fresh, printerStatus: "ok" });
    await device("org-b", "halifax", "d4", { lastSeenAt: stale, status: "revoked" });
    const old = Timestamp.fromMillis(now - 60 * 60 * 1000);
    await db().doc("orgs/org-a/locations/cambridge/orders/o1/payments/p1").set({ status: "pending", updatedAt: old });
    await recordIncident("payment_stuck", "test", { orgId: "org-a" });

    const summary = await runHealthSweep(now);
    expect(summary).toEqual({
      staleDevices: 2,
      staleDevicesByOrg: { "org-a": 2 },
      printerProblems: 1,
      stuckPayments: 1,
      openIncidents: 1,
    });
    expect((await db().doc("platformHealth/summary").get()).get("staleDevices")).toBe(2);
  });
});

describe("resolveIncident", () => {
  it("is platform admin only and audited", async () => {
    await recordIncident("stripe_webhook_failed", "test", { orgId: "org-a" });
    const [incident] = (await db().collection("platformIncidents").get()).docs;
    await expectHttpsError(resolveIncident(caller(u.ownerA), { incidentId: incident.id, note: "fixed" }), "permission-denied");
    await resolveIncident(caller(PLATFORM_ADMIN), { incidentId: incident.id, note: "Replayed the event" });
    expect((await incident.ref.get()).data()).toMatchObject({ resolved: true, resolvedBy: PLATFORM_ADMIN });
    const log = await db().collection("platformAuditLog").get();
    expect(log.docs.map((d) => d.get("action"))).toEqual(["incident.resolved"]);
  });
});
