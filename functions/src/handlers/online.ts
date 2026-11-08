/**
 * The restaurant's own ordering site (roadmap step 4), docs/orders.md.
 *
 *   updateOnlineOrdering   managers set the web address and options; any
 *                          front-of-house role can pause and resume
 *   getStorefront          public: the store's menu and whether it's taking orders
 *   placeOnlineOrder       public: prices the cart on the server and creates the order
 *   getOnlineOrderStatus   public, with the order's secret token: progress for the guest
 *   handleOnlineCheckoutEvent  Stripe webhook: paid → kitchen; expired → canceled
 *
 * Guests don't sign in. Every price comes from Firestore, never from the
 * request, and the order is written with the Admin SDK, so the tenant rules
 * stay closed to the public.
 */
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { logger } from "firebase-functions";
import { audit } from "../lib/audit.js";
import { fail } from "../lib/errors.js";
import { db } from "../lib/firebase.js";
import { sha256 } from "../lib/ids.js";
import { recordIncident } from "../lib/platform.js";
import { isManager, type Role } from "../lib/roles.js";
import {
  type Caller,
  paths,
  requireActiveMember,
  requireUid,
  requireWritableOrg,
  roleAt,
} from "../lib/tenant.js";
import { asInput, docId, type Input, optStr, str } from "../lib/validate.js";
import { CHECKOUT_EXPIRES_MINUTES, type OnlineCheckoutGateway } from "../orders/checkout.js";
import { loadStoreMenu, parseRequestedLines, priceRequestedLines, type StoreSection } from "../orders/menu.js";
import { priceOrder, type TaxRate, taxRatesFrom } from "../orders/pricing.js";

const PAUSERS: readonly Role[] = ["owner", "franchise_owner", "store_manager", "cashier", "kitchen", "device"];

export const onlinePaths = {
  settings: (o: string, l: string) => `${paths.location(o, l)}/settings/onlineOrdering`,
  storefront: (slug: string) => `storefronts/${slug}`,
  order: (o: string, l: string, id: string) => `${paths.location(o, l)}/orders/${id}`,
  payment: (o: string, l: string, orderId: string, id: string) =>
    `${paths.location(o, l)}/orders/${orderId}/payments/${id}`,
};

export interface OnlineSettings {
  enabled: boolean;
  paused: boolean;
  slug: string | null;
  payAtPickup: boolean;
  payOnline: boolean;
  pickupLeadMinutes: number;
  stripeAccountId: string | null;
  /** Shown on the ordering site, its receipts and its privacy page. */
  contactPhone: string | null;
  contactEmail: string | null;
}

const DEFAULTS: OnlineSettings = {
  enabled: false,
  paused: false,
  slug: null,
  payAtPickup: true,
  payOnline: false,
  pickupLeadMinutes: 15,
  stripeAccountId: null,
  contactPhone: null,
  contactEmail: null,
};

function settingsFrom(data: Record<string, unknown> | undefined): OnlineSettings {
  return { ...DEFAULTS, ...(data ?? {}) } as OnlineSettings;
}

/**
 * Paths the ordering site uses for itself, so no store can claim them.
 * Keep in step with apps/online (its routes) and functions/src/site/seo.ts.
 */
export const RESERVED_SLUGS: ReadonlySet<string> = new Set([
  "privacy", "terms", "cookies", "order", "orders", "sitemap", "robots", "api", "admin",
  "assets", "icons", "canvaskit", "favicon", "manifest", "index", "help", "support", "www",
]);

/** Lowercase letters, digits and single hyphens, 3 to 40 long: `maple-tea-cambridge`. */
export function validSlug(value: string): boolean {
  return /^[a-z0-9](?:[a-z0-9]|-(?=[a-z0-9])){2,39}$/.test(value) && !RESERVED_SLUGS.has(value);
}

/** A phone number a guest can dial: 10 to 15 digits, with spaces, dashes, dots, brackets or a leading +. */
export function validPhone(value: string): boolean {
  const digits = value.replace(/\D/g, "");
  return /^\+?[0-9 ().-]{10,25}$/.test(value) && digits.length >= 10 && digits.length <= 15;
}

export function validEmail(value: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(value);
}

function bool(input: Input, key: string): boolean | undefined {
  const v = input[key];
  if (v === undefined) return undefined;
  if (typeof v !== "boolean") throw fail.invalid(`${key} must be true or false.`);
  return v;
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

/**
 * Managers change everything except the Stripe account, which only the owner
 * sets (it decides where online money goes). Cashiers, kitchen staff and
 * devices may only pause or resume, for a rush or a broken fryer.
 */
export async function updateOnlineOrdering(caller: Caller, data: unknown): Promise<OnlineSettings> {
  const uid = requireUid(caller);
  const input = asInput(data);
  const orgId = docId(input, "orgId");
  const locationId = docId(input, "locationId");

  const changes: Partial<OnlineSettings> = {};
  const enabled = bool(input, "enabled");
  const paused = bool(input, "paused");
  const payAtPickup = bool(input, "payAtPickup");
  const payOnline = bool(input, "payOnline");
  if (enabled !== undefined) changes.enabled = enabled;
  if (paused !== undefined) changes.paused = paused;
  if (payAtPickup !== undefined) changes.payAtPickup = payAtPickup;
  if (payOnline !== undefined) changes.payOnline = payOnline;
  if (input.slug !== undefined) {
    const slug = str(input, "slug", { min: 3, max: 40 }).toLowerCase();
    if (!validSlug(slug)) throw fail.invalid("Use 3 to 40 lowercase letters, numbers and hyphens.");
    changes.slug = slug;
  }
  if (input.pickupLeadMinutes !== undefined) {
    const v = input.pickupLeadMinutes;
    if (typeof v !== "number" || !Number.isInteger(v) || v < 0 || v > 240) {
      throw fail.invalid("Pickup lead time is 0 to 240 minutes.");
    }
    changes.pickupLeadMinutes = v;
  }
  if (input.stripeAccountId !== undefined) {
    const v = optStr(input, "stripeAccountId", { max: 64 });
    if (v !== null && !/^acct_[A-Za-z0-9]+$/.test(v)) throw fail.invalid("A Stripe account ID starts with acct_.");
    changes.stripeAccountId = v;
  }
  if (input.contactPhone !== undefined) {
    const v = optStr(input, "contactPhone", { max: 25 });
    if (v !== null && !validPhone(v)) throw fail.invalid("Enter the store's phone number, like 519-555-0100.");
    changes.contactPhone = v;
  }
  if (input.contactEmail !== undefined) {
    const v = optStr(input, "contactEmail", { max: 120 })?.toLowerCase() ?? null;
    if (v !== null && !validEmail(v)) throw fail.invalid("Enter an email address, like hello@example.com.");
    changes.contactEmail = v;
  }
  if (Object.keys(changes).length === 0) throw fail.invalid("Nothing to change.");

  return db().runTransaction(async (tx) => {
    const member = await requireActiveMember(tx, orgId, uid);
    const role = roleAt(member, locationId);
    const onlyPause = Object.keys(changes).every((k) => k === "paused");
    if (!role || !(onlyPause ? PAUSERS.includes(role) : isManager(role))) throw fail.denied();
    if ("stripeAccountId" in changes && role !== "owner") throw fail.denied("Only the owner sets the Stripe account.");
    await requireWritableOrg(tx, orgId);
    const loc = await tx.get(db().doc(paths.location(orgId, locationId)));
    if (!loc.exists) throw fail.notFound("Location not found.");

    const ref = db().doc(onlinePaths.settings(orgId, locationId));
    const current = settingsFrom((await tx.get(ref)).data());
    const next: OnlineSettings = { ...current, ...changes };
    if (next.enabled && !next.slug) throw fail.precondition("Choose a web address before turning online ordering on.");
    if (next.enabled && !next.payAtPickup && !next.payOnline) throw fail.precondition("Allow at least one way to pay.");
    if (next.payOnline && !next.stripeAccountId) {
      throw fail.precondition("Online card payments need the restaurant's Stripe account first.");
    }

    if (changes.slug && changes.slug !== current.slug) {
      const claim = db().doc(onlinePaths.storefront(changes.slug));
      const taken = await tx.get(claim);
      if (taken.exists && (taken.get("orgId") !== orgId || taken.get("locationId") !== locationId)) {
        throw fail.conflict("That web address is taken.");
      }
      tx.set(claim, { orgId, locationId, createdAt: FieldValue.serverTimestamp() });
      if (current.slug) tx.delete(db().doc(onlinePaths.storefront(current.slug)));
    }
    tx.set(ref, {
      orgId,
      locationId,
      ...next,
      updatedAt: FieldValue.serverTimestamp(),
      updatedBy: uid,
    });
    audit(tx, orgId, {
      action: onlyPause ? (next.paused ? "online.paused" : "online.resumed") : "online.settings_updated",
      actorUid: uid,
      actorKind: member.kind,
      locationId,
      target: { changes: Object.keys(changes) },
    });
    return next;
  });
}

// ---------------------------------------------------------------------------
// Public storefront
// ---------------------------------------------------------------------------

interface Store {
  orgId: string;
  locationId: string;
  settings: OnlineSettings;
  locationName: string;
  brandName: string;
  timezone: string;
  /** The location's street address as entered for it, or null. Never made up. */
  address: string | null;
  province: string | null;
  /** Online ordering is on and the org and location are active: worth showing to search engines. */
  listed: boolean;
  /** Why the store isn't taking orders, or null when it is. */
  closedReason: string | null;
  taxRates: TaxRate[];
}

export async function loadStore(slug: string): Promise<Store> {
  if (!validSlug(slug)) throw fail.notFound("We couldn't find that restaurant.");
  const link = await db().doc(onlinePaths.storefront(slug)).get();
  if (!link.exists) throw fail.notFound("We couldn't find that restaurant.");
  const orgId = link.get("orgId") as string;
  const locationId = link.get("locationId") as string;
  const [org, loc, settingsSnap, tax, brand] = await Promise.all([
    db().doc(paths.org(orgId)).get(),
    db().doc(paths.location(orgId, locationId)).get(),
    db().doc(onlinePaths.settings(orgId, locationId)).get(),
    db().doc(`${paths.location(orgId, locationId)}/settings/tax`).get(),
    db().doc(`${paths.org(orgId)}/config/brand`).get(),
  ]);
  const settings = settingsFrom(settingsSnap.data());
  if (!org.exists || !loc.exists || settings.slug !== slug) throw fail.notFound("We couldn't find that restaurant.");
  let closedReason: string | null = null;
  const listed = settings.enabled && org.get("status") === "active" && loc.get("status") === "active";
  if (!listed) {
    closedReason = "This restaurant isn't taking online orders.";
  } else if (org.get("accessLevel") !== "full") {
    closedReason = "This restaurant isn't taking online orders right now.";
  } else if (settings.paused) {
    closedReason = "This restaurant has paused online orders for a little while.";
  }
  return {
    orgId,
    locationId,
    settings,
    locationName: (loc.get("name") as string | undefined) ?? "",
    brandName: (brand.get("displayName") as string | undefined) ?? (org.get("name") as string | undefined) ?? "",
    timezone: (loc.get("timezone") as string | undefined) ?? "America/Toronto",
    address: ((loc.get("address") as string | null | undefined) ?? "").trim() || null,
    province: (loc.get("province") as string | undefined) ?? null,
    listed,
    closedReason,
    taxRates: taxRatesFrom(tax.data()),
  };
}

export interface Storefront {
  slug: string;
  brandName: string;
  locationName: string;
  timezone: string;
  /** Where to pick up, and how to reach the store: the tenant's own data. */
  address: string | null;
  province: string | null;
  phone: string | null;
  email: string | null;
  open: boolean;
  closedReason: string | null;
  payAtPickup: boolean;
  payOnline: boolean;
  pickupLeadMinutes: number;
  taxRates: TaxRate[];
  sections: StoreSection[];
}

/** What the ordering site shows. Leaves out kitchen routing and anything internal. */
export async function getStorefront(data: unknown): Promise<Storefront> {
  const input = asInput(data);
  const slug = str(input, "slug", { min: 3, max: 40 }).toLowerCase();
  const store = await loadStore(slug);
  const sections = store.settings.enabled ? await loadStoreMenu(store.orgId, store.locationId) : [];
  return {
    slug,
    brandName: store.brandName,
    locationName: store.locationName,
    timezone: store.timezone,
    address: store.address,
    province: store.province,
    phone: store.settings.contactPhone,
    email: store.settings.contactEmail,
    open: store.closedReason === null,
    closedReason: store.closedReason,
    payAtPickup: store.settings.payAtPickup,
    payOnline: store.settings.payOnline && !!store.settings.stripeAccountId,
    pickupLeadMinutes: store.settings.pickupLeadMinutes,
    taxRates: store.taxRates,
    sections: sections.map((s) => ({
      ...s,
      items: s.items.map((i) => ({ ...i, kitchenStation: null })),
    })),
  };
}

// ---------------------------------------------------------------------------
// Placing an order
// ---------------------------------------------------------------------------

/** How far ahead a guest can schedule a pickup. */
export const MAX_SCHEDULE_HOURS = 48;

export interface PlacedOrder {
  orderId: string;
  ticket: string;
  totalCents: number;
  status: string;
  /** Present when the guest pays by card: send them here. */
  checkoutUrl: string | null;
}

export function onlineOrderId(slug: string, key: string): string {
  return `web_${sha256(`${slug}:${key}`).slice(0, 28)}`;
}

/** "W-" and three digits from the order ID, for calling out at the counter. */
export function onlineTicket(orderId: string): string {
  return `W-${(parseInt(sha256(orderId).slice(0, 8), 16) % 900) + 100}`;
}

export interface OnlineOptions {
  /** Where the ordering site lives, for Stripe's return links. Never from the request. */
  siteUrl: string;
  now?: number;
}

/**
 * Creates the order from the guest's cart. The guest's `orderToken` (a
 * random string their browser makes) is both the idempotency key, so a
 * double tap or a retry finds the first order, and the secret that lets
 * them see its progress. Only its hash is stored.
 */
export async function placeOnlineOrder(
  data: unknown,
  gateway: OnlineCheckoutGateway | null,
  opts: OnlineOptions,
): Promise<PlacedOrder> {
  const input = asInput(data);
  const slug = str(input, "slug", { min: 3, max: 40 }).toLowerCase();
  const token = str(input, "orderToken", { min: 16, max: 100 });
  if (!/^[A-Za-z0-9_-]+$/.test(token)) throw fail.invalid("orderToken must be letters, digits, - or _.");
  const payment = input.payment === "online" ? "online" : input.payment === "at_pickup" ? "at_pickup" : null;
  if (!payment) throw fail.invalid("payment must be online or at_pickup.");
  const requested = parseRequestedLines(input.items);
  const customer = (input.customer ?? {}) as Input;
  const name = str(customer, "name", { min: 1, max: 60 });
  const phone = optStr(customer, "phone", { max: 20 });
  if (phone !== null && !/^[0-9+() .-]{7,20}$/.test(phone)) throw fail.invalid("That phone number doesn't look right.");
  const email = optStr(customer, "email", { max: 254 });
  if (email !== null && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) throw fail.invalid("That email doesn't look right.");
  const notes = optStr(input, "notes", { max: 300 });

  const now = opts.now ?? Date.now();
  const orderId = onlineOrderId(slug, token);
  const tokenHash = sha256(token);

  const store = await loadStore(slug);
  const ref = db().doc(onlinePaths.order(store.orgId, store.locationId, orderId));
  const existing = await ref.get();
  if (existing.exists) {
    if (existing.get("statusTokenHash") !== tokenHash) throw fail.conflict("Try placing the order again.");
    return {
      orderId,
      ticket: existing.get("ticket"),
      totalCents: existing.get("totals.totalCents"),
      status: existing.get("status"),
      checkoutUrl: existing.get("status") === "awaiting_payment" ? existing.get("checkoutUrl") ?? null : null,
    };
  }
  if (store.closedReason) throw fail.precondition(store.closedReason);
  if (payment === "at_pickup" && !store.settings.payAtPickup) throw fail.precondition("Pay online for this restaurant.");
  if (payment === "online" && (!store.settings.payOnline || !store.settings.stripeAccountId || !gateway)) {
    throw fail.precondition("Online card payments aren't set up for this restaurant.");
  }

  const earliest = now + store.settings.pickupLeadMinutes * 60_000;
  let pickupAt = earliest;
  if (input.pickupAt !== undefined && input.pickupAt !== null) {
    const asked = input.pickupAt;
    if (typeof asked !== "number" || !Number.isFinite(asked)) throw fail.invalid("pickupAt must be a time in milliseconds.");
    if (asked > now + MAX_SCHEDULE_HOURS * 3_600_000) throw fail.invalid("Pickups can be scheduled up to two days ahead.");
    pickupAt = Math.max(asked, earliest);
  }

  const menu = await loadStoreMenu(store.orgId, store.locationId);
  const items = priceRequestedLines(menu, requested);
  const totals = priceOrder(items, [], store.taxRates);
  if (totals.totalCents <= 0) throw fail.invalid("The order total must be more than zero.");
  const ticket = onlineTicket(orderId);

  await ref.create({
    orgId: store.orgId,
    locationId: store.locationId,
    source: "online",
    ticket,
    status: payment === "online" ? "awaiting_payment" : "new",
    paymentStatus: "unpaid",
    payment,
    fulfillment: "pickup",
    pickupAt: Timestamp.fromMillis(pickupAt),
    items,
    totals,
    discounts: [],
    notes,
    customer: { name, phone, email },
    statusTokenHash: tokenHash,
    createdBy: "online",
    createdAt: FieldValue.serverTimestamp(),
    deviceId: null,
    idempotencyKey: orderId,
    checkoutUrl: null,
  }).catch(async (err: unknown) => {
    // Two taps at once: the other one created it.
    if ((err as { code?: number }).code === 6) return;
    throw err;
  });

  if (payment === "at_pickup") {
    return { orderId, ticket, totalCents: totals.totalCents, status: "new", checkoutUrl: null };
  }

  const back = `${opts.siteUrl}/${slug}/order/${orderId}?t=${encodeURIComponent(token)}`;
  try {
    const session = await gateway!.createCheckout({
      orgId: store.orgId,
      locationId: store.locationId,
      orderId,
      stripeAccountId: store.settings.stripeAccountId!,
      description: `Order ${ticket} at ${store.brandName} ${store.locationName}`.trim(),
      totalCents: totals.totalCents,
      customerEmail: email,
      successUrl: back,
      cancelUrl: back,
      idempotencyKey: orderId,
    });
    await ref.update({ checkoutUrl: session.url, checkoutSessionId: session.sessionId });
    return { orderId, ticket, totalCents: totals.totalCents, status: "awaiting_payment", checkoutUrl: session.url };
  } catch (err) {
    logger.error("Online checkout failed", { orgId: store.orgId, orderId, err: String(err) });
    await ref.update({ status: "canceled", cancelReason: "checkout_failed" });
    throw fail.precondition("We couldn't start the card payment. Please try again.");
  }
}

// ---------------------------------------------------------------------------
// Order progress for the guest
// ---------------------------------------------------------------------------

export interface OnlineOrderStatus {
  orderId: string;
  /** For the thank-you page: who has the order and where to pick it up. */
  storeName: string;
  address: string | null;
  phone: string | null;
  ticket: string;
  status: string;
  paymentStatus: string;
  pickupAt: number | null;
  totalCents: number;
  checkoutUrl: string | null;
  items: { name: string; qty: number; modifiers: string[] }[];
}

export async function getOnlineOrderStatus(data: unknown): Promise<OnlineOrderStatus> {
  const input = asInput(data);
  const slug = str(input, "slug", { min: 3, max: 40 }).toLowerCase();
  const orderId = docId(input, "orderId");
  const token = str(input, "orderToken", { min: 16, max: 100 });
  const notFound = () => fail.notFound("We couldn't find that order.");
  if (!validSlug(slug)) throw notFound();
  const link = await db().doc(onlinePaths.storefront(slug)).get();
  if (!link.exists) throw notFound();
  const snap = await db().doc(onlinePaths.order(link.get("orgId"), link.get("locationId"), orderId)).get();
  // Same answer for a wrong token and a missing order, so IDs can't be probed.
  if (!snap.exists || snap.get("statusTokenHash") !== sha256(token)) throw notFound();
  const order = snap.data()!;
  const store = await loadStore(slug).catch(() => null);
  return {
    orderId,
    storeName: store ? [store.brandName, store.locationName].filter(Boolean).join(" · ") : "",
    address: store?.address ?? null,
    phone: store?.settings.contactPhone ?? null,
    ticket: order.ticket,
    status: order.status,
    paymentStatus: order.paymentStatus,
    pickupAt: (order.pickupAt as Timestamp | undefined)?.toMillis() ?? null,
    totalCents: order.totals?.totalCents ?? 0,
    checkoutUrl: order.status === "awaiting_payment" ? order.checkoutUrl ?? null : null,
    items: ((order.items ?? []) as { name: string; qty: number; modifiers?: { name: string }[] }[]).map((l) => ({
      name: l.name,
      qty: l.qty,
      modifiers: (l.modifiers ?? []).map((m) => m.name),
    })),
  };
}

// ---------------------------------------------------------------------------
// Stripe webhook for online payments (connected accounts)
// ---------------------------------------------------------------------------

export interface CheckoutEventLike {
  id: string;
  type: string;
  account?: string;
  data: { object: Record<string, unknown> };
}

export type CheckoutOutcome = "paid" | "canceled" | "duplicate" | "ignored" | "unmatched";

/**
 * Applies a verified Checkout event from a restaurant's Stripe account.
 * Idempotent: the payment document's ID comes from the session, and an order
 * that already left awaiting_payment isn't changed. A session that doesn't
 * match its order (wrong account or amount) raises an incident instead.
 */
export async function handleOnlineCheckoutEvent(event: CheckoutEventLike): Promise<CheckoutOutcome> {
  if (event.type !== "checkout.session.completed" && event.type !== "checkout.session.expired"
    && event.type !== "checkout.session.async_payment_succeeded") {
    return "ignored";
  }
  const session = event.data.object as {
    id?: string;
    payment_status?: string;
    amount_total?: number;
    payment_intent?: string | { id: string } | null;
    metadata?: Record<string, string>;
  };
  const meta = session.metadata ?? {};
  const { orgId, locationId, orderId } = meta;
  if (!session.id || !orgId || !locationId || !orderId
    || ![orgId, locationId, orderId].every((v) => /^[A-Za-z0-9_-]{1,128}$/.test(v))) {
    return "ignored";
  }

  type Problem = { kind: "online_checkout_unmatched" | "online_checkout_amount"; message: string; extra?: Record<string, unknown> };
  const result = await db().runTransaction(async (tx): Promise<{ outcome: CheckoutOutcome; problem?: Problem }> => {
    const orderRef = db().doc(onlinePaths.order(orgId, locationId, orderId));
    const settingsRef = db().doc(onlinePaths.settings(orgId, locationId));
    const [order, settings] = await Promise.all([tx.get(orderRef), tx.get(settingsRef)]);
    if (!order.exists || order.get("source") !== "online" || order.get("checkoutSessionId") !== session.id) {
      return { outcome: "unmatched", problem: { kind: "online_checkout_unmatched", message: "Stripe Checkout event for an unknown order" } };
    }
    if (event.account && settings.get("stripeAccountId") !== event.account) {
      return { outcome: "unmatched", problem: { kind: "online_checkout_unmatched", message: "Checkout event from a different Stripe account" } };
    }
    if (order.get("status") !== "awaiting_payment") return { outcome: "duplicate" };

    if (event.type === "checkout.session.expired") {
      tx.update(orderRef, { status: "canceled", cancelReason: "not_paid", updatedAt: FieldValue.serverTimestamp() });
      return { outcome: "canceled" };
    }
    if (session.payment_status !== "paid") return { outcome: "ignored" };
    const total = order.get("totals.totalCents") as number;
    if (session.amount_total !== total) {
      return {
        outcome: "unmatched",
        problem: {
          kind: "online_checkout_amount",
          message: "Online payment amount doesn't match the order",
          extra: { paid: session.amount_total ?? null, total },
        },
      };
    }
    const paymentId = `online_${sha256(session.id!).slice(0, 28)}`;
    const intent = typeof session.payment_intent === "string" ? session.payment_intent : session.payment_intent?.id ?? null;
    tx.set(db().doc(onlinePaths.payment(orgId, locationId, orderId, paymentId)), {
      orgId,
      locationId,
      orderId,
      method: "card",
      provider: "stripe_online",
      amountCents: total,
      tipCents: 0,
      refundedCents: 0,
      status: "succeeded",
      providerRef: intent,
      checkoutSessionId: session.id,
      stripeAccountId: event.account ?? null,
      idempotencyKey: paymentId,
      createdBy: "stripe",
      createdAt: FieldValue.serverTimestamp(),
      settledAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    tx.update(orderRef, {
      status: "new",
      paymentStatus: "paid",
      paidAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    return { outcome: "paid" };
  });
  if (result.problem) {
    await recordIncident(result.problem.kind, result.problem.message, {
      eventId: event.id, orgId, locationId, orderId, ...result.problem.extra,
    });
  }
  return result.outcome;
}

export { CHECKOUT_EXPIRES_MINUTES };
