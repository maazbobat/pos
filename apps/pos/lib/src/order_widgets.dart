import 'package:flutter/material.dart';
import 'package:pos_shared/pos_shared.dart';

import 'app.dart';
import 'device_shell.dart';

/// Pick an item's options (size, toppings), quantity and a note.
class ItemOptionsDialog extends StatefulWidget {
  const ItemOptionsDialog({
    super.key,
    required this.entry,
    required this.lineId,
  });
  final LocationMenuItem entry;
  final String lineId;

  @override
  State<ItemOptionsDialog> createState() => _ItemOptionsDialogState();
}

class _ItemOptionsDialogState extends State<ItemOptionsDialog> {
  final Map<String, List<String>> _picks = {};
  final _notes = TextEditingController();
  var _qty = 1;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Single-choice required groups start on their first option.
    for (final g in widget.entry.modifierGroups) {
      _picks[g.id] = g.minSelect == 1 && g.maxSelect == 1
          ? [g.options.first.id]
          : [];
    }
  }

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  void _toggle(ModifierGroup g, String optionId) {
    setState(() {
      _error = null;
      final picks = _picks[g.id]!;
      if (g.maxSelect == 1) {
        _picks[g.id] = [optionId];
      } else if (picks.contains(optionId)) {
        picks.remove(optionId);
      } else if (picks.length < g.maxSelect) {
        picks.add(optionId);
      }
    });
  }

  OrderLine? _line() {
    try {
      return OrderLine.fromMenu(
        lineId: widget.lineId,
        entry: widget.entry,
        selections: _picks,
        qty: _qty,
        notes: _notes.text,
      );
    } on MenuValidationError {
      return null;
    }
  }

  void _add() {
    try {
      Navigator.of(context).pop(
        OrderLine.fromMenu(
          lineId: widget.lineId,
          entry: widget.entry,
          selections: _picks,
          qty: _qty,
          notes: _notes.text,
        ),
      );
    } on MenuValidationError catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final line = _line();
    return AlertDialog(
      title: Text(widget.entry.item.name),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final g in widget.entry.modifierGroups) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 6),
                  child: Text(
                    g.required
                        ? '${g.name} (pick ${g.minSelect == g.maxSelect ? g.minSelect : '${g.minSelect}-${g.maxSelect}'})'
                        : '${g.name} (up to ${g.maxSelect})',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final o in g.options)
                      FilterChip(
                        key: Key('option-${g.id}-${o.id}'),
                        label: Text(
                          o.priceDeltaCents > 0
                              ? '${o.name} +${formatCad(o.priceDeltaCents)}'
                              : o.name,
                        ),
                        selected: _picks[g.id]!.contains(o.id),
                        onSelected: (_) => _toggle(g, o.id),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              TextField(
                key: const Key('line-notes'),
                controller: _notes,
                maxLength: 140,
                decoration: const InputDecoration(
                  labelText: 'Note for the kitchen',
                  hintText: 'Less ice, no onions…',
                ),
              ),
              Row(
                children: [
                  IconButton(
                    onPressed: _qty > 1 ? () => setState(() => _qty--) : null,
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                  Text('$_qty', style: theme.textTheme.titleLarge),
                  IconButton(
                    onPressed: _qty < maxLineQty
                        ? () => setState(() => _qty++)
                        : null,
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                ],
              ),
              if (_error != null)
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('add-to-order'),
          onPressed: _add,
          child: Text(
            line == null ? 'Add' : 'Add ${formatCad(line.lineTotalCents)}',
          ),
        ),
      ],
    );
  }
}

/// The order being rung up: lines, discount, here or to go, totals, pay.
class CartPanel extends StatelessWidget {
  const CartPanel({
    super.key,
    required this.cart,
    required this.onChanged,
    required this.onPayCash,
    this.onPayCard,
  });
  final Cart cart;
  final ValueChanged<Cart> onChanged;
  final VoidCallback onPayCash;

  /// Null when this location has no card reader set up.
  final VoidCallback? onPayCard;

  Future<void> _discount(BuildContext context) async {
    final result = await showDialog<Discount?>(
      context: context,
      builder: (_) => DiscountDialog(current: cart.discounts.firstOrNull),
    );
    if (result != null) {
      onChanged(cart.withDiscount(result.value == 0 ? null : result));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final totals = cart.totals;
    return Material(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: SegmentedButton<Fulfillment>(
              segments: const [
                ButtonSegment(value: Fulfillment.here, label: Text('For here')),
                ButtonSegment(value: Fulfillment.takeout, label: Text('To go')),
              ],
              selected: {cart.fulfillment},
              onSelectionChanged: (s) =>
                  onChanged(cart.withFulfillment(s.single)),
            ),
          ),
          Expanded(
            child: cart.isEmpty
                ? const Center(child: Text('Tap an item to start an order.'))
                : ListView(
                    children: [
                      for (final line in cart.lines)
                        ListTile(
                          key: Key('line-${line.lineId}'),
                          dense: true,
                          title: Text('${line.qty} × ${line.name}'),
                          subtitle: line.modifiers.isEmpty && line.notes == null
                              ? null
                              : Text(
                                  [
                                    ...line.modifiers.map((m) => m.name),
                                    ?line.notes,
                                  ].join(', '),
                                ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(formatCad(line.lineTotalCents)),
                              IconButton(
                                tooltip: 'One less',
                                onPressed: () => onChanged(
                                  cart.setQty(line.lineId, line.qty - 1),
                                ),
                                icon: const Icon(Icons.remove_circle_outline),
                              ),
                              IconButton(
                                tooltip: 'One more',
                                onPressed: () => onChanged(
                                  cart.setQty(line.lineId, line.qty + 1),
                                ),
                                icon: const Icon(Icons.add_circle_outline),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _TotalRow('Subtotal', totals.subtotalCents),
                if (totals.discountCents > 0)
                  _TotalRow('Discount', -totals.discountCents),
                for (final t in totals.taxes) _TotalRow(t.name, t.cents),
                _TotalRow(
                  'Total',
                  totals.totalCents,
                  style: theme.textTheme.titleLarge,
                  valueKey: const Key('order-total'),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    OutlinedButton.icon(
                      key: const Key('discount'),
                      onPressed: cart.isEmpty ? null : () => _discount(context),
                      icon: const Icon(Icons.percent),
                      label: const Text('Discount'),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: cart.isEmpty
                          ? null
                          : () => onChanged(cart.clear()),
                      child: const Text('Clear'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        key: const Key('pay-cash'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(56),
                        ),
                        onPressed: cart.isEmpty ? null : onPayCash,
                        icon: const Icon(Icons.payments_outlined),
                        label: Text('Cash ${formatCad(totals.totalCents)}'),
                      ),
                    ),
                    if (onPayCard != null) ...[
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.icon(
                          key: const Key('pay-card'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(56),
                          ),
                          onPressed: cart.isEmpty ? null : onPayCard,
                          icon: const Icon(Icons.credit_card),
                          label: const Text('Card'),
                        ),
                      ),
                    ],
                  ],
                ),
                if (onPayCard == null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'To take cards, a manager adds a card reader in the manager app.',
                    style: theme.textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TotalRow extends StatelessWidget {
  const _TotalRow(this.label, this.cents, {this.style, this.valueKey});
  final String label;
  final int cents;
  final TextStyle? style;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label, style: style)),
        Text(formatCad(cents), key: valueKey, style: style),
      ],
    );
  }
}

/// The order summary at the bottom of a narrow screen.
class CartBar extends StatelessWidget {
  const CartBar({super.key, required this.cart, required this.onOpen});
  final Cart cart;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: FilledButton(
          key: const Key('open-cart'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: onOpen,
          child: Text(
            cart.isEmpty
                ? 'Order is empty'
                : 'Order: ${cart.itemCount} item${cart.itemCount == 1 ? '' : 's'} · ${formatCad(cart.totals.totalCents)}',
          ),
        ),
      ),
    );
  }
}

/// Percent or dollar amount off, with a reason. Any seller can apply one:
/// discounts never need a manager's PIN.
class DiscountDialog extends StatefulWidget {
  const DiscountDialog({super.key, this.current});
  final Discount? current;

  @override
  State<DiscountDialog> createState() => _DiscountDialogState();
}

class _DiscountDialogState extends State<DiscountDialog> {
  late var _type = widget.current?.type ?? DiscountType.percent;
  late final _value = TextEditingController(
    text: widget.current == null
        ? ''
        : widget.current!.type == DiscountType.percent
        ? '${widget.current!.value}'
        : formatCad(widget.current!.value).substring(1),
  );
  late final _reason = TextEditingController(text: widget.current?.reason);
  String? _error;

  @override
  void dispose() {
    _value.dispose();
    _reason.dispose();
    super.dispose();
  }

  void _apply() {
    final text = _value.text.trim();
    int? value;
    if (_type == DiscountType.percent) {
      value = int.tryParse(text);
      if (value == null || value < 0 || value > 100) {
        setState(() => _error = 'Enter a percent from 0 to 100.');
        return;
      }
    } else {
      value = parseCad(text);
      if (value == null) {
        setState(() => _error = 'Enter an amount like 2.50.');
        return;
      }
    }
    final reason = _reason.text.trim();
    Navigator.of(context).pop(
      Discount(
        type: _type,
        value: value,
        reason: reason.isEmpty ? null : reason,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Discount'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SegmentedButton<DiscountType>(
              segments: const [
                ButtonSegment(value: DiscountType.percent, label: Text('%')),
                ButtonSegment(value: DiscountType.amount, label: Text(r'$')),
              ],
              selected: {_type},
              onSelectionChanged: (s) => setState(() => _type = s.single),
            ),
            TextField(
              key: const Key('discount-value'),
              controller: _value,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: _type == DiscountType.percent
                    ? 'Percent off'
                    : 'Amount off',
                errorText: _error,
              ),
            ),
            TextField(
              key: const Key('discount-reason'),
              controller: _reason,
              maxLength: 60,
              decoration: const InputDecoration(labelText: 'Reason'),
            ),
          ],
        ),
      ),
      actions: [
        if (widget.current != null)
          TextButton(
            onPressed: () =>
                Navigator.of(context)
                    .pop(const Discount(type: DiscountType.amount, value: 0)),
            child: const Text('Remove'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('apply-discount'),
          onPressed: _apply,
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

/// How much cash the guest handed over. Returns the amount tendered.
class CashDialog extends StatefulWidget {
  const CashDialog({super.key, required this.totalCents});
  final int totalCents;

  @override
  State<CashDialog> createState() => _CashDialogState();
}

class _CashDialogState extends State<CashDialog> {
  final _other = TextEditingController();
  int? _tendered;

  @override
  void dispose() {
    _other.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tendered = _tendered;
    final change = tendered == null
        ? null
        : changeDue(widget.totalCents, tendered);
    return AlertDialog(
      title: Text('Cash: ${formatCad(widget.totalCents)}'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final amount in quickCashAmounts(widget.totalCents))
                  ChoiceChip(
                    key: Key('cash-$amount'),
                    label: Text(
                      amount == widget.totalCents ? 'Exact' : formatCad(amount),
                    ),
                    selected: tendered == amount,
                    onSelected: (_) => setState(() {
                      _tendered = amount;
                      _other.clear();
                    }),
                  ),
              ],
            ),
            TextField(
              key: const Key('cash-other'),
              controller: _other,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: 'Other amount'),
              onChanged: (v) => setState(() => _tendered = parseCad(v)),
            ),
            const SizedBox(height: 16),
            if (tendered != null)
              Text(
                change == null
                    ? 'Not enough: ${formatCad(widget.totalCents - tendered)} short.'
                    : 'Change: ${formatCad(change)}',
                key: const Key('cash-change'),
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: change == null ? theme.colorScheme.error : null,
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('cash-done'),
          onPressed: change == null
              ? null
              : () => Navigator.of(context).pop(tendered),
          child: const Text('Paid'),
        ),
      ],
    );
  }
}

/// Pause or resume online orders from the counter, for a rush. Hidden
/// until a manager turns online ordering on.
class OnlinePauseButton extends StatelessWidget {
  const OnlinePauseButton({super.key, required this.device});
  final DeviceContext device;

  @override
  Widget build(BuildContext context) {
    final orders = BackendScope.of(context).orders;
    return StreamBuilder<OnlineOrderingSettings?>(
      stream: orders.onlineOrdering(device.orgId, device.locationId),
      builder: (context, snap) {
        final s = snap.data;
        if (s == null || !s.enabled) return const SizedBox.shrink();
        return TextButton.icon(
          key: const Key('online-pause'),
          onPressed: () async {
            final messenger = ScaffoldMessenger.of(context);
            try {
              await orders.updateOnlineOrdering(
                device.orgId,
                device.locationId,
                paused: !s.paused,
              );
              messenger.showSnackBar(
                SnackBar(
                  content: Text(
                    s.paused
                        ? 'Online orders are back on.'
                        : 'Online orders paused.',
                  ),
                ),
              );
            } catch (e) {
              messenger.showSnackBar(SnackBar(content: Text(errorText(e))));
            }
          },
          icon: Icon(
            s.paused ? Icons.play_circle_outline : Icons.pause_circle_outline,
          ),
          label: Text(s.paused ? 'Resume online' : 'Pause online'),
        );
      },
    );
  }
}

String sourceLabel(Order order) => switch (order.source) {
  OrderSource.pos => 'Counter',
  OrderSource.online => 'Online',
  OrderSource.delivery => switch (order.channel) {
    'uber_eats' => 'Uber Eats',
    'doordash' => 'DoorDash',
    'skip' => 'SkipTheDishes',
    _ => 'Delivery',
  },
};

String statusLabel(OrderStatus status) => switch (status) {
  OrderStatus.awaitingPayment => 'Waiting for payment',
  OrderStatus.newOrder => 'New',
  OrderStatus.inProgress => 'Making',
  OrderStatus.ready => 'Ready',
  OrderStatus.completed => 'Picked up',
  OrderStatus.canceled => 'Canceled',
  OrderStatus.voided => 'Voided',
};
