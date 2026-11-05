# Permissions

The source of truth is [`tests/rules/src/matrix.ts`](../tests/rules/src/matrix.ts):
every operation there is run by every role at the target store, by the same
roles at another store, by another org, by a platform admin without a grant
and by a signed-out caller. CI fails if `firestore.rules` disagrees with it.

Hand-written cases for the acceptance criteria (cross-tenant reads, privilege
escalation, suspended and read-only states, platform support grants, query
shapes) are in [`tests/rules/src/named.test.ts`](../tests/rules/src/named.test.ts).

## Principles

- Owners act on every location in their org; every other role only where they hold it.
- Anything that changes who can do what is a Cloud Function with an audit entry,
  never a direct client write: memberships, devices, voids and refunds, card
  payments, closed cash-session adjustments, locations, billing, support grants.
- Discounts need no manager PIN.
- Billing problems never lock members out of reading their own data.
- Platform admins have no standing access; a time-boxed support grant gives
  read-only access to one org. They read `platformOrgs`, `platformAuditLog`,
  `platformHealth` and `platformIncidents`, and set plans, trials and org
  status through audited Functions (docs/commercial.md).
- Refunds and voids need a manager, or a manager's PIN typed on a device.

## Summary

Yes = rules allow. Fn = Cloud Function only. R = read only. Own = own records.

| Operation | Owner | Franchise owner | Manager | Cashier | Kitchen | Inventory | Accountant | Device |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Brand, franchise menu, promotions | Yes | R | R | R | R | R | R | R |
| Subscription status | R | R | | | | | R | |
| Location settings, price overrides | Yes | Yes | Yes | R | R | R | R | R |
| Mark sold out | Yes | Yes | Yes | Yes | Yes | | | Yes |
| Staff list | Yes | Yes | Yes | | | | | |
| Create orders, cash payments, discounts | Yes | Yes | Yes | Yes | | | | Yes |
| Read orders | Yes | Yes | Yes | Yes | Yes | | R | Yes |
| Prep status | Yes | Yes | Yes | Yes | Yes | | | Yes |
| Void, refund, card payment | Fn | Fn | Fn | Fn | | | | Fn |
| Cash sessions | Yes | Yes | Yes | Own | | | R | Open ones |
| Inventory, stock, purchase orders | Yes | Yes | Yes | | R | Yes | R | |
| Reports | Yes | Yes | Yes | | | Inventory | R | |
| Refunds (read) | Yes | Yes | Yes | Yes | | | R | Yes |
| Audit log | R | R (own stores) | | | | | | |
| Billing: Checkout, portal | Fn | | | | | | | |
| Memberships, devices, locations | Fn | Fn | Fn | | | | | |
| Online ordering settings (web address, payment options) | Fn | Fn | Fn | R | R | R | R | R |
| Pause or resume online orders | Fn | Fn | Fn | Fn | Fn | | | Fn |
| Stripe account for online payments | Fn | | | | | | | |
| Link delivery stores | Fn | | | | | | | |
| Push menu to delivery apps | Fn | Fn | Fn | | | | | |
| Take payment at pickup for online orders | Yes | Yes | Yes | Yes | | | | Yes |

Online and delivery orders are written by Functions with the server's (or
the marketplace's) prices; staff can move their status and record payment
at pickup, but not change items, prices or the guest's details. Guests on
the ordering site don't sign in and never touch Firestore directly.
