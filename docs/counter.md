# Counter: card payments, printers and the cash drawer

How the POS takes cards on Stripe smart readers and prints to Epson
receipt printers. Payments in general (the `PaymentProvider` interface,
refunds, voids, recovery) are in [commercial.md](commercial.md#payments).

## Card payments (Stripe Terminal)

Server-driven Stripe Terminal: the tablet never talks to the reader.

1. The cashier taps **Card**, picks a tip (none, 10, 15 or 18% of the
   total) and, if the store has more than one, a reader.
2. The POS writes the order unpaid (waiting until the server has it), then
   calls `startCardPayment`. The Function creates a PaymentIntent for the
   total plus tip on the **restaurant's connected Stripe account** (the
   same `acct_…` its online orders are paid into, set only by the owner)
   and sends it to the counter's reader.
3. The guest taps, inserts or swipes. The POS polls `refreshPayment` every
   2 seconds until Stripe says approved or declined. The cashier can cancel
   while the reader waits.
4. Declined or the reader is offline: **Try again** (a new attempt, the same
   order) or close, which leaves the order unpaid in Orders, where staff can
   take cash, charge the card again or void it.

Cards and Interac debit are both accepted. The idempotency key is in the
PaymentIntent's metadata, so `recoverPendingPayments` finds a charge whose
answer was lost (a crashed Function, a closed tablet) even without Stripe's
payment ID. A reader that is offline or busy fails at once and the
PaymentIntent is cancelled, so it can't be charged later.

Code: `functions/src/payments/stripe_terminal.ts` (adapter, behind a narrow
`TerminalApi` so tests use `functions/test/fake_terminal.ts`), the POS's
`CardPaymentDialog` in `apps/pos/lib/src/counter_widgets.dart`.

**Refunds** go through `refundPayment` (a manager, or a manager's PIN on
the tablet, with a reason; audited) and Stripe's refund API on the
restaurant's account. **Interac refunds** have to be done with the guest's
card on the reader (Interac's rule), so they are refused with
`interac_needs_card` for now; refund those from the Stripe dashboard.

**Pairing a reader:** Manager app, store, **Counter**, **Add a card reader**.
On the reader: Settings, Generate pairing code; type the three words.
`registerCardReader` registers it on the restaurant's Stripe account, makes
the store's Stripe Terminal location the first time (from the street address
typed once), saves it in `settings/payments.terminals` and turns cards on at
the store.

## Printers (Epson)

Receipts and kitchen tickets are laid out once (`packages/shared/lib/src/printing/`)
and sent one of two ways, set per printer:

| Connection | How | Works on |
| --- | --- | --- |
| **Epson ePOS** (default) | ePOS-Print XML POSTed to `http://<printer>/cgi-bin/epos/service.cgi` | Android tablets and the browser. Any network TM printer with ePOS-Print: TM-m30II/III, TM-T88VI/VII, TM-T20III/IV (Ethernet/Wi-Fi models), TM-m50 |
| **Raw (port 9100)** | ESC/POS bytes over TCP | Android app only; any network ESC/POS printer |

A browser on an `https://` page can't call a plain `http://` printer; turn
on HTTPS for that printer (and trust its certificate on the tablet) or use
the Android app.

Printers live in `settings/hardware` (managers edit them in the manager
app's **Counter** tab):

- **Guest receipts:** store name, header lines (address, phone), order
  number, items with options and notes, subtotal, discount, each tax with its
  rate, total, tip, how it was paid, cash tendered and change, the GST/HST
  number and a bottom line. Printed after every sale, or offered as "Print
  receipt" (the store chooses). Reprints say COPY.
- **Kitchen tickets:** large ticket number and items, options, notes, the
  pickup time for online orders. A kitchen printer can be limited to some
  kitchen stations (`bar`, `kitchen`), so drinks print at the bar and food
  in the kitchen. Printed when the order is paid (cash) or approved (card).
- **Cash drawer:** plugged into a printer's drawer port and ticked on that
  printer. It opens on cash sales and cash refunds, through the printer
  (ESC p / ePOS `pulse`). There's no "no sale" button yet.

Printing never blocks a sale. A problem (out of paper, cover open, can't
reach the printer) shows in a banner on the POS with the printer's name.

Text is printed in code page 858, which covers French accents.

## Setting up a store (Maaz)

Stripe (test mode first):

1. Enable **Stripe Connect** and **Terminal** on the platform account. The
   restaurant's account must be connected (the owner pastes `acct_…` in the
   Online tab until Connect onboarding is built).
2. `STRIPE_SECRET_KEY` is the same secret billing uses. Without it the card
   Functions answer "Stripe isn't set up".
3. In test mode, pair a **simulated reader** with the code `simulated-wpe`
   to try the whole flow without hardware.
4. Order readers through the restaurant's Stripe dashboard (Terminal, Shop):
   Stripe Reader S700 or BBPOS WisePOS E, on the store Wi-Fi.

Epson:

1. Put the printer on the store network and give it a fixed IP (DHCP
   reservation). Hold the feed button while turning it on to print its
   network settings.
2. Open the printer's IP in a browser, and under ePOS-Print make sure it is
   enabled (it is by default on current TM-m30 and TM-T88 models).
3. Add it in the Counter tab, tick the cash drawer if one is plugged in, and
   ring up a test sale.

## Not done yet

- On-reader tipping and receipts by email or SMS (the tip is picked on the
  tablet today).
- Interac refunds on the reader.
- A card order goes to the kitchen display as soon as it's rung up, before the
  card is approved. A declined card leaves it there, unpaid, until staff void it.
- Online and delivery orders don't print a kitchen ticket by themselves yet;
  staff print one from Orders (or use the kitchen display).
- USB or Bluetooth printers, Epson TM-m30 Bluetooth pairing.
- "No sale" drawer opening and cash drawer sessions (counts, pay-ins and outs).
- Matching Stripe payouts against orders.
- Printer status (paper low) and a test-print button on the POS.
