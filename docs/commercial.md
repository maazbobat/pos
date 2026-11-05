# Commercial operations

Roadmap step 3: billing, payments, audit logs, platform support access and
monitoring. All of it is Cloud Functions in `functions/src/handlers/`, tested
against the emulators with `npm run test:functions`. Nothing here talks to a
real Stripe or Clover account in tests.

## Billing

`orgs/{orgId}/billing/subscription` is the server-side source of truth.
Only Functions write it, and `org.accessLevel` is derived from it
(`functions/src/billing/access.ts`):

| State | Access |
| --- | --- |
| Free trial (30 days from creation) or active subscription | full |
| Payment failed, subscription cancelled, or trial over | full for a 14-day grace period from when it lapsed |
| Grace period over | `read_only`: everyone can still read and export, nobody writes |
| Paid again | full, and the lapse is forgotten |

`read_only` blocks writes in both `firestore.rules` and every Function, but
reads are never blocked by billing, so owners always keep their data.
Starting Checkout and opening the billing portal still work while read-only,
so a lapsed owner can pay.

| Function | Who | What |
| --- | --- | --- |
| `startCheckout` | owner | Stripe Checkout for Starter or Professional. Creates one Stripe customer per org and links it server-side (`stripeCustomers/{id}`). Return URLs are fixed by `MANAGER_APP_URL`, never taken from the request |
| `openBillingPortal` | owner | Stripe's customer portal (card changes, cancel, invoices) |
| `stripeWebhook` | Stripe | HTTPS endpoint. Verifies the signature over the raw body, then applies the event |
| `setManualPlan` | platform admin | Franchise and other custom deals, pilots, comped accounts. Needs a reason |
| `extendTrial` | platform admin | Extends the free trial by 1 to 90 days. Needs a reason |
| `enforceBillingAccess` | hourly | Ends trials and grace periods on time |

The webhook is idempotent (each event ID is stored in `stripeEvents/` in the
same transaction that applies it), ignores events older than the last one
applied to that subscription, ignores late events from a replaced
subscription, and refuses events for a customer no org is linked to or whose
metadata names a different org. Those raise a platform incident instead.

Plans and prices: Starter and Professional are bought through Checkout; their
prices live in Stripe so they can change without a deploy. Franchise is
custom, set with `setManualPlan`.

### Setting up Stripe (Maaz)

In a Stripe **test-mode** account, per Firebase project:

1. Create two recurring CAD prices with these lookup keys:
   `pos_starter_monthly_cad` (~$79/mo) and `pos_professional_monthly_cad` (~$149/mo).
2. Add a webhook endpoint pointing at the deployed `stripeWebhook` URL, sending
   `checkout.session.completed`, `customer.subscription.created`, `.updated`,
   `.deleted`, `.paused`, `.resumed`, `invoice.paid` and `invoice.payment_failed`.
3. Set the secrets: `firebase functions:secrets:set STRIPE_SECRET_KEY` and
   `STRIPE_WEBHOOK_SECRET` (the endpoint's `whsec_…`).
4. Set `MANAGER_APP_URL` to the manager app's address.
5. Turn on the customer portal in Stripe's settings.

Sales tax on the subscription itself (GST/HST on SaaS fees) needs the
accountant's answer before turning on Stripe Tax.

## Payments

`functions/src/payments/provider.ts` defines `PaymentProvider`: `charge`,
`lookup`, `cancel`, `refund`, all idempotent on the POS's idempotency key,
all in whole cents, and none of them ever returns or stores card data.

| Provider | State |
| --- | --- |
| `cash` | Done. The POS writes cash payments directly so they work offline; the rules check their shape and use the idempotency key as the document ID |
| `clover` | Interface only. Throws "not set up" until Clover's certification is done |
| `stripe_terminal` | Interface only. Needs Stripe Terminal locations and readers |
| `fake_card` | A pretend terminal for tests and the local emulators only. Refused in a deployed project |

A location picks its card provider in `locations/{id}/settings/payments`
(`cardProvider`, `terminals: {id: {ref, name}}`), which managers edit.

| Function | Who | What |
| --- | --- | --- |
| `startCardPayment` | sellers | Creates a pending payment, then asks the provider to charge. A retry with the same key returns the first attempt. Won't take more than is left to pay |
| `refreshPayment` | sellers | Asks the provider what happened (the POS polls this) |
| `cancelCardPayment` | sellers | Stops a charge the guest hasn't completed |
| `refundPayment` | managers, or a device with a manager's PIN | Partial or full, tip included, never more than was paid. Audited with the reason |
| `voidOrder` | managers, or a device with a manager's PIN | Only once nothing is left paid on the order. Audited |
| `recoverPendingPayments` | every 10 min | Settles charges we never heard back about. A charge the provider never saw fails after 15 min; one still pending at the provider after 30 min raises an incident |

A manager PIN typed on a device counts toward the same 5-tries lockout as
signing in, and a cashier's PIN counts as wrong.

Reconciliation today means recovering interrupted charges and keeping each
order's `paymentStatus` (`unpaid`, `paid`, `partially_refunded`, `refunded`)
in line with its payments. Matching against the processor's settlement
reports comes with the Clover and Stripe Terminal adapters.

## Audit log and platform support access

Every Function that changes access, money or billing writes
`orgs/{orgId}/auditLog`, with `actorKind` (`user`, `device`,
`platform_admin`, `billing`, `system`), the approving staff member for device
actions, and the reason where one was given. Anything a platform admin does is
written to the org's log, which the owner reads, and to `platformAuditLog`.

A platform admin has no standing access to any tenant. `grantSupportAccess`
opens read-only access to one org for 1 to 24 hours with a reason; the owner
or the admin can end it early with `revokeSupportAccess`. `setOrgStatus`
suspends or reactivates an org with a reason. Firestore can't log individual
reads, so the grant itself is what's audited.

The admin portal reads `platformOrgs/{orgId}`, a summary per tenant (name,
plan, status, billing state, location count, owner email) kept up to date by
Functions, so listing tenants needs no tenant access.

## Monitoring

See [monitoring.md](monitoring.md).
