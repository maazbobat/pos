# Orders, online ordering and delivery

Roadmap step 4. Every order, whoever placed it, is one document at
`orgs/{orgId}/locations/{locationId}/orders/{orderId}`, so the POS, the
kitchen display and reports read one place.

## The order document

| Field | Notes |
| --- | --- |
| `source` | `pos`, `online` or `delivery` |
| `ticket` | What staff call out. POS: three digits from the order ID. Online: `W-` and three digits. Delivery: the marketplace's own short ID |
| `status` | `new` → `in_progress` → `ready` → `completed`. Server-only: `awaiting_payment` (online, card not paid yet), `canceled` (never paid), `voided` (voidOrder) |
| `paymentStatus` | `unpaid`, `paid`, then `partially_refunded` / `refunded` from refunds |
| `fulfillment` | `here`, `takeout` (POS), `pickup` (online), `delivery` |
| `items[]` | `lineId, itemId, name, qty, unitPriceCents, modifiers[{groupId, optionId, name, priceDeltaCents}], lineTotalCents, taxable, kitchenStation, notes`. Names and prices are copied at sale time so menu edits never change past orders |
| `totals` | `subtotalCents, discountCents, taxCents, totalCents, taxes[{id, name, rate, cents}]` |
| `discounts[]` | `{type: percent or amount, value, reason}`. No manager PIN |
| `customer` | `{name, phone, email}` for online and delivery orders. Personal information: shown only to staff at that store |
| `pickupAt` | Online and delivery |
| `createdBy, createdAt, deviceId, staffUid, idempotencyKey` | Who rang it up; the device and the staff member signed in on it |

## Money

Integer cents everywhere. Pricing (`pos_shared` `priceOrder`, and
`functions/src/orders/pricing.ts` for the server) works like this:

1. Line = qty × (store price + chosen option prices).
2. Discounts come off before tax, percent rounded half up.
3. The discount is split between taxable and non-taxable lines in proportion.
4. Each tax rate from `settings/tax` is applied on its own and rounded half up,
   so GST and QST each show exactly as charged.

Both implementations run the same cases from
`packages/shared/test/fixtures/pricing_cases.json`. The rules check that
POS totals add up (`total = subtotal - discount + tax`, all whole cents);
they can't check item prices, which is why online orders are priced on the server.

## POS and kitchen display

- **Ringing up:** tap an item (choose options if it has any), adjust
  quantities, add a discount with a reason, pick for here or to go, then Cash.
  The order and its cash payment are one batch write with the order ID made on
  the tablet, so a sale goes through offline and syncs later.
- **Orders screen:** counter, online and delivery orders together. Take cash
  for an online order paid at pickup, mark orders picked up.
- **Kitchen display:** a tablet paired as a kitchen display skips the PIN pad
  and shows open tickets oldest first, with options, notes, ticket age and a
  station filter. Tap to move a ticket along.
- **Pause online orders** from the POS, kitchen display or manager app.

- **Card:** once a Stripe reader is paired, a Card button sends the total and
  tip to the reader. Receipts, kitchen tickets and the cash drawer go through
  Epson printers. See [counter.md](counter.md).

## Online ordering site (`apps/online`)

Each store has a web address (`/maple-cambridge`) set in the manager app's
Online tab. Launch polish (search and link previews, legal pages, cookies,
analytics) is in [online-site.md](online-site.md). Guests don't sign in; the site only calls public Functions:

| Function | Who | What |
| --- | --- | --- |
| `updateOnlineOrdering` | managers; any front-of-house role for pause only; owner for the Stripe account | Web address (unique, held in `storefronts/{slug}`), on/off, pause, pay at pickup, pay online, pickup lead time, the phone and email guests see. Audited |
| `getStorefront` | public | Store name, the location's address, its public phone and email, open or paused, menu with this store's prices and sold-out flags, tax rates. No kitchen routing or internal fields |
| `placeOnlineOrder` | public | Prices the cart from Firestore (the request carries item IDs and picks only), checks sold-out, option limits, lead time and the 48-hour scheduling window, then creates the order |
| `getOnlineOrderStatus` | public, with the order's token | Progress, ticket, items and total. A wrong token and a missing order get the same answer |
| `onlineCheckoutWebhook` | Stripe | Verified Checkout events from restaurants' accounts |

The browser makes a random 32-character token per checkout. It's the
idempotency key (a double tap returns the first order) and the secret for the
progress page; only its hash is stored.

**Pay at pickup:** the order goes straight to the kitchen as `unpaid`; staff
take cash from the Orders screen.

**Pay online:** Stripe Checkout on the restaurant's own Stripe account (Stripe
Connect), so the money goes to the restaurant. The order waits in
`awaiting_payment` (hidden from the kitchen, untouchable by staff) until the
webhook confirms the amount and account match, then becomes `new` and `paid`
with a `stripe_online` payment. An expired session (30 minutes) cancels it.
Anything that doesn't match raises a platform incident.

## Delivery marketplaces

`functions/src/delivery/aggregator.ts` defines `DeliveryAggregator` (verify
webhook, parse order, push menu, pause store). Deliverect is a stub until the
partner agreement is done; a fake runs in tests and on the emulator.

| Function | Who | What |
| --- | --- | --- |
| `linkDeliveryStore` | owner | Maps an aggregator store ID to a location (`deliveryStores/`, one location per store). Audited |
| `deliveryWebhook` | aggregator | `POST /deliveryWebhook/{aggregator}`. Verified first; 503 while the aggregator isn't set up so it retries |
| `syncDeliveryMenu` | managers | Pushes this location's menu, prices and sold-out flags |

Orders are stored once: the order ID is a hash of the aggregator and its
order ID, created in a transaction. They arrive `paid` with the marketplace's
totals. An order for an unlinked, closed or read-only store raises an
incident. Orders land in Firestore on the server, so a store whose tablets are
offline still has them when the tablets reconnect.

## Before launch (Maaz)

- **Stripe Connect:** enable Connect on the platform account, onboard each
  restaurant's account (Connect onboarding flow still to build; for now the
  owner pastes `acct_…`), add a Connect webhook for
  `checkout.session.completed`, `checkout.session.async_payment_succeeded`
  and `checkout.session.expired` pointing at `onlineCheckoutWebhook`, and set
  `STRIPE_CONNECT_WEBHOOK_SECRET` and `ORDERING_SITE_URL`. Decide whether the
  platform takes an application fee.
- **Refunds of online payments** go through the Stripe dashboard until the
  `stripe_online` provider's refund is wired up.
- **Abuse protection:** turn on App Check for the public Functions and add
  per-IP rate limits before the site is public.
- **Deliverect:** partner agreement, then per store a channel link and webhook secret.
- **Accountant:** confirm how tax on marketplace orders is reported (the
  marketplace's tax figures are stored as given) and that rounding per rate is right.
- **Privacy:** guest names, phones and emails on orders need a retention period
  in the privacy policy (PIPEDA).

## Not done yet

Store hours on the ordering site, guest notifications by SMS or email (the
progress page refreshes every 10 seconds), shared loyalty, cash drawer
sessions on the POS, combos, and the Connect onboarding flow. Counter
cards and printing are in [counter.md](counter.md).
