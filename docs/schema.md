# Tenant schema

Tenancy is decided by the document path, never by fields a client sends.

```
platformAdmins/{uid}                 platform admins (Functions write only)
platformOrgs/{orgId}                 tenant summary for the admin portal (platform admins read)
platformAuditLog/{eventId}           every platform admin action (platform admins read)
platformHealth/summary               monitoring sweep (platform admins read)
platformIncidents/{id}               problems to look at (platform admins read)
stripeCustomers/{customerId}         Stripe customer to org link (Functions only)
stripeEvents/{eventId}               processed Stripe webhook events (Functions only)
pairingCodes/{code}                  device pairing codes (Functions only)
users/{uid}                          profile; orgIds[] maintained by Functions

orgs/{orgId}                         name, type, status, accessLevel, plan
  billing/subscription               plan, billing state, derived access (Functions only, docs/commercial.md)
  members/{uid}                      orgRole, locationRoles {locationId: role}, roles[], kind, status
  invites/{inviteId}                 pending staff invites; token stored as a hash (Functions only)
  pinIndex/{hmac}                    staff PIN lookup, HMAC of the PIN (Functions only, unreadable)
  memberSecrets/{uid}                a member's current PIN key (Functions only, unreadable)
  supportGrants/{adminUid}           time-boxed platform support access (Functions only)
  auditLog/{eventId}                 append-only (Functions only)
  config/{brand | loyalty | receipt}
  menuCategories/ menuItems/ modifierGroups/ combos/ promotions/
  reports/{reportId}                 cross-location rollups (Functions only)

  locations/{locationId}             name, status, timezone, province
    settings/{hours | tax | hardware | kitchenRouting | payments}
    menuOverrides/{itemId}           available, price
    staff/{uid}                      staff list mirrored from memberships (Functions only)
    devices/{deviceId}               type, status, appVersion, lastSeenAt, printer health
      private/pinGuard               wrong-PIN counter and lockout (Functions only)
    orders/{orderId}
      payments/{paymentId}           cents, no card data; clients record cash only
      refunds/{refundId}             written by refundPayment (Functions only)
    cashSessions/{sessionId}
      movements/{movementId}
    inventoryItems/ stockMovements/ purchaseOrders/
    reports/{reportId}               location rollups (Functions only)
```

Every document under an org stores `orgId`, and every document under a
location also stores `locationId`. Both must equal the path on create and can
never change.

## State fields

| Field | Values | Effect |
| --- | --- | --- |
| `orgs/{orgId}.status` | `active`, `suspended` | Suspended: only the owner can read; nobody writes |
| `orgs/{orgId}.accessLevel` | `full`, `read_only` | Read-only (billing lapsed): everyone reads, nobody writes |
| `locations/{id}.status` | `active`, `closed` | Closed: only the owner can read; nobody writes |
| `members/{uid}.status` | `active`, `suspended` | Suspended member or revoked device: no access |

## Membership

```js
orgs/org-a/members/uid_123 = {
  uid: "uid_123", orgId: "org-a", kind: "user", status: "active",
  orgRole: null,                       // "owner" = every location
  locationRoles: { cambridge: "store_manager", toronto: "cashier" },
  roles: ["store_manager", "cashier"]  // distinct roles, for org-wide checks
}
```

One role per location. Devices are members with `kind: "device"` and the
`device` role at one location; staff switch on a device with a PIN, and
elevated actions go through Functions that check a manager PIN server-side.

## Menu

Owners edit the org menu directly (the rules check each document's shape);
locations override availability and price. Money is always whole cents
(`int`), never a float. `pos_shared` has the models, their `validate()`
checks, and `buildLocationMenu`, which merges the org menu with one store's
overrides for the POS.

| Document | Fields |
| --- | --- |
| `menuCategories/{id}` | `name` (1-60), `sortOrder` int, `active` |
| `menuItems/{id}` | `name` (1-100), `description?`, `categoryId`, `priceCents`, `modifierGroupIds[]` (max 20), `taxable`, `kitchenStation?`, `active`, `sortOrder`, `imagePath?` |
| `modifierGroups/{id}` | `name`, `minSelect`, `maxSelect` (min ≤ max ≤ options), `options[]` of `{id, name, priceDeltaCents}` (1-50) |
| `locations/{id}/menuOverrides/{itemId}` | `available`, `priceCents` (null = org price) |

Front-of-house roles can only flip `available` on an override (sold out).
Rules can't look inside list entries, so option prices and IDs are checked by
the apps through the models. Combos and promotions keep their milestone-1
rules until they get their own design.
