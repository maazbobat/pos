import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:pos_shared/pos_shared.dart';

import 'app.dart';

/// A random key for one payment attempt. Retrying the same attempt reuses
/// it, so a dropped connection can't charge the guest twice.
String newAttemptKey() {
  final r = Random.secure();
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  return 'pos-${List.generate(20, (_) => chars[r.nextInt(chars.length)]).join()}';
}

/// Tip choices, in percent of the total.
const tipPercents = [10, 15, 18];

int tipFor(int totalCents, int percent) => (totalCents * percent + 50) ~/ 100;

/// Shows print problems in a banner that stays until dismissed, so it
/// doesn't hide the sale's confirmation (and the change due) or get lost.
void showPrintErrors(
  ScaffoldMessengerState messenger,
  List<PrintException> errors,
) {
  if (errors.isEmpty) return;
  messenger
    ..clearMaterialBanners()
    ..showMaterialBanner(
      MaterialBanner(
        key: const Key('print-error'),
        leading: const Icon(Icons.print_disabled_outlined),
        content: Text(errors.map((e) => e.toString()).join('\n')),
        actions: [
          TextButton(
            onPressed: messenger.hideCurrentMaterialBanner,
            child: const Text('Dismiss'),
          ),
        ],
      ),
    );
}

/// Prints the guest receipt (and opens the drawer for cash).
Future<void> printReceipt(
  BuildContext context, {
  required Order order,
  required HardwareSettings hardware,
  required List<ReceiptPayment> payments,
  bool openDrawer = false,
  bool reprint = false,
}) async {
  final printing = BackendScope.printingOf(context);
  final messenger = ScaffoldMessenger.of(context);
  final storeName = await _storeName(context, order);
  final errors = await printing.receipt(
    hardware,
    order: order,
    storeName: storeName,
    payments: payments,
    openDrawer: openDrawer,
    reprint: reprint,
  );
  showPrintErrors(messenger, errors);
}

Future<void> printKitchen(
  BuildContext context, {
  required Order order,
  required HardwareSettings hardware,
  bool reprint = false,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final errors = await BackendScope.printingOf(context)
      .kitchen(hardware, order, reprint: reprint);
  showPrintErrors(messenger, errors);
}

Future<String> _storeName(BuildContext context, Order order) async {
  final data = BackendScope.of(context).data;
  try {
    final loc = await data
        .location(order.orgId, order.locationId)
        .first
        .timeout(const Duration(seconds: 2));
    return loc?.name ?? '';
  } catch (_) {
    return '';
  }
}

/// The card payment, from picking a tip to "Approved". Returns the
/// succeeded payment, or null if the cashier gave up. [ensureOrder] writes
/// the order the first time it's needed and returns it.
class CardPaymentDialog extends StatefulWidget {
  const CardPaymentDialog({
    super.key,
    required this.totalCents,
    required this.readers,
    required this.ensureOrder,
  });
  final int totalCents;
  final List<CardReader> readers;
  final Future<Order> Function() ensureOrder;

  @override
  State<CardPaymentDialog> createState() => _CardPaymentDialogState();
}

class CardPaymentDone {
  const CardPaymentDone(this.order, this.payment);
  final Order order;
  final OrderPayment payment;
}

class _CardPaymentDialogState extends State<CardPaymentDialog> {
  int _tipPercent = 0;
  late CardReader _reader = widget.readers.first;
  String _key = newAttemptKey();
  Order? _order;
  CardPaymentState? _state;
  String? _error;
  bool _busy = false;
  Timer? _poll;

  static const pollEvery = Duration(seconds: 2);

  int get _tipCents => tipFor(widget.totalCents, _tipPercent);

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _charge() async {
    final counter = BackendScope.of(context).counter;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final order = _order ??= await widget.ensureOrder();
      final state = await counter.startCardPayment(
        order,
        amountCents: widget.totalCents,
        tipCents: _tipCents,
        idempotencyKey: _key,
        readerId: _reader.id,
      );
      if (!mounted) return;
      _update(state);
      if (!state.status.done) {
        _poll = Timer.periodic(pollEvery, (_) => _refresh());
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    final order = _order;
    final state = _state;
    if (order == null || state == null || state.status.done) return;
    try {
      final next = await BackendScope.of(context).counter
          .refreshPayment(order, state.paymentId);
      if (mounted) _update(next);
    } catch (_) {
      // A missed poll is fine; the next one or the server's recovery job catches up.
    }
  }

  void _update(CardPaymentState state) {
    setState(() => _state = state);
    if (!state.status.done) return;
    _poll?.cancel();
    if (state.status == CardPaymentStatus.succeeded) {
      Navigator.of(context).pop(
        CardPaymentDone(
          _order!,
          OrderPayment(
            id: state.paymentId,
            method: 'card',
            provider: 'stripe_terminal',
            amountCents: widget.totalCents,
            tipCents: _tipCents,
            status: state.status,
          ),
        ),
      );
    }
  }

  Future<void> _cancel() async {
    final order = _order;
    final state = _state;
    if (order == null || state == null) return;
    setState(() => _busy = true);
    try {
      _update(
        await BackendScope.of(context).counter
            .cancelCardPayment(order, state.paymentId),
      );
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _retry() => setState(() {
    _key = newAttemptKey();
    _state = null;
    _error = null;
  });

  @override
  Widget build(BuildContext context) {
    final state = _state;
    final waiting = state != null && !state.status.done;
    final failed =
        state != null &&
        state.status.done &&
        state.status != CardPaymentStatus.succeeded;
    final total = widget.totalCents + _tipCents;

    final Widget body;
    final List<Widget> actions;
    if (waiting) {
      body = Column(
        key: const Key('card-waiting'),
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            'Ask the guest to tap, insert or swipe on ${_reader.name}.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            formatCad(total),
            style: Theme.of(context).textTheme.headlineMedium,
          ),
        ],
      );
      actions = [
        TextButton(
          key: const Key('card-cancel'),
          onPressed: _busy ? null : _cancel,
          child: const Text('Cancel payment'),
        ),
      ];
    } else if (failed) {
      body = Text(state.message, key: const Key('card-failed'));
      actions = [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(_order == null ? 'Close' : 'Close (order stays unpaid)'),
        ),
        FilledButton(
          key: const Key('card-retry'),
          onPressed: _retry,
          child: const Text('Try again'),
        ),
      ];
    } else {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Tip', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                key: const Key('tip-0'),
                label: const Text('No tip'),
                selected: _tipPercent == 0,
                onSelected: (_) => setState(() => _tipPercent = 0),
              ),
              for (final p in tipPercents)
                ChoiceChip(
                  key: Key('tip-$p'),
                  label: Text(
                    '$p% · ${formatCad(tipFor(widget.totalCents, p))}',
                  ),
                  selected: _tipPercent == p,
                  onSelected: (_) => setState(() => _tipPercent = p),
                ),
            ],
          ),
          if (widget.readers.length > 1) ...[
            const SizedBox(height: 16),
            DropdownButtonFormField<CardReader>(
              key: const Key('card-reader'),
              initialValue: _reader,
              decoration: const InputDecoration(labelText: 'Card reader'),
              items: [
                for (final r in widget.readers)
                  DropdownMenuItem(value: r, child: Text(r.name)),
              ],
              onChanged: (r) => setState(() => _reader = r ?? _reader),
            ),
          ],
          if (_error case final e?) ...[
            const SizedBox(height: 12),
            Text(
              e,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      );
      actions = [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Back'),
        ),
        FilledButton(
          key: const Key('card-charge'),
          onPressed: _busy ? null : _charge,
          child: Text('Charge ${formatCad(total)}'),
        ),
      ];
    }
    return PopScope(
      // Don't lose track of a charge the guest may still be paying.
      canPop: !waiting,
      child: AlertDialog(
        title: Text('Card: ${formatCad(widget.totalCents)}'),
        content: SizedBox(width: 400, child: body),
        actions: actions,
      ),
    );
  }
}

/// A manager's approval on the tablet: their PIN and a reason.
class ManagerApproval {
  const ManagerApproval({
    required this.pin,
    required this.reason,
    this.amountCents,
  });
  final String pin;
  final String reason;
  final int? amountCents;
}

/// Asks for a reason, a manager's PIN, and for refunds the amount.
class ManagerApprovalDialog extends StatefulWidget {
  const ManagerApprovalDialog({
    super.key,
    required this.title,
    required this.action,
    this.maxRefundCents,
  });
  final String title;
  final String action;

  /// Set for a refund: the most that can go back. The amount starts there.
  final int? maxRefundCents;

  @override
  State<ManagerApprovalDialog> createState() => _ManagerApprovalDialogState();
}

class _ManagerApprovalDialogState extends State<ManagerApprovalDialog> {
  final _reason = TextEditingController();
  final _pin = TextEditingController();
  late final _amount = TextEditingController(
    text: widget.maxRefundCents == null
        ? ''
        : formatCad(widget.maxRefundCents!).substring(1),
  );
  String? _error;

  @override
  void dispose() {
    _reason.dispose();
    _pin.dispose();
    _amount.dispose();
    super.dispose();
  }

  void _submit() {
    final reason = _reason.text.trim();
    final pin = _pin.text.trim();
    int? amount;
    if (widget.maxRefundCents case final max?) {
      amount = parseCad(_amount.text);
      if (amount == null || amount < 1 || amount > max) {
        setState(() => _error = 'Enter an amount up to ${formatCad(max)}.');
        return;
      }
    }
    if (reason.length < 3) {
      setState(() => _error = 'Give a reason.');
      return;
    }
    if (!RegExp(r'^\d{4,8}$').hasMatch(pin)) {
      setState(() => _error = 'A manager types their PIN.');
      return;
    }
    Navigator.of(context)
        .pop(ManagerApproval(pin: pin, reason: reason, amountCents: amount));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.maxRefundCents != null)
              TextField(
                key: const Key('approval-amount'),
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: 'Amount',
                  prefixText: r'$',
                  helperText: 'Up to ${formatCad(widget.maxRefundCents!)}',
                ),
              ),
            TextField(
              key: const Key('approval-reason'),
              controller: _reason,
              decoration: const InputDecoration(labelText: 'Reason'),
            ),
            TextField(
              key: const Key('approval-pin'),
              controller: _pin,
              obscureText: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Manager PIN'),
              onSubmitted: (_) => _submit(),
            ),
            if (_error case final e?)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  e,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Back'),
        ),
        FilledButton(
          key: const Key('approval-submit'),
          onPressed: _submit,
          child: Text(widget.action),
        ),
      ],
    );
  }
}
