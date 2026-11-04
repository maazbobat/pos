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

  for (const [orgId, org] of Object.entries(ORGS) as [OrgId, (typeof ORGS)[OrgId]][]) {
    const o = `orgs/${orgId}`;
    set(o, { name: org.name, type: org.type, status: "active", accessLevel: "full", plan: "professional" });
    set(`${o}/billing/subscription`, { orgId, status: "active", plan: "professional" });
    set(`${o}/config/brand`, { orgId, displayName: org.name, primaryColor: "#2E7D32" });
    set(`${o}/menuItems/item-1`, { orgId, name: "House drink", price: 5.5 });
    set(`${o}/promotions/promo-1`, { orgId, name: "Happy hour", percentOff: 10 });
    set(`${o}/auditLog/evt-org`, { orgId, action: "org.created", createdAt: past });
    set(`${o}/reports/rollup`, { orgId, kind: "sales", total: 1000 });

    set(`${o}/members/${ownerUid(orgId)}`, membership(orgId, ownerUid(orgId), "owner"));
    const firstLoc = Object.keys(org.locations)[0];
    set(`${o}/members/${extraUid(orgId)}`, membership(orgId, extraUid(orgId), "cashier", firstLoc));

    for (const [locId, locName] of Object.entries(org.locations)) {
      const l = `${o}/locations/${locId}`;
      const ids = { orgId, locationId: locId };
      set(l, { ...ids, name: locName, status: "active", timezone: "America/Toronto", province: "ON" });
      set(`${l}/settings/hardware`, { ...ids, printerIp: "192.168.1.50", drawer: "printer" });
      set(`${l}/menuOverrides/item-1`, { ...ids, itemId: "item-1", available: true, price: 6 });
      set(`${l}/staff/${extraUid(orgId)}`, { ...ids, role: "cashier" });
      set(`${l}/devices/device-other`, { ...ids, type: "pos", status: "active", appVersion: "0.1.0" });
      set(`${l}/orders/order-1`, order(ids, "unpaid", memberUid(orgId, locId, "cashier")));
      set(`${l}/orders/order-1/payments/pay-1`, {
        ...ids, orderId: "order-1", method: "cash", amount: 5.5, createdBy: "seed", createdAt: past,
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

export function order(
  ids: { orgId: string; locationId: string },
  paymentStatus: "unpaid" | "paid",
  createdBy: string,
) {
  return {
    ...ids,
    status: "new",
    paymentStatus,
    items: [{ itemId: "item-1", qty: 1, price: 5.5 }],
    totals: { subtotal: 5.5, tax: 0.72, total: 6.22 },
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
