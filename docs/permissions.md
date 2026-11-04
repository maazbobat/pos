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
  read-only access to one org.

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
| Audit log | R | R (own stores) | | | | | | |
| Memberships, devices, locations | Fn | Fn | Fn | | | | | |
