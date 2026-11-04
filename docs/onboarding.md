# Onboarding flows

Roadmap step 2. Every step below is a callable Cloud Function in
`functions/src/handlers/`, deployed to `northamerica-northeast1`. Each one
re-reads the caller's membership from Firestore, ignores any role or tenant
claim in the request beyond using the IDs to look things up, and writes an
entry to `orgs/{orgId}/auditLog`. Tests: `npm run test:functions`.

## 1. A new restaurant

1. A platform admin calls `createOrganization` (name, type, owner email). This
   creates the org (`status: active`, `accessLevel: full`, `plan: trial`), a
   trialing subscription placeholder and an owner invite. The admin gets no
   membership in the org.
2. The owner opens the invite link and calls `acceptInvite` (below).
3. The owner calls `createLocation` (name, province, timezone). The location
   gets starting tax settings: HST in ON, NB, NL, NS and PE, GST elsewhere,
   with `reviewed: false` until someone confirms them. Provincial sales taxes
   are left for the owner to add. **These rates need accountant review.**
4. `setLocationStatus` closes or reopens a location (owner only).

Self-serve sign-up can reuse the same code once billing exists (step 3).

## 2. Staff

`inviteStaff` creates `orgs/{orgId}/invites/{inviteId}` and returns a one-time
token for the invite link (only its hash is stored). Sending the email is not
built yet; for now the manager app shows the link to share.

Who can give which role at a location they act in:

| Caller | Can invite, change to, or remove |
| --- | --- |
| Owner | any role, and other owners |
| Franchise owner | store manager, cashier, kitchen, inventory manager, accountant |
| Store manager | cashier, kitchen, inventory manager |

`acceptInvite` needs a signed-in account whose email matches the invite **and**
the token, so neither a forwarded link nor a guessed email is enough. It
merges the role into an existing membership (one role per location), mirrors
the person into `locations/{id}/staff`, and adds the org to `users/{uid}.orgIds`.

`setMemberRole` changes or removes a role at one location; the caller must be
able to give both the old and the new role, and nobody can change their own
access. Removing someone's last role removes them from the org. `setOwner`
grants or removes ownership (owners only). Removing access works even when
the org is read-only.

## 3. Devices

1. A manager calls `createPairingCode` for a location and device type (`pos`
   or `kds`). The code looks like `7KQM-3XWP`, lasts 15 minutes, works once,
   and is stored only as a SHA-256 hash.
2. The tablet, signed out, calls `redeemPairingCode`. The Function creates an
   auth account whose uid is the device ID, a membership with the `device`
   role at that one location, and `locations/{id}/devices/{deviceId}`, and
   returns a custom token. The tablet signs in with it and stays signed in,
   so it keeps working offline.
3. `revokeDevice` suspends the membership, marks the device revoked, disables
   the account and revokes its refresh tokens.

## 4. Staff PIN on a device

- Each person sets their own PIN with `setStaffPin` (4 to 8 digits, no
  `1111` or `1234`). PINs are unique within an org, so the PIN alone says who
  is at the till. They are stored as an HMAC keyed by the `PIN_PEPPER` secret,
  which has to be set in each Firebase project before deploying
  (`firebase functions:secrets:set PIN_PEPPER`).
- The device calls `startStaffSession` with a PIN and gets back the person and
  their role at its location. Five wrong PINs lock that device's PIN pad for
  five minutes.
- Writes made from the device are signed in as the device; the app records
  the staff uid on orders for reporting.
- Switching staff needs a connection for now. Offline switching would mean
  caching PIN verifiers on the tablet, which is a separate decision.
- Voids and refunds (step 3) will use the same lookup, `resolveStaffPin`, to
  check a manager's PIN server-side.
