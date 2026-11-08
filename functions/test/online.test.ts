import { beforeEach, describe, expect, it } from "vitest";
import {
  getOnlineOrderStatus,
  getStorefront,
  handleOnlineCheckoutEvent,
  onlineOrderId,
  placeOnlineOrder,
  updateOnlineOrdering,
  validSlug,
} from "../src/handlers/online.js";
import { membershipData } from "../src/lib/tenant.js";
import type { OnlineCheckoutGateway, OnlineCheckoutRequest } from "../src/orders/checkout.js";
import { auditActions, caller, db, expectHttpsError, resetEmulators, seed, setOrg, u } from "./setup.js";

const ORG = "orgs/org-a";
const LOC = `${ORG}/locations/cambridge`;
const ids = { orgId: "org-a", locationId: "cambridge" };
const TOKEN = "guest-token-0123456789";
const DEVICE = "dev_cam_kds";

class FakeCheckout implements OnlineCheckoutGateway {
  readonly calls: OnlineCheckoutRequest[] = [];
  fail = false;
  async createCheckout(req: OnlineCheckoutRequest) {
    if (this.fail) throw new Error("stripe down");
    this.calls.push(req);
    return { url: `https://checkout.stripe.test/${req.orderId}`, sessionId: `cs_${req.orderId}` };
  }
}

let checkout: FakeCheckout;
const opts = { siteUrl: "https://order.example.test" };

beforeEach(async () => {
  await resetEmulators();
  await seed();
  checkout = new FakeCheckout();
  const batch = db().batch();
  batch.set(db().doc(`${LOC}/settings/tax`), { ...ids, province: "ON", rates: [{ id: "hst", name: "HST", rate: 0.13 }] });
  batch.set(db().doc(`${ORG}/config/brand`), { orgId: "org-a", displayName: "Maple Tea" });
  batch.set(db().doc(`${ORG}/menuCategories/tea`), { orgId: "org-a", name: "Tea", sortOrder: 0, active: true });
  batch.set(db().doc(`${ORG}/menuCategories/old`), { orgId: "org-a", name: "Old", sortOrder: 1, active: false });
  batch.set(db().doc(`${ORG}/menuItems/taro`), {
    orgId: "org-a", name: "Taro milk tea", description: null, categoryId: "tea", priceCents: 600,
    modifierGroupIds: ["size"], taxable: true, kitchenStation: "bar", active: true, sortOrder: 0,
  });
  batch.set(db().doc(`${ORG}/menuItems/mango`), {
    orgId: "org-a", name: "Mango slush", description: null, categoryId: "tea", priceCents: 550,
    modifierGroupIds: [], taxable: true, kitchenStation: "bar", active: true, sortOrder: 1,
  });
  batch.set(db().doc(`${ORG}/modifierGroups/size`), {
    orgId: "org-a", name: "Size", minSelect: 1, maxSelect: 1,
    options: [{ id: "m", name: "Medium", priceDeltaCents: 0 }, { id: "l", name: "Large", priceDeltaCents: 100 }],
  });
  // Cambridge charges 6.25 for taro, and mango is sold out here.
  batch.set(db().doc(`${LOC}/menuOverrides/taro`), { ...ids, itemId: "taro", available: true, priceCents: 625 });
  batch.set(db().doc(`${LOC}/menuOverrides/mango`), { ...ids, itemId: "mango", available: false, priceCents: null });
  batch.set(db().doc(`${ORG}/members/${DEVICE}`), membershipData("org-a", DEVICE, {
    kind: "device", orgRole: null, locationRoles: { cambridge: "device" },
  }));
  await batch.commit();
});

const turnOn = (extra: Record<string, unknown> = {}) =>
  updateOnlineOrdering(caller(u.managerCam), { ...ids, enabled: true, slug: "maple-cambridge", ...extra });

const cart = (extra: Record<string, unknown> = {}) => ({
  slug: "maple-cambridge",
  orderToken: TOKEN,
  payment: "at_pickup",
  items: [{ itemId: "taro", qty: 2, modifiers: { size: ["l"] }, notes: "less ice" }],
  customer: { name: "Sam", phone: "519-555-0100" },
  ...extra,
});

describe("online ordering settings", () => {
  it("lets a manager claim a unique web address and turn ordering on", async () => {
    const s = await turnOn();
    expect(s).toMatchObject({ enabled: true, slug: "maple-cambridge", payAtPickup: true, payOnline: false });
    expect((await db().doc("storefronts/maple-cambridge").get()).data()).toMatchObject(ids);
    await expectHttpsError(
      updateOnlineOrdering(caller(u.managerTor), { orgId: "org-a", locationId: "toronto", slug: "maple-cambridge" }),
      "already-exists",
    );
    // Changing the address frees the old one.
    await updateOnlineOrdering(caller(u.managerCam), { ...ids, slug: "maple-cam" });
    expect((await db().doc("storefronts/maple-cambridge").get()).exists).toBe(false);
    expect(await auditActions("org-a")).toContain("online.settings_updated");
  });

  it("lets front-of-house pause and resume, and nothing else", async () => {
    await turnOn();
    await updateOnlineOrdering(caller(u.kitchenCam), { ...ids, paused: true });
    await updateOnlineOrdering({ uid: DEVICE, email: null }, { ...ids, paused: false });
    await expectHttpsError(updateOnlineOrdering(caller(u.cashierCam), { ...ids, enabled: false }), "permission-denied");
    await expectHttpsError(updateOnlineOrdering(caller(u.managerTor), { ...ids, paused: true }), "permission-denied");
    await expectHttpsError(updateOnlineOrdering(caller(u.ownerB), { ...ids, paused: true }), "permission-denied");
    expect(await auditActions("org-a")).toEqual(expect.arrayContaining(["online.paused", "online.resumed"]));
  });

  it("keeps the Stripe account to the owner and checks the settings make sense", async () => {
    await expectHttpsError(turnOn({ stripeAccountId: "acct_123" }), "permission-denied");
    await expectHttpsError(
      updateOnlineOrdering(caller(u.managerCam), { ...ids, enabled: true }),
      "failed-precondition",
    );
    await expectHttpsError(turnOn({ payOnline: true }), "failed-precondition");
    await updateOnlineOrdering(caller(u.ownerA), { ...ids, stripeAccountId: "acct_123" });
    await expect(turnOn({ payOnline: true, payAtPickup: false })).resolves.toMatchObject({ payOnline: true });
    await expectHttpsError(turnOn({ slug: "Bad Slug!" }), "invalid-argument");
  });

  it("refuses changes while the org is read-only", async () => {
    await setOrg("org-a", { accessLevel: "read_only" });
    await expectHttpsError(turnOn(), "failed-precondition");
  });

  it("checks web addresses, keeping the site's own paths free", () => {
    expect(validSlug("maple-tea-cambridge")).toBe(true);
    for (const bad of ["ab", "-maple", "maple-", "maple--tea", "Maple", "a".repeat(41), "privacy", "terms", "sitemap"]) {
      expect(validSlug(bad)).toBe(false);
    }
  });

  it("keeps the store's public phone and email, and checks them", async () => {
    await turnOn();
    const s = await updateOnlineOrdering(caller(u.managerCam), {
      ...ids, contactPhone: "(519) 555-0199", contactEmail: "Hello@MapleTea.example",
    });
    expect(s).toMatchObject({ contactPhone: "(519) 555-0199", contactEmail: "hello@mapletea.example" });
    await expectHttpsError(updateOnlineOrdering(caller(u.managerCam), { ...ids, contactPhone: "555" }), "invalid-argument");
    await expectHttpsError(updateOnlineOrdering(caller(u.managerCam), { ...ids, contactEmail: "nope" }), "invalid-argument");
    await expectHttpsError(updateOnlineOrdering(caller(u.cashierCam), { ...ids, contactPhone: "519-555-0199" }), "permission-denied");
    expect(await updateOnlineOrdering(caller(u.managerCam), { ...ids, contactPhone: null })).toMatchObject({ contactPhone: null });
  });
});

describe("storefront", () => {
  it("shows this store's menu, prices and sold-out items, without internals", async () => {
    await turnOn();
    const store = await getStorefront({ slug: "maple-cambridge" });
    expect(store).toMatchObject({ brandName: "Maple Tea", locationName: "cambridge", open: true, payAtPickup: true });
    expect(store.taxRates).toEqual([{ id: "hst", name: "HST", rate: 0.13 }]);
    expect(store.sections.map((s) => s.name)).toEqual(["Tea"]);
    const [taro, mango] = store.sections[0].items;
    expect(taro).toMatchObject({ name: "Taro milk tea", priceCents: 625, available: true, kitchenStation: null });
    expect(mango).toMatchObject({ name: "Mango slush", available: false });
    // No address on file means none is shown: the site never makes one up.
    expect(store).toMatchObject({ address: null, phone: null, email: null });
  });

  it("shows the location's address and the store's contact details", async () => {
    await db().doc(LOC).update({ address: "  12 Main St, Cambridge, ON N1R 1A1 " });
    await turnOn({ contactPhone: "519-555-0199", contactEmail: "hi@maple.example" });
    expect(await getStorefront({ slug: "maple-cambridge" })).toMatchObject({
      address: "12 Main St, Cambridge, ON N1R 1A1", province: "ON", phone: "519-555-0199", email: "hi@maple.example",
    });
  });

  it("says when the store is paused or the org lapsed, and hides unknown stores", async () => {
    await turnOn();
    await updateOnlineOrdering(caller(u.cashierCam), { ...ids, paused: true });
    expect(await getStorefront({ slug: "maple-cambridge" })).toMatchObject({ open: false });
    await updateOnlineOrdering(caller(u.cashierCam), { ...ids, paused: false });
    await setOrg("org-a", { accessLevel: "read_only" });
    expect(await getStorefront({ slug: "maple-cambridge" })).toMatchObject({ open: false });
    await expectHttpsError(getStorefront({ slug: "nobody-here" }), "not-found");
  });
});

describe("placing an online order", () => {
  it("prices the cart on the server and sends a pay-at-pickup order straight to the kitchen", async () => {
    await turnOn();
    const placed = await placeOnlineOrder(cart({
      // A guest trying to set their own price is ignored: there's no field for it.
      items: [{ itemId: "taro", qty: 2, modifiers: { size: ["l"] }, notes: "less ice", priceCents: 1 }],
    }), checkout, opts);
    expect(placed).toMatchObject({ status: "new", checkoutUrl: null, totalCents: 1450 + 189 });
    expect(placed.ticket).toMatch(/^W-\d{3}$/);
    const order = (await db().doc(`${LOC}/orders/${placed.orderId}`).get()).data()!;
    expect(order).toMatchObject({
      ...ids, source: "online", status: "new", paymentStatus: "unpaid", payment: "at_pickup", fulfillment: "pickup",
      customer: { name: "Sam", phone: "519-555-0100", email: null },
      totals: { subtotalCents: 1450, discountCents: 0, taxCents: 189, totalCents: 1639 },
    });
    expect(order.items[0]).toMatchObject({
      itemId: "taro", name: "Taro milk tea", qty: 2, unitPriceCents: 625, lineTotalCents: 1450, kitchenStation: "bar",
      modifiers: [{ groupId: "size", optionId: "l", name: "Large", priceDeltaCents: 100 }], notes: "less ice",
    });
    expect(order.statusTokenHash).not.toContain(TOKEN);
    expect(checkout.calls).toHaveLength(0);
  });

  it("returns the first order when the guest taps twice", async () => {
    await turnOn();
    const first = await placeOnlineOrder(cart(), checkout, opts);
    const again = await placeOnlineOrder(cart(), checkout, opts);
    expect(again.orderId).toBe(first.orderId);
    expect((await db().collection(`${LOC}/orders`).get()).size).toBe(1);
  });

  it("refuses sold-out items, bad picks, closed stores and unset payment methods", async () => {
    await turnOn();
    await expectHttpsError(placeOnlineOrder(cart({ items: [{ itemId: "mango", qty: 1 }] }), checkout, opts), "failed-precondition");
    await expectHttpsError(placeOnlineOrder(cart({ items: [{ itemId: "taro", qty: 1 }] }), checkout, opts), "invalid-argument");
    await expectHttpsError(
      placeOnlineOrder(cart({ items: [{ itemId: "taro", qty: 1, modifiers: { size: ["xl"] } }] }), checkout, opts),
      "invalid-argument",
    );
    await expectHttpsError(placeOnlineOrder(cart({ items: [{ itemId: "ghost", qty: 1 }] }), checkout, opts), "failed-precondition");
    await expectHttpsError(placeOnlineOrder(cart({ items: [] }), checkout, opts), "invalid-argument");
    await expectHttpsError(placeOnlineOrder(cart({ payment: "online" }), checkout, opts), "failed-precondition");
    await updateOnlineOrdering(caller(u.cashierCam), { ...ids, paused: true });
    await expectHttpsError(placeOnlineOrder(cart(), checkout, opts), "failed-precondition");
    expect((await db().collection(`${LOC}/orders`).get()).size).toBe(0);
  });

  it("schedules pickups no sooner than the lead time and at most two days out", async () => {
    await turnOn({ pickupLeadMinutes: 20 });
    const now = Date.UTC(2026, 10, 5, 17, 0);
    const soon = await placeOnlineOrder(cart({ pickupAt: now + 60_000 }), checkout, { ...opts, now });
    const order = (await db().doc(`${LOC}/orders/${soon.orderId}`).get()).data()!;
    expect(order.pickupAt.toMillis()).toBe(now + 20 * 60_000);
    await expectHttpsError(
      placeOnlineOrder(cart({ orderToken: "another-token-0123456", pickupAt: now + 3 * 86_400_000 }), checkout, { ...opts, now }),
      "invalid-argument",
    );
  });
});

describe("paying online with Stripe Checkout", () => {
  beforeEach(async () => {
    await updateOnlineOrdering(caller(u.ownerA), { ...ids, stripeAccountId: "acct_maple" });
    await turnOn({ payOnline: true });
  });

  const completed = (orderId: string, extra: Record<string, unknown> = {}, type = "checkout.session.completed") => ({
    id: `evt_${Math.random()}`,
    type,
    account: "acct_maple",
    data: { object: { id: `cs_${orderId}`, payment_status: "paid", amount_total: 1639, payment_intent: "pi_1", metadata: { ...ids, orderId }, ...extra } },
  });

  it("holds the order until Stripe says it's paid, then sends it to the kitchen once", async () => {
    const placed = await placeOnlineOrder(cart({ payment: "online", customer: { name: "Sam", email: "sam@example.com" } }), checkout, opts);
    expect(placed).toMatchObject({ status: "awaiting_payment", checkoutUrl: `https://checkout.stripe.test/${placed.orderId}` });
    expect(checkout.calls[0]).toMatchObject({
      stripeAccountId: "acct_maple", totalCents: 1639, customerEmail: "sam@example.com", idempotencyKey: placed.orderId,
    });
    expect(checkout.calls[0].successUrl).toContain("https://order.example.test/maple-cambridge/order/");

    expect(await handleOnlineCheckoutEvent(completed(placed.orderId))).toBe("paid");
    expect(await handleOnlineCheckoutEvent(completed(placed.orderId))).toBe("duplicate");
    const order = (await db().doc(`${LOC}/orders/${placed.orderId}`).get()).data()!;
    expect(order).toMatchObject({ status: "new", paymentStatus: "paid" });
    const pays = await db().collection(`${LOC}/orders/${placed.orderId}/payments`).get();
    expect(pays.size).toBe(1);
    expect(pays.docs[0].data()).toMatchObject({ provider: "stripe_online", method: "card", amountCents: 1639, status: "succeeded" });
  });

  it("cancels an order whose checkout expired", async () => {
    const placed = await placeOnlineOrder(cart({ payment: "online" }), checkout, opts);
    expect(await handleOnlineCheckoutEvent(completed(placed.orderId, {}, "checkout.session.expired"))).toBe("canceled");
    expect((await db().doc(`${LOC}/orders/${placed.orderId}`).get()).get("status")).toBe("canceled");
  });

  it("refuses events with the wrong amount, account or session", async () => {
    const placed = await placeOnlineOrder(cart({ payment: "online" }), checkout, opts);
    expect(await handleOnlineCheckoutEvent(completed(placed.orderId, { amount_total: 100 }))).toBe("unmatched");
    expect(await handleOnlineCheckoutEvent({ ...completed(placed.orderId), account: "acct_other" })).toBe("unmatched");
    expect(await handleOnlineCheckoutEvent(completed(placed.orderId, { id: "cs_other" }))).toBe("unmatched");
    expect((await db().doc(`${LOC}/orders/${placed.orderId}`).get()).get("status")).toBe("awaiting_payment");
    const incidents = await db().collection("platformIncidents").get();
    expect(incidents.docs.map((d) => d.get("kind")).sort())
      .toEqual(["online_checkout_amount", "online_checkout_unmatched", "online_checkout_unmatched"]);
  });

  it("cancels the order if Stripe can't start a checkout", async () => {
    checkout.fail = true;
    await expectHttpsError(placeOnlineOrder(cart({ payment: "online" }), checkout, opts), "failed-precondition");
    const id = onlineOrderId("maple-cambridge", TOKEN);
    expect((await db().doc(`${LOC}/orders/${id}`).get()).get("status")).toBe("canceled");
  });
});

describe("order progress for the guest", () => {
  it("shows progress with the right token and nothing without it", async () => {
    await turnOn();
    const placed = await placeOnlineOrder(cart(), checkout, opts);
    await db().doc(`${LOC}/orders/${placed.orderId}`).update({ status: "ready" });
    const status = await getOnlineOrderStatus({ slug: "maple-cambridge", orderId: placed.orderId, orderToken: TOKEN });
    expect(status).toMatchObject({
      status: "ready", ticket: placed.ticket, totalCents: 1639, storeName: "Maple Tea · cambridge", address: null,
    });
    expect(status.items).toEqual([{ name: "Taro milk tea", qty: 2, modifiers: ["Large"] }]);
    expect(JSON.stringify(status)).not.toContain("519-555-0100");
    await expectHttpsError(
      getOnlineOrderStatus({ slug: "maple-cambridge", orderId: placed.orderId, orderToken: "wrong-token-0123456789" }),
      "not-found",
    );
  });
});
