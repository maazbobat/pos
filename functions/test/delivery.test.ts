import { beforeEach, describe, expect, it } from "vitest";
import { type ExternalOrder, FakeAggregator } from "../src/delivery/aggregator.js";
import { deliveryOrderId, ingestDeliveryOrder, linkDeliveryStore, syncDeliveryMenu } from "../src/handlers/delivery.js";
import { auditActions, caller, db, expectHttpsError, resetEmulators, seed, setOrg, u } from "./setup.js";

const LOC = "orgs/org-a/locations/cambridge";
const ids = { orgId: "org-a", locationId: "cambridge" };

let fake: FakeAggregator;
const registry = () => fake;

beforeEach(async () => {
  await resetEmulators();
  await seed();
  fake = new FakeAggregator();
  await db().doc("orgs/org-a/menuCategories/tea").set({ orgId: "org-a", name: "Tea", sortOrder: 0, active: true });
  await db().doc("orgs/org-a/menuItems/taro").set({
    orgId: "org-a", name: "Taro milk tea", categoryId: "tea", priceCents: 600, modifierGroupIds: [],
    taxable: true, kitchenStation: "bar", active: true, sortOrder: 0,
  });
});

const external = (extra: Partial<ExternalOrder> = {}): ExternalOrder => ({
  externalId: "ue-123",
  externalStoreId: "store-cam",
  channel: "uber_eats",
  displayId: "8F2A1",
  fulfillment: "delivery",
  customerName: "Alex",
  pickupAt: null,
  lines: [{ itemId: "taro", name: "Taro milk tea", qty: 2, unitPriceCents: 750, modifiers: [{ name: "Large", priceDeltaCents: 100 }], notes: null }],
  subtotalCents: 1500,
  taxCents: 195,
  totalCents: 1695,
  notes: "Ring the bell",
  ...extra,
});

const link = (who = u.ownerA, extra: Record<string, unknown> = {}) =>
  linkDeliveryStore(caller(who), { ...ids, aggregator: "fake", externalStoreId: "store-cam", ...extra });

describe("linking delivery stores", () => {
  it("is owner-only, audited, and one location per store", async () => {
    await expectHttpsError(link(u.managerCam), "permission-denied");
    await link();
    expect(await auditActions("org-a")).toContain("delivery.store_linked");
    await expectHttpsError(
      linkDeliveryStore(caller(u.ownerA), { orgId: "org-a", locationId: "toronto", aggregator: "fake", externalStoreId: "store-cam" }),
      "already-exists",
    );
    await expectHttpsError(
      linkDeliveryStore(caller(u.ownerB), { orgId: "org-b", locationId: "halifax", aggregator: "fake", externalStoreId: "store-cam" }),
      "already-exists",
    );
  });
});

describe("delivery order intake", () => {
  it("stores a marketplace order once, as paid, with the marketplace's prices", async () => {
    await link();
    const first = await ingestDeliveryOrder("fake", external());
    const again = await ingestDeliveryOrder("fake", external());
    expect(first).toEqual({ outcome: "created", orderId: deliveryOrderId("fake", "ue-123") });
    expect(again.outcome).toBe("duplicate");
    const orders = await db().collection(`${LOC}/orders`).get();
    expect(orders.size).toBe(1);
    expect(orders.docs[0].data()).toMatchObject({
      ...ids, source: "delivery", channel: "uber_eats", ticket: "8F2A1", status: "new", paymentStatus: "paid",
      fulfillment: "delivery", totals: { subtotalCents: 1500, taxCents: 195, totalCents: 1695 },
      customer: { name: "Alex" }, notes: "Ring the bell",
    });
    expect(orders.docs[0].get("items")[0]).toMatchObject({ unitPriceCents: 650, lineTotalCents: 1500, qty: 2 });
  });

  it("raises an incident for unlinked stores, bad shapes and lapsed tenants", async () => {
    expect((await ingestDeliveryOrder("fake", external())).outcome).toBe("unmatched");
    await link();
    expect((await ingestDeliveryOrder("fake", external({ totalCents: 12.5 }))).outcome).toBe("refused");
    await setOrg("org-a", { accessLevel: "read_only" });
    expect((await ingestDeliveryOrder("fake", external({ externalId: "ue-999" }))).outcome).toBe("refused");
    expect((await db().collection(`${LOC}/orders`).get()).size).toBe(0);
    expect((await db().collection("platformIncidents").get()).size).toBe(3);
  });
});

describe("menu sync", () => {
  it("pushes this location's menu to the linked store, for managers only", async () => {
    await expectHttpsError(syncDeliveryMenu(caller(u.managerCam), { ...ids, aggregator: "fake" }, registry), "failed-precondition");
    await link();
    await expectHttpsError(syncDeliveryMenu(caller(u.cashierCam), { ...ids, aggregator: "fake" }, registry), "permission-denied");
    await expect(syncDeliveryMenu(caller(u.managerCam), { ...ids, aggregator: "fake" }, registry)).resolves.toEqual({ items: 1 });
    expect(fake.menus.get("store-cam")?.[0].items[0]).toMatchObject({ id: "taro", priceCents: 600, available: true });
  });
});
