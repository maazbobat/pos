# Monitoring

## In the admin portal

`healthSweep` runs every 15 minutes and writes `platformHealth/summary`:

| Field | Meaning |
| --- | --- |
| `staleDevices`, `staleDevicesByOrg` | Active devices that haven't checked in for 15 minutes |
| `printerProblems` | Active devices reporting `printerStatus` of `offline`, `paper_out` or `error` |
| `stuckPayments` | Card payments still pending after 30 minutes |
| `openIncidents` | Unresolved `platformIncidents` |

`platformIncidents/{id}` records things a person should look at: Stripe
events that couldn't be matched to an org or failed to apply, and stuck card
payments. A platform admin resolves one with `resolveIncident` and a note,
which is audited.

Devices report their own `appVersion`, `lastSeenAt`, `printerStatus` and
`health` (allowed by the rules). The POS doesn't send the heartbeat yet;
that comes with the checkout screens.

## Paging (Cloud Monitoring, per Firebase project)

Every incident is also logged at error level with an `incident` field, so
alerts don't depend on anyone watching the portal. Before the first real
deploy, create these alert policies in each project:

1. **Incidents:** log-based alert on `severity>=ERROR AND jsonPayload.incident:*`.
2. **Function errors:** error rate above 5% over 10 minutes on any function,
   and any 5xx from `stripeWebhook`.
3. **Scheduled jobs:** alert if `enforceBillingAccess`, `recoverPendingPayments`
   or `healthSweep` hasn't run successfully in 2 hours.
4. **Firestore:** alert on a sudden rise in rules denials, which is what a
   broken client release or an attack looks like.

Backups and restore tests are separate (roadmap: environments).
