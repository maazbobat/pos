import { doc, Timestamp, writeBatch, type Firestore } from "firebase/firestore";

/** Roles held per location (the owner role is org-wide). */
export const LOCATION_ROLES = [
  "franchise_owner",
  "store_manager",
  "cashier",
  "kitchen",
  "inventory_manager",
  "accountant",
  "device",
] as const;

export type LocationRole = (typeof LOCATION_ROLES)[number];
export type Role = "owner" | LocationRole;

export const ORGS = {
  "org-a": {
    name: "Maple Tea Co",
    type: "franchise",
    locations: { cambridge: "Cambridge", toronto: "Toronto" },
  },
  "org-b": {
    name: "Harbour Grill",
    type: "independent",
    locations: { halifax: "Halifax", dartmouth: "Dartmouth" },
  },
} as const;

export type OrgId = keyof typeof ORGS;

export const PLATFORM_ADMIN = "platform-admin";

export const ownerUid = (org: OrgId) => `${org}-owner`;
export const memberUid = (org: OrgId, loc: string, role: LocationRole) => `${org}-${loc}-${role}`;
/** A member nobody signs in as, used to test reading someone else's membership. */
export const extraUid = (org: OrgId) => `${org}-extra`;

const past = Timestamp.fromMillis(Date.UTC(2026, 0, 1));

/** Seeds two orgs, each with two locations and a member for every role. */
export async function seed(db: Firestore): Promise<void> {
  const batch = writeBatch(db);
  const set = (path: string, data: Record<string, unknown>) => batch.set(doc(db, path), data);

  set(`platformAdmins/${PLATFORM_ADMIN}`, { createdAt: past });
  set("platformOrgs/org-a", { orgId: "org-a", name: "Maple Tea Co", plan: "professional", status: "active" });
  set("platformAuditLog/evt-1", { orgId: "org-a", action: "org.created", createdAt: past });
  set("platformHealth/summary", { staleDevices: 0, checkedAt: past });
  set("platformIncidents/inc-1", { kind: "payment_stuck", orgId: "org-a", resolved: false });
  set("stripeCustomers/cus_123", { orgId: "org-a" });
  set("stripeEvents/evt_123", { orgId: "org-a", type: "invoice.paid" });
  set("storefronts/maple-cambridge", { orgId: "org-a", locationId: "cambridge" });
  set("deliveryStores/fake_store-1", { orgId: "org-a", locationId: "cambridge" });

  for (const [orgId, org] of Object.entries(ORGS) as [OrgId, (typeof ORGS)[OrgId]][]) {
    const o = `orgs/${orgId}`;
    set(o, { name: org.name, type: org.type, status: "active", accessLevel: "full", plan: "professional" });
    set(`${o}/billing/subscription`, { orgId, status: "active", plan: "professional" });
    set(`${o}/config/brand`, { orgId, displayName: org.name, primaryColor: "#2E7D32" });
    set(`${o}/menuCategories/cat-1`, { orgId, name: "Drinks", sortOrder: 0, active: true });
    set(`${o}/menuItems/item-1`, menuItem(orgId));
    set(`${o}/modifierGroups/mod-1`, modifierGroup(orgId));
    set(`${o}/promotions/promo-1`, { orgId, name: "Happy hour", percentOff: 10 });
    set(`${o}/auditLog/evt-org`, { orgId, action: "org.created", createdAt: past });
    set(`${o}/reports/rollup`, { orgId, kind: "sales", total: 1000 });

    set(`${o}/members/${ownerUid(orgId)}`, membership(orgId, ownerUid(orgId), "owner"));
    const firstLoc = Object.keys(org.locations)[0];
    set(`${o}/members/${extraUid(orgId)}`, membership(orgId, extraUid(orgId), "cashier", firstLoc));

    set(`${o}/invites/inv-owner`, { orgId, locationId: null, email: "new-owner@example.com", role: "owner", status: "pending" });
    set(`${o}/pinIndex/pin-key-1`, { uid: extraUid(orgId) });
    set(`${o}/memberSecrets/${extraUid(orgId)}`, { pinKey: "pin-key-1" });

    for (const [locId, locName] of Object.entries(org.locations)) {
      const l = `${o}/locations/${locId}`;
      const ids = { orgId, locationId: locId };
      set(l, { ...ids, name: locName, status: "active", timezone: "America/Toronto", province: "ON" });
      set(`${l}/settings/hardware`, { ...ids, printerIp: "192.168.1.50", drawer: "printer" });
      set(`${l}/settings/onlineOrdering`, { ...ids, enabled: true, paused: false, slug: `${orgId}-${locId}` });
      set(`${l}/menuOverrides/item-1`, { ...ids, itemId: "item-1", available: true, priceCents: 600 });
      set(`${l}/staff/${extraUid(orgId)}`, { ...ids, role: "cashier" });
      set(`${l}/devices/device-other`, { ...ids, type: "pos", status: "active", appVersion: "0.1.0" });
      set(`${l}/devices/device-other/private/pinGuard`, { failures: 2, lockedUntil: null });
      set(`${o}/invites/inv-${locId}`, { ...ids, email: `new-${locId}@example.com`, role: "cashier", status: "pending" });
      set(`${l}/orders/order-1`, order(ids, "unpaid", memberUid(orgId, locId, "cashier")));
      set(`${l}/orders/order-1/payments/pay-1`, {
        ...ids, orderId: "order-1", method: "cash", provider: "cash", amountCents: 550, tipCents: 0,
        status: "succeeded", idempotencyKey: "pay-1", createdBy: "seed", createdAt: past,
      });
      set(`${l}/orders/order-1/refunds/refund-1`, {
        ...ids, orderId: "order-1", paymentId: "pay-1", amountCents: 100, status: "succeeded", reason: "spilled",
      });
      set(`${l}/inventoryItems/inv-1`, { ...ids, name: "Tapioca pearls", quantity: 20, unit: "kg" });
      set(`${l}/reports/daily-sales`, { ...ids, kind: "sales", total: 500 });
      set(`${l}/reports/daily-inventory`, { ...ids, kind: "inventory", lowStock: 2 });
      set(`${o}/auditLog/evt-${locId}`, { ...ids, action: "settings.updated", createdAt: past });

      for (const role of LOCATION_ROLES) {
        const uid = memberUid(orgId, locId, role);
        set(`${o}/members/${uid}`, membership(orgId, uid, role, locId));
      }
    }
  }
  await batch.commit();
}

export function membership(orgId: OrgId, uid: string, role: Role, locId?: string) {
  return {
    uid,
    orgId,
    kind: role === "device" ? "device" : "user",
    status: "active",
    orgRole: role === "owner" ? "owner" : null,
    locationRoles: role === "owner" || !locId ? {} : { [locId]: role },
    roles: [role],
  };
}

export function menuItem(orgId: string, overrides: Record<string, unknown> = {}) {
  return {
    orgId,
    name: "House drink",
    description: null,
    categoryId: "cat-1",
    priceCents: 550,
    modifierGroupIds: ["mod-1"],
    taxable: true,
    kitchenStation: "bar",
    active: true,
    sortOrder: 0,
    ...overrides,
  };
}

export function modifierGroup(orgId: string, overrides: Record<string, unknown> = {}) {
  return {
    orgId,
    name: "Sweetness",
    minSelect: 1,
    maxSelect: 1,
    options: [
      { id: "full", name: "100%", priceDeltaCents: 0 },
      { id: "half", name: "50%", priceDeltaCents: 0 },
    ],
    ...overrides,
  };
}

export function order(
  ids: { orgId: string; locationId: string },
  paymentStatus: "unpaid" | "paid",
  createdBy: string,
) {
  return {
    ...ids,
    source: "pos",
    ticket: "101",
    status: "new",
    paymentStatus,
    fulfillment: "here",
    items: [orderLine()],
    totals: { subtotalCents: 550, discountCents: 0, taxCents: 72, totalCents: 622 },
    discounts: [],
    createdBy,
    createdAt: past,
    deviceId: null,
    idempotencyKey: `seed-${createdBy}`,
  };
}

export function cashSession(
  ids: { orgId: string; locationId: string },
  openedBy: string,
  status: "open" | "closed",
) {
  return { ...ids, openedBy, openedAt: past, status, float: 100 };
}

export function orderLine(overrides: Record<string, unknown> = {}) {
  return {
    lineId: "l1", itemId: "item-1", name: "House drink", qty: 1, unitPriceCents: 550,
    modifiers: [], lineTotalCents: 550, taxable: true, kitchenStation: "bar", notes: null,
    ...overrides,
  };
}

/** An order the ordering site placed (written by Functions in real use). */
export function onlineOrder(
  ids: { orgId: string; locationId: string },
  status: "awaiting_payment" | "new",
  paymentStatus: "unpaid" | "paid",
) {
  return {
    ...order(ids, paymentStatus, "online"),
    source: "online",
    ticket: "W-417",
    status,
    fulfillment: "pickup",
    customer: { name: "Sam", phone: "5195550100", email: null },
    statusTokenHash: "abc",
  };
}
