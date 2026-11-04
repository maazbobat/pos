# Tenant schema

Tenancy is decided by the document path, never by fields a client sends.

```
platformAdmins/{uid}                 platform admins (Functions write only)
pairingCodes/{code}                  device pairing codes (Functions only)
users/{uid}                          profile; orgIds[] maintained by Functions

orgs/{orgId}                         name, type, status, accessLevel, plan
  billing/subscription               Stripe state (webhook Function only)
  members/{uid}                      orgRole, locationRoles {locationId: role}, roles[], kind, status
  invites/{inviteId}                 pending staff invites; token stored as a hash (Functions only)
  pinIndex/{hmac}                    staff PIN lookup, HMAC of the PIN (Functions only, unreadable)
  memberSecrets/{uid}                a member's current PIN key (Functions only, unreadable)
  supportGrants/{adminUid}           time-boxed platform support access (Functions only)
  auditLog/{eventId}                 append-only (Functions only)
  config/{brand | loyalty | receipt}
  menuItems/ modifierGroups/ combos/ promotions/
  reports/{reportId}                 cross-location rollups (Functions only)

  locations/{locationId}             name, status, timezone, province
    settings/{hours | tax | hardware | kitchenRouting}
    menuOverrides/{itemId}           available, price
    staff/{uid}                      staff list mirrored from memberships (Functions only)
    devices/{deviceId}               type, status, appVersion, lastSeenAt, printer health
      private/pinGuard               wrong-PIN counter and lockout (Functions only)
    orders/{orderId}
      payments/{paymentId}           no card data; clients record cash only
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
