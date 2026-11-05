/**
 * Delivery marketplace orders through an aggregator (delivery/aggregator.ts).
 *
 *   linkDeliveryStore    owner: map an aggregator's store ID to a location
 *   ingestDeliveryOrder  from the verified webhook: store each order exactly once
 *   syncDeliveryMenu     managers: push this location's menu and sold-out flags
 *
 * Offline handling: orders land in Firestore on the server, whether or not
 * the store's tablets are online. The kitchen display and POS pick them up
 * from Firestore when they reconnect, and nothing on the tablet has to
 * accept an order for it to be kept.
 */
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { audit } from "../lib/audit.js";
import { fail } from "../lib/errors.js";
import { db } from "../lib/firebase.js";
import { sha256 } from "../lib/ids.js";
import { recordIncident } from "../lib/platform.js";
import { isManager } from "../lib/roles.js";
import { type Caller, paths, requireActiveMember, requireUid, requireWritableOrg, roleAt } from "../lib/tenant.js";
import { asInput, docId, oneOf, str } from "../lib/validate.js";
import { AGGREGATOR_IDS, type AggregatorId, type DeliveryAggregator, type ExternalOrder } from "../delivery/aggregator.js";
import { loadStoreMenu } from "../orders/menu.js";

const storeKey = (aggregator: AggregatorId, externalStoreId: string) =>
  `${aggregator}_${sha256(externalStoreId).slice(0, 24)}`;

export const deliveryOrderId = (aggregator: AggregatorId, externalId: string) =>
  `dlv_${sha256(`${aggregator}:${externalId}`).slice(0, 28)}`;

export const deliveryPaths = {
  store: (aggregator: AggregatorId, externalStoreId: string) => `deliveryStores/${storeKey(aggregator, externalStoreId)}`,
  locationLink: (o: string, l: string, aggregator: AggregatorId) =>
    `${paths.location(o, l)}/settings/delivery_${aggregator}`,
};

/** Owner only: which aggregator store is which location. One store per location per aggregator. */
export async function linkDeliveryStore(caller: Caller, data: unknown): Promise<{ ok: true }> {
  const uid = requireUid(caller);
  const input = asInput(data);
  const orgId = docId(input, "orgId");
  const locationId = docId(input, "locationId");
  const aggregator = oneOf(input, "aggregator", AGGREGATOR_IDS);
  const externalStoreId = str(input, "externalStoreId", { min: 1, max: 128 });

  await db().runTransaction(async (tx) => {
    const member = await requireActiveMember(tx, orgId, uid);
    if (roleAt(member, locationId) !== "owner") throw fail.denied("Only the owner links delivery stores.");
    await requireWritableOrg(tx, orgId);
    const loc = await tx.get(db().doc(paths.location(orgId, locationId)));
    if (!loc.exists) throw fail.notFound("Location not found.");
    const storeRef = db().doc(deliveryPaths.store(aggregator, externalStoreId));
    const linkRef = db().doc(deliveryPaths.locationLink(orgId, locationId, aggregator));
    const [existing, link] = await Promise.all([tx.get(storeRef), tx.get(linkRef)]);
    if (existing.exists && (existing.get("orgId") !== orgId || existing.get("locationId") !== locationId)) {
      throw fail.conflict("That delivery store is linked to another location.");
    }
    const previous = link.get("externalStoreId") as string | undefined;
    if (previous && previous !== externalStoreId) tx.delete(db().doc(deliveryPaths.store(aggregator, previous)));
    tx.set(storeRef, { orgId, locationId, aggregator, externalStoreId, createdAt: FieldValue.serverTimestamp() });
    tx.set(linkRef, {
      orgId, locationId, aggregator, externalStoreId, updatedAt: FieldValue.serverTimestamp(), updatedBy: uid,
    });
    audit(tx, orgId, {
      action: "delivery.store_linked", actorUid: uid, locationId, target: { aggregator, externalStoreId },
    });
  });
  return { ok: true };
}

export type IngestOutcome = "created" | "duplicate" | "unmatched" | "refused";

function validExternal(o: ExternalOrder): boolean {
  const cents = (v: unknown) => typeof v === "number" && Number.isInteger(v) && v >= 0 && v <= 10_000_000;
  return typeof o.externalId === "string" && o.externalId.length > 0 && o.externalId.length <= 200
    && typeof o.externalStoreId === "string" && o.externalStoreId.length > 0
    && Array.isArray(o.lines) && o.lines.length > 0 && o.lines.length <= 100
    && o.lines.every((l) => typeof l.name === "string" && Number.isInteger(l.qty) && l.qty > 0 && cents(l.unitPriceCents))
    && cents(o.subtotalCents) && cents(o.taxCents) && cents(o.totalCents);
}

/**
 * Stores one marketplace order. The order ID comes from the aggregator and
 * its order ID, and the document is created in a transaction, so a webhook
 * delivered twice (or two at once) stores the order once. An order for a
 * store nobody linked, or for a closed or read-only tenant, raises an
 * incident so someone can sort it out with the marketplace.
 */
export async function ingestDeliveryOrder(aggregator: AggregatorId, order: ExternalOrder): Promise<{ outcome: IngestOutcome; orderId?: string }> {
  if (!validExternal(order)) {
    await recordIncident("delivery_order_unmatched", "Delivery order with a bad shape", { aggregator });
    return { outcome: "refused" };
  }
  const link = await db().doc(deliveryPaths.store(aggregator, order.externalStoreId)).get();
  if (!link.exists) {
    await recordIncident("delivery_order_unmatched", "Delivery order for a store nobody linked", {
      aggregator, externalStoreId: order.externalStoreId, externalId: order.externalId,
    });
    return { outcome: "unmatched" };
  }
  const orgId = link.get("orgId") as string;
  const locationId = link.get("locationId") as string;
  const orderId = deliveryOrderId(aggregator, order.externalId);
  const ref = db().doc(`${paths.location(orgId, locationId)}/orders/${orderId}`);

  const outcome = await db().runTransaction(async (tx): Promise<IngestOutcome> => {
    const [existing, org, loc] = await Promise.all([
      tx.get(ref),
      tx.get(db().doc(paths.org(orgId))),
      tx.get(db().doc(paths.location(orgId, locationId))),
    ]);
    if (existing.exists) return "duplicate";
    if (org.get("status") !== "active" || org.get("accessLevel") !== "full" || loc.get("status") !== "active") {
      return "refused";
    }
    const items = order.lines.map((l, i) => ({
      lineId: `l${i + 1}`,
      itemId: l.itemId ?? "",
      name: l.name.slice(0, 100),
      qty: l.qty,
      unitPriceCents: l.unitPriceCents - l.modifiers.reduce((s, m) => s + m.priceDeltaCents, 0),
      modifiers: l.modifiers.map((m, j) => ({ groupId: "", optionId: `m${j + 1}`, name: m.name.slice(0, 60), priceDeltaCents: m.priceDeltaCents })),
      lineTotalCents: l.unitPriceCents * l.qty,
      taxable: true,
      kitchenStation: null,
      notes: l.notes?.slice(0, 140) ?? null,
    }));
    tx.create(ref, {
      orgId,
      locationId,
      source: "delivery",
      channel: order.channel,
      aggregator,
      external: { aggregator, externalId: order.externalId, displayId: order.displayId },
      ticket: order.displayId.slice(0, 12) || orderId.slice(-4),
      status: "new",
      paymentStatus: "paid",
      fulfillment: order.fulfillment,
      pickupAt: order.pickupAt ? Timestamp.fromMillis(order.pickupAt) : null,
      items,
      totals: {
        subtotalCents: order.subtotalCents,
        discountCents: Math.max(0, order.subtotalCents + order.taxCents - order.totalCents),
        taxCents: order.taxCents,
        totalCents: order.totalCents,
        taxes: [],
      },
      discounts: [],
      notes: order.notes?.slice(0, 300) ?? null,
      customer: { name: order.customerName?.slice(0, 60) ?? "Guest", phone: null, email: null },
      createdBy: aggregator,
      createdAt: FieldValue.serverTimestamp(),
      deviceId: null,
      idempotencyKey: orderId,
    });
    return "created";
  });
  if (outcome === "refused") {
    await recordIncident("delivery_order_unmatched", "Delivery order for a closed or read-only store", {
      aggregator, orgId, locationId, externalId: order.externalId,
    });
  }
  return { outcome, orderId };
}

/** Managers push this location's menu (with prices and sold-out flags) to a linked aggregator. */
export async function syncDeliveryMenu(
  caller: Caller,
  data: unknown,
  registry: (id: AggregatorId) => DeliveryAggregator,
): Promise<{ items: number }> {
  const uid = requireUid(caller);
  const input = asInput(data);
  const orgId = docId(input, "orgId");
  const locationId = docId(input, "locationId");
  const aggregator = oneOf(input, "aggregator", AGGREGATOR_IDS);
  const member = await requireActiveMember(null, orgId, uid);
  if (!isManager(roleAt(member, locationId))) throw fail.denied();
  await requireWritableOrg(null, orgId);
  const link = await db().doc(deliveryPaths.locationLink(orgId, locationId, aggregator)).get();
  if (!link.exists) throw fail.precondition("Link this location to a delivery store first.");
  const menu = await loadStoreMenu(orgId, locationId);
  await registry(aggregator).pushMenu(link.get("externalStoreId") as string, menu);
  await db().doc(deliveryPaths.locationLink(orgId, locationId, aggregator)).update({
    menuSyncedAt: FieldValue.serverTimestamp(),
  });
  return { items: menu.reduce((n, s) => n + s.items.length, 0) };
}
