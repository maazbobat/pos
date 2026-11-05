/**
 * Third-party delivery (Uber Eats, DoorDash, SkipTheDishes) through an
 * aggregator such as Deliverect or Otter, behind one interface so going
 * direct to a marketplace later is another adapter, not a rewrite.
 *
 * An aggregator:
 * - sends us orders by webhook, which we verify, map to a location and
 *   store once even if it's sent again (handlers/delivery.ts);
 * - receives our menu for each mapped store (two-way sync: our menu and
 *   sold-out flags out, their orders in);
 * - can be told a store is paused or busy.
 *
 * Orders from marketplaces are already paid to the marketplace, so they
 * arrive as paid with the marketplace's prices. We keep its totals as they
 * are, because that's what the restaurant is settled on.
 */
import type { StoreSection } from "../orders/menu.js";

export const AGGREGATOR_IDS = ["deliverect", "fake"] as const;
export type AggregatorId = (typeof AGGREGATOR_IDS)[number];

/** The marketplace an order came through, as the aggregator names it. */
export type DeliveryChannel = "uber_eats" | "doordash" | "skip" | "other";

export interface ExternalOrderLine {
  /** Our menu item ID if the aggregator knows it (we send it as the PLU). */
  itemId: string | null;
  name: string;
  qty: number;
  /** Price of one, with options, in cents. */
  unitPriceCents: number;
  modifiers: { name: string; priceDeltaCents: number }[];
  notes: string | null;
}

export interface ExternalOrder {
  /** The aggregator's ID for the order. Deduplication key. */
  externalId: string;
  /** The aggregator's ID for the store, mapped to our location in deliveryStores. */
  externalStoreId: string;
  channel: DeliveryChannel;
  /** What the courier and the guest call it, for example "8F2A1". */
  displayId: string;
  fulfillment: "delivery" | "pickup";
  customerName: string | null;
  pickupAt: number | null;
  lines: ExternalOrderLine[];
  subtotalCents: number;
  taxCents: number;
  totalCents: number;
  notes: string | null;
}

export class AggregatorNotConfigured extends Error {
  constructor(readonly aggregator: AggregatorId, detail: string) {
    super(`${aggregator} isn't set up: ${detail}`);
  }
}

export interface DeliveryAggregator {
  readonly id: AggregatorId;
  /** Checks the webhook signature over the raw body. Throws if it doesn't match. */
  verifyWebhook(rawBody: Buffer, headers: Record<string, string | undefined>): void;
  /** Reads an order out of a verified webhook body, or null for other events. */
  parseOrder(body: unknown): ExternalOrder | null;
  pushMenu(externalStoreId: string, menu: StoreSection[]): Promise<void>;
  setStorePaused(externalStoreId: string, paused: boolean): Promise<void>;
}

/**
 * Deliverect. Needs Deliverect's partner agreement, then per restaurant a
 * Deliverect account with each marketplace connected, a channel link ID per
 * location and the webhook secret. Maaz is arranging the agreement; until
 * then every call fails clearly.
 *
 * When wired up: verify the HMAC header Deliverect signs order webhooks
 * with, map `channelLinkId` to externalStoreId and `channelOrderDisplayId`
 * to displayId, read prices in cents (Deliverect already uses integer
 * minor units), and push menus with its menu API using our item IDs as PLUs.
 */
export class DeliverectAggregator implements DeliveryAggregator {
  readonly id = "deliverect" as const;
  private fail(): never {
    throw new AggregatorNotConfigured("deliverect", "waiting on the Deliverect partner agreement.");
  }
  verifyWebhook(): void { this.fail(); }
  parseOrder(): ExternalOrder | null { this.fail(); }
  pushMenu(): Promise<void> { this.fail(); }
  setStorePaused(): Promise<void> { this.fail(); }
}

/**
 * A pretend aggregator for tests and the local emulators. Its "signature" is
 * a shared header value; its body is an ExternalOrder as JSON.
 */
export class FakeAggregator implements DeliveryAggregator {
  readonly id = "fake" as const;
  readonly menus = new Map<string, StoreSection[]>();
  readonly paused = new Map<string, boolean>();
  constructor(private readonly secret = "fake-secret") {}

  verifyWebhook(_raw: Buffer, headers: Record<string, string | undefined>): void {
    if (headers["x-fake-signature"] !== this.secret) throw new Error("Bad signature");
  }
  parseOrder(body: unknown): ExternalOrder | null {
    const b = body as { event?: string; order?: ExternalOrder };
    return b?.event === "order.created" && b.order ? b.order : null;
  }
  async pushMenu(externalStoreId: string, menu: StoreSection[]): Promise<void> {
    this.menus.set(externalStoreId, menu);
  }
  async setStorePaused(externalStoreId: string, paused: boolean): Promise<void> {
    this.paused.set(externalStoreId, paused);
  }
}

export type AggregatorRegistry = (id: AggregatorId) => DeliveryAggregator;

/** The fake only runs on the emulator, like the fake card terminal. */
export function defaultAggregators(): AggregatorRegistry {
  const deliverect = new DeliverectAggregator();
  const fake = process.env.FUNCTIONS_EMULATOR === "true" ? new FakeAggregator() : null;
  return (id) => {
    if (id === "deliverect") return deliverect;
    if (fake) return fake;
    throw new AggregatorNotConfigured("fake", "the test aggregator only runs on the emulator.");
  };
}
