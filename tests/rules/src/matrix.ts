/**
 * The permission matrix, as data.
 *
 * Every operation is run against Org A's Cambridge store by every subject in
 * matrix.test.ts. `allowed` lists the roles that must succeed; every other
 * role, every Toronto-only role (for location-scoped operations), all of Org
 * B, a platform admin without a support grant and a signed-out caller must
 * be denied. Keep this in step with docs/permissions.md.
 */
import {
  collection,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  serverTimestamp,
  setDoc,
  updateDoc,
  type Firestore,
} from "firebase/firestore";
import { cashSession, order, type Role } from "./fixtures.js";

export const TARGET_ORG = "org-a";
export const TARGET_LOC = "cambridge";

const ORG = `orgs/${TARGET_ORG}`;
const LOC = `${ORG}/locations/${TARGET_LOC}`;
const IDS = { orgId: TARGET_ORG, locationId: TARGET_LOC };

export interface OpContext {
  /** The caller's uid ("anonymous" when signed out). */
  uid: string;
  /** Unique per test case, for documents the case creates. */
  id: string;
}

export interface Operation {
  name: string;
  /** "org": any location role counts. "location": only roles held at Cambridge. */
  scope: "org" | "location";
  allowed: readonly Role[];
  setup?: (admin: Firestore, ctx: OpContext) => Promise<void>;
  run: (db: Firestore, ctx: OpContext) => Promise<unknown>;
}

const ALL: Role[] = [
  "owner", "franchise_owner", "store_manager", "cashier", "kitchen",
  "inventory_manager", "accountant", "device",
];
const MANAGERS: Role[] = ["owner", "franchise_owner", "store_manager"];
const SELLERS: Role[] = [...MANAGERS, "cashier", "device"];
const MONEY_READERS: Role[] = [...MANAGERS, "accountant"];
const INVENTORY_EDITORS: Role[] = [...MANAGERS, "inventory_manager"];
const NOBODY: Role[] = [];

const newOrder = (ctx: OpContext, overrides: Record<string, unknown> = {}) => ({
  ...IDS,
  status: "new",
  paymentStatus: "paid",
  items: [{ itemId: "item-1", qty: 2, price: 5.5 }],
  totals: { subtotal: 11, tax: 1.43, total: 12.43 },
  discounts: [],
  createdBy: ctx.uid,
  createdAt: serverTimestamp(),
  deviceId: null,
  idempotencyKey: ctx.id,
  ...overrides,
});

const seedOrder = (paymentStatus: "unpaid" | "paid") => (admin: Firestore, ctx: OpContext) =>
  setDoc(doc(admin, `${LOC}/orders/${ctx.id}`), order(IDS, paymentStatus, "someone-else"));

const seedSession = (openedBy: "self" | "other", status: "open" | "closed") =>
  (admin: Firestore, ctx: OpContext) =>
    setDoc(
      doc(admin, `${LOC}/cashSessions/${ctx.id}`),
      cashSession(IDS, openedBy === "self" ? ctx.uid : "someone-else", status),
    );

export const OPERATIONS: Operation[] = [
  // ---------- Organization ----------
  {
    name: "read org profile",
    scope: "org",
    allowed: ALL,
    run: (db) => getDoc(doc(db, ORG)),
  },
  {
    name: "rename the org",
    scope: "org",
    allowed: ["owner"],
    run: (db) => updateDoc(doc(db, ORG), { name: "Maple Tea Co", updatedAt: serverTimestamp() }),
  },
  {
    name: "change org accessLevel or status",
    scope: "org",
    allowed: NOBODY,
    run: (db) => updateDoc(doc(db, ORG), { accessLevel: "full", status: "active", plan: "franchise" }),
  },
  {
    name: "read brand config",
    scope: "org",
    allowed: ALL,
    run: (db) => getDoc(doc(db, `${ORG}/config/brand`)),
  },
  {
    name: "edit brand config",
    scope: "org",
    allowed: ["owner"],
    run: (db) => setDoc(doc(db, `${ORG}/config/brand`), {
      orgId: TARGET_ORG, displayName: "Maple Tea Co", primaryColor: "#1B5E20",
    }),
  },
  {
    name: "read franchise menu",
    scope: "org",
    allowed: ALL,
    run: (db) => getDocs(collection(db, `${ORG}/menuItems`)),
  },
  {
    name: "create franchise menu item",
    scope: "org",
    allowed: ["owner"],
    run: (db, ctx) => setDoc(doc(db, `${ORG}/menuItems/${ctx.id}`), {
      orgId: TARGET_ORG, name: "Mango slush", price: 6.25,
    }),
  },
  {
    name: "create menu item tagged with another org",
    scope: "org",
    allowed: NOBODY,
    run: (db, ctx) => setDoc(doc(db, `${ORG}/menuItems/${ctx.id}`), {
      orgId: "org-b", name: "Mango slush", price: 6.25,
    }),
  },
  {
    name: "create promotion",
    scope: "org",
    allowed: ["owner"],
    run: (db, ctx) => setDoc(doc(db, `${ORG}/promotions/${ctx.id}`), {
      orgId: TARGET_ORG, name: "Two for one", percentOff: 50,
    }),
  },
  {
    name: "read subscription status",
    scope: "org",
    allowed: ["owner", "franchise_owner", "accountant"],
    run: (db) => getDoc(doc(db, `${ORG}/billing/subscription`)),
  },
  {
    name: "change subscription status",
    scope: "org",
    allowed: NOBODY,
    run: (db) => setDoc(doc(db, `${ORG}/billing/subscription`), {
      orgId: TARGET_ORG, status: "active", plan: "franchise",
    }),
  },
  {
    name: "read another member's membership",
    scope: "org",
    allowed: ["owner"],
    run: (db) => getDoc(doc(db, `${ORG}/members/${TARGET_ORG}-extra`)),
  },
  {
    name: "grant yourself the owner role",
    scope: "org",
    allowed: NOBODY,
    run: (db, ctx) => setDoc(
      doc(db, `${ORG}/members/${ctx.uid}`),
      { orgRole: "owner", status: "active" },
      { merge: true },
    ),
  },
  {
    name: "read org-level audit event",
    scope: "org",
    allowed: ["owner"],
    run: (db) => getDoc(doc(db, `${ORG}/auditLog/evt-org`)),
  },
  {
    name: "read Cambridge audit event",
    scope: "location",
    allowed: ["owner", "franchise_owner"],
    run: (db) => getDoc(doc(db, `${ORG}/auditLog/evt-${TARGET_LOC}`)),
  },
  {
    name: "write audit log",
    scope: "org",
    allowed: NOBODY,
    run: (db, ctx) => setDoc(doc(db, `${ORG}/auditLog/${ctx.id}`), {
      orgId: TARGET_ORG, action: "forged", createdAt: serverTimestamp(),
    }),
  },
  {
    name: "read org rollup report",
    scope: "org",
    allowed: ["owner"],
    run: (db) => getDoc(doc(db, `${ORG}/reports/rollup`)),
  },
  {
    name: "create a support grant",
    scope: "org",
    allowed: NOBODY,
    run: (db, ctx) => setDoc(doc(db, `${ORG}/supportGrants/${ctx.uid}`), {
      reason: "self-granted", expiresAt: new Date(Date.now() + 3_600_000),
    }),
  },

  // ---------- Location ----------
  {
    name: "read location",
    scope: "location",
    allowed: ALL,
    run: (db) => getDoc(doc(db, LOC)),
  },
  {
    name: "rename location",
    scope: "location",
    allowed: MANAGERS,
    run: (db) => updateDoc(doc(db, LOC), { name: "Cambridge" }),
  },
  {
    name: "close location directly",
    scope: "location",
    allowed: NOBODY,
    run: (db) => updateDoc(doc(db, LOC), { status: "closed" }),
  },
  {
    name: "read hardware settings",
    scope: "location",
    allowed: ALL,
    run: (db) => getDoc(doc(db, `${LOC}/settings/hardware`)),
  },
  {
    name: "change printer IP",
    scope: "location",
    allowed: MANAGERS,
    run: (db) => updateDoc(doc(db, `${LOC}/settings/hardware`), { printerIp: "192.168.1.51" }),
  },
  {
    name: "set a location price override",
    scope: "location",
    allowed: MANAGERS,
    // A fresh document per case: writing a value that is already stored is
    // not a change, and the rules rightly allow it.
    setup: (admin, ctx) => setDoc(doc(admin, `${LOC}/menuOverrides/${ctx.id}`), {
      ...IDS, itemId: ctx.id, available: true, price: 6,
    }),
    run: (db, ctx) => updateDoc(doc(db, `${LOC}/menuOverrides/${ctx.id}`), { price: 6.5 }),
  },
  {
    name: "mark an item sold out",
    scope: "location",
    allowed: [...SELLERS, "kitchen"],
    setup: (admin, ctx) => setDoc(doc(admin, `${LOC}/menuOverrides/${ctx.id}`), {
      ...IDS, itemId: ctx.id, available: true,
    }),
    run: (db, ctx) => updateDoc(doc(db, `${LOC}/menuOverrides/${ctx.id}`), {
      available: false, updatedAt: serverTimestamp(), updatedBy: ctx.uid,
    }),
  },
  {
    name: "list location staff",
    scope: "location",
    allowed: MANAGERS,
    run: (db) => getDocs(collection(db, `${LOC}/staff`)),
  },

  // ---------- Orders ----------
  {
    name: "create an order",
    scope: "location",
    allowed: SELLERS,
    run: (db, ctx) => setDoc(doc(db, `${LOC}/orders/${ctx.id}`), newOrder(ctx)),
  },
  {
    name: "create an order with a discount, no PIN",
    scope: "location",
    allowed: SELLERS,
    run: (db, ctx) => setDoc(doc(db, `${LOC}/orders/${ctx.id}`), newOrder(ctx, {
      discounts: [{ type: "percent", value: 15, reason: "regular" }],
    })),
  },
  {
    name: "create an order claiming the Toronto location",
    scope: "location",
    allowed: NOBODY,
    run: (db, ctx) => setDoc(
      doc(db, `${LOC}/orders/${ctx.id}`),
      newOrder(ctx, { locationId: "toronto" }),
    ),
  },
  {
    name: "create an order claiming Org B",
    scope: "location",
    allowed: NOBODY,
    run: (db, ctx) => setDoc(doc(db, `${LOC}/orders/${ctx.id}`), newOrder(ctx, { orgId: "org-b" })),
  },
  {
    name: "create an order as someone else",
    scope: "location",
    allowed: NOBODY,
    run: (db, ctx) => setDoc(
      doc(db, `${LOC}/orders/${ctx.id}`),
      newOrder(ctx, { createdBy: "someone-else" }),
    ),
  },
  {
    name: "create an order already voided",
    scope: "location",
    allowed: NOBODY,
    run: (db, ctx) => setDoc(doc(db, `${LOC}/orders/${ctx.id}`), newOrder(ctx, { status: "voided" })),
  },
  {
    name: "read an order",
    scope: "location",
    allowed: [...SELLERS, "kitchen", "accountant"],
    run: (db) => getDoc(doc(db, `${LOC}/orders/order-1`)),
  },
  {
    name: "list orders",
    scope: "location",
    allowed: [...SELLERS, "kitchen", "accountant"],
    run: (db) => getDocs(collection(db, `${LOC}/orders`)),
  },
  {
    name: "apply a discount to an open order",
    scope: "location",
    allowed: SELLERS,
    setup: seedOrder("unpaid"),
    run: (db, ctx) => updateDoc(doc(db, `${LOC}/orders/${ctx.id}`), {
      discounts: [{ type: "percent", value: 10 }],
      totals: { subtotal: 5.5, discount: 0.55, tax: 0.64, total: 5.59 },
    }),
  },
  {
    name: "move an order's prep status",
    scope: "location",
    allowed: [...SELLERS, "kitchen"],
    setup: seedOrder("unpaid"),
    run: (db, ctx) => updateDoc(doc(db, `${LOC}/orders/${ctx.id}`), {
      status: "in_progress", updatedAt: serverTimestamp(), updatedBy: ctx.uid,
    }),
  },
  {
    name: "move an order to another location",
    scope: "location",
    allowed: NOBODY,
    setup: seedOrder("unpaid"),
    run: (db, ctx) => updateDoc(doc(db, `${LOC}/orders/${ctx.id}`), { locationId: "toronto" }),
  },
  {
    name: "void an order directly",
    scope: "location",
    allowed: NOBODY,
    setup: seedOrder("paid"),
    run: (db, ctx) => updateDoc(doc(db, `${LOC}/orders/${ctx.id}`), { status: "voided" }),
  },
  {
    name: "refund an order directly",
    scope: "location",
    allowed: NOBODY,
    setup: seedOrder("paid"),
    run: (db, ctx) => updateDoc(doc(db, `${LOC}/orders/${ctx.id}`), { paymentStatus: "refunded" }),
  },
  {
    name: "change totals on a paid order",
    scope: "location",
    allowed: NOBODY,
    setup: seedOrder("paid"),
    run: (db, ctx) => updateDoc(doc(db, `${LOC}/orders/${ctx.id}`), {
      totals: { subtotal: 1, tax: 0, total: 1 },
    }),
  },
  {
    name: "delete an order",
    scope: "location",
    allowed: NOBODY,
    setup: seedOrder("unpaid"),
    run: (db, ctx) => deleteDoc(doc(db, `${LOC}/orders/${ctx.id}`)),
  },

  // ---------- Payments ----------
  {
    name: "record a cash payment",
    scope: "location",
    allowed: SELLERS,
    run: (db, ctx) => setDoc(doc(db, `${LOC}/orders/order-1/payments/${ctx.id}`), {
      ...IDS, orderId: "order-1", method: "cash", amount: 6.22,
      createdBy: ctx.uid, createdAt: serverTimestamp(),
    }),
  },
  {
    name: "record a card payment from the client",
    scope: "location",
    allowed: NOBODY,
    run: (db, ctx) => setDoc(doc(db, `${LOC}/orders/order-1/payments/${ctx.id}`), {
      ...IDS, orderId: "order-1", method: "card", amount: 6.22,
      createdBy: ctx.uid, createdAt: serverTimestamp(),
    }),
  },
  {
    name: "read payments",
    scope: "location",
    allowed: [...SELLERS, "accountant"],
    run: (db) => getDoc(doc(db, `${LOC}/orders/order-1/payments/pay-1`)),
  },
  {
    name: "edit a payment",
    scope: "location",
    allowed: NOBODY,
    run: (db) => updateDoc(doc(db, `${LOC}/orders/order-1/payments/pay-1`), { amount: 0.01 }),
  },

  // ---------- Cash sessions ----------
  {
    name: "open a cash session",
    scope: "location",
    allowed: SELLERS,
    run: (db, ctx) => setDoc(doc(db, `${LOC}/cashSessions/${ctx.id}`), {
      ...IDS, openedBy: ctx.uid, openedAt: serverTimestamp(), status: "open", float: 150,
    }),
  },
  {
    name: "open a cash session in someone else's name",
    scope: "location",
    allowed: NOBODY,
    run: (db, ctx) => setDoc(doc(db, `${LOC}/cashSessions/${ctx.id}`), {
      ...IDS, openedBy: "someone-else", openedAt: serverTimestamp(), status: "open", float: 150,
    }),
  },
  {
    name: "read own open cash session",
    scope: "location",
    allowed: [...SELLERS, "accountant"],
    setup: seedSession("self", "open"),
    run: (db, ctx) => getDoc(doc(db, `${LOC}/cashSessions/${ctx.id}`)),
  },
  {
    name: "read someone else's open cash session",
    scope: "location",
    allowed: [...MONEY_READERS, "device"],
    setup: seedSession("other", "open"),
    run: (db, ctx) => getDoc(doc(db, `${LOC}/cashSessions/${ctx.id}`)),
  },
  {
    name: "read someone else's closed cash session",
    scope: "location",
    allowed: MONEY_READERS,
    setup: seedSession("other", "closed"),
    run: (db, ctx) => getDoc(doc(db, `${LOC}/cashSessions/${ctx.id}`)),
  },
  {
    name: "close own cash session",
    scope: "location",
    allowed: SELLERS,
    setup: seedSession("self", "open"),
    run: (db, ctx) => updateDoc(doc(db, `${LOC}/cashSessions/${ctx.id}`), {
      status: "closed", countedCash: 412.5, closedAt: serverTimestamp(), closedBy: ctx.uid,
    }),
  },
  {
    name: "close someone else's cash session",
    scope: "location",
    allowed: [...MANAGERS, "device"],
    setup: seedSession("other", "open"),
    run: (db, ctx) => updateDoc(doc(db, `${LOC}/cashSessions/${ctx.id}`), {
      status: "closed", countedCash: 412.5, closedAt: serverTimestamp(), closedBy: ctx.uid,
    }),
  },
  {
    name: "edit a closed cash session",
    scope: "location",
    allowed: NOBODY,
    setup: seedSession("self", "closed"),
    run: (db, ctx) => updateDoc(doc(db, `${LOC}/cashSessions/${ctx.id}`), { countedCash: 500 }),
  },
  {
    name: "record a paid-out on own open session",
    scope: "location",
    allowed: SELLERS,
    setup: seedSession("self", "open"),
    run: (db, ctx) => setDoc(doc(db, `${LOC}/cashSessions/${ctx.id}/movements/m1`), {
      ...IDS, type: "paid_out", amount: 12, reason: "milk",
      createdBy: ctx.uid, createdAt: serverTimestamp(),
    }),
  },

  // ---------- Inventory ----------
  {
    name: "read inventory",
    scope: "location",
    allowed: [...INVENTORY_EDITORS, "kitchen", "accountant"],
    run: (db) => getDoc(doc(db, `${LOC}/inventoryItems/inv-1`)),
  },
  {
    name: "update a stock count",
    scope: "location",
    allowed: INVENTORY_EDITORS,
    run: (db) => updateDoc(doc(db, `${LOC}/inventoryItems/inv-1`), { quantity: 18 }),
  },
  {
    name: "record a stock movement",
    scope: "location",
    allowed: INVENTORY_EDITORS,
    run: (db, ctx) => setDoc(doc(db, `${LOC}/stockMovements/${ctx.id}`), {
      ...IDS, itemId: "inv-1", delta: -2, reason: "waste",
      createdBy: ctx.uid, createdAt: serverTimestamp(),
    }),
  },
  {
    name: "create a purchase order",
    scope: "location",
    allowed: INVENTORY_EDITORS,
    run: (db, ctx) => setDoc(doc(db, `${LOC}/purchaseOrders/${ctx.id}`), {
      ...IDS, supplier: "Pearl Supply", lines: [{ itemId: "inv-1", qty: 10 }],
      status: "draft", createdBy: ctx.uid, createdAt: serverTimestamp(),
    }),
  },

  // ---------- Devices ----------
  {
    name: "read another device",
    scope: "location",
    allowed: MANAGERS,
    run: (db) => getDoc(doc(db, `${LOC}/devices/device-other`)),
  },
  {
    name: "report own device health",
    scope: "location",
    allowed: ["device"],
    setup: (admin, ctx) => setDoc(doc(admin, `${LOC}/devices/${ctx.uid}`), {
      ...IDS, type: "pos", status: "active", appVersion: "0.1.0",
    }),
    run: (db, ctx) => updateDoc(doc(db, `${LOC}/devices/${ctx.uid}`), {
      appVersion: "0.1.1", lastSeenAt: serverTimestamp(), printerStatus: "ok",
    }),
  },
  {
    name: "register a device directly",
    scope: "location",
    allowed: NOBODY,
    run: (db, ctx) => setDoc(doc(db, `${LOC}/devices/${ctx.id}`), {
      ...IDS, type: "pos", status: "active",
    }),
  },

  // ---------- Reports ----------
  {
    name: "read sales report",
    scope: "location",
    allowed: MONEY_READERS,
    run: (db) => getDoc(doc(db, `${LOC}/reports/daily-sales`)),
  },
  {
    name: "read inventory report",
    scope: "location",
    allowed: [...MONEY_READERS, "inventory_manager"],
    run: (db) => getDoc(doc(db, `${LOC}/reports/daily-inventory`)),
  },
  {
    name: "write a report",
    scope: "location",
    allowed: NOBODY,
    run: (db) => setDoc(doc(db, `${LOC}/reports/daily-sales`), { ...IDS, kind: "sales", total: 1 }),
  },
];
