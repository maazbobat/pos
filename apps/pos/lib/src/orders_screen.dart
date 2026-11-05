import 'package:flutter/material.dart';
import 'package:pos_shared/pos_shared.dart';

import 'app.dart';
import 'counter_widgets.dart';
import 'device_shell.dart';
import 'order_widgets.dart';

/// Recent orders at this store, counter, online and delivery together.
/// Staff hand orders over here, take payment for orders not paid yet,
/// reprint receipts and kitchen tickets, and (with a manager's PIN) refund
/// or void.
class OrdersScreen extends StatelessWidget {
  const OrdersScreen({super.key, required this.device, required this.staff});
  final DeviceContext device;
  final StaffSession staff;

  @override
  Widget build(BuildContext context) {
    final backend = BackendScope.of(context);
    final orders = backend.orders;
    return StreamBuilder<PaymentSettings>(
      stream: backend.counter.paymentSettings(device.orgId, device.locationId),
      builder: (context, paySnap) => StreamBuilder<HardwareSettings>(
        stream: backend.counter.hardware(device.orgId, device.locationId),
        builder: (context, hwSnap) => _scaffold(
          context,
          orders,
          paySnap.data ?? const PaymentSettings(),
          hwSnap.data ?? const HardwareSettings(),
        ),
      ),
    );
  }

  Widget _scaffold(
    BuildContext context,
    OrdersBackend orders,
    PaymentSettings payments,
    HardwareSettings hardware,
  ) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Orders'),
        actions: [OnlinePauseButton(device: device)],
      ),
      body: StreamBuilder<List<Order>>(
        stream: orders.recentOrders(device.orgId, device.locationId),
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text(errorText(snap.error!)));
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final list = snap.data!;
          if (list.isEmpty) return const Center(child: Text('No orders yet.'));
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) => _OrderTile(
              order: list[i],
              staff: staff,
              payments: payments,
              hardware: hardware,
            ),
          );
        },
      ),
    );
  }
}

enum _Action { receipt, kitchen, refund, voidOrder }

class _OrderTile extends StatelessWidget {
  const _OrderTile({
    required this.order,
    required this.staff,
    required this.payments,
    required this.hardware,
  });
  final Order order;
  final StaffSession staff;
  final PaymentSettings payments;
  final HardwareSettings hardware;

  Future<void> _chargeCard(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final done = await showDialog<CardPaymentDone>(
      context: context,
      barrierDismissible: false,
      builder: (_) => CardPaymentDialog(
        totalCents: order.totals.totalCents,
        readers: payments.readers,
        ensureOrder: () async => order,
      ),
    );
    if (done == null || !context.mounted) return;
    messenger.showSnackBar(
      SnackBar(content: Text('Order ${order.ticket} paid by card.')),
    );
    if (hardware.autoPrintReceipt) {
      await printReceipt(
        context,
        order: order,
        hardware: hardware,
        payments: [done.payment.toReceipt()],
      );
    }
  }

  Future<void> _reprintReceipt(BuildContext context) async {
    final counter = BackendScope.of(context).counter;
    final paid = [
      for (final p in await counter.payments(order).first)
        if (p.status == CardPaymentStatus.succeeded) p.toReceipt(),
    ];
    if (!context.mounted) return;
    await printReceipt(
      context,
      order: order,
      hardware: hardware,
      payments: paid,
      reprint: true,
    );
  }

  Future<void> _refund(BuildContext context) async {
    final counter = BackendScope.of(context).counter;
    final messenger = ScaffoldMessenger.of(context);
    final refundable = [
      for (final p in await counter.payments(order).first)
        if (p.status == CardPaymentStatus.succeeded && p.refundableCents > 0) p,
    ];
    if (!context.mounted) return;
    if (refundable.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Nothing left to refund on this order.')),
      );
      return;
    }
    final payment = refundable.length == 1
        ? refundable.single
        : await showDialog<OrderPayment>(
            context: context,
            builder: (c) => SimpleDialog(
              title: const Text('Refund which payment?'),
              children: [
                for (final p in refundable)
                  SimpleDialogOption(
                    onPressed: () => Navigator.of(c).pop(p),
                    child: Text(
                      '${p.label} ${formatCad(p.amountCents + p.tipCents)}',
                    ),
                  ),
              ],
            ),
          );
    if (payment == null || !context.mounted) return;
    final approval = await showDialog<ManagerApproval>(
      context: context,
      builder: (_) => ManagerApprovalDialog(
        title: 'Refund ${payment.label.toLowerCase()} on #${order.ticket}',
        action: 'Refund',
        maxRefundCents: payment.refundableCents,
      ),
    );
    if (approval == null || !context.mounted) return;
    final printing = BackendScope.printingOf(context);
    await _run(context, () async {
      final status = await counter.refundPayment(
        order,
        paymentId: payment.id,
        amountCents: approval.amountCents!,
        reason: approval.reason,
        idempotencyKey: newAttemptKey(),
        managerPin: approval.pin,
      );
      messenger.showSnackBar(
        SnackBar(
          key: const Key('refund-result'),
          content: Text(switch (status) {
            'succeeded' => 'Refunded ${formatCad(approval.amountCents!)}.',
            'pending' => 'Refund sent. It can take a moment to show.',
            _ =>
              payment.provider == 'stripe_terminal'
                  ? 'The refund didn\'t go through. Interac debit is refunded with the card on the reader, from Stripe.'
                  : 'The refund didn\'t go through.',
          }),
        ),
      );
      if (status == 'succeeded' && payment.method == 'cash') {
        showPrintErrors(messenger, await printing.openDrawer(hardware));
      }
    });
  }

  Future<void> _void(BuildContext context) async {
    final counter = BackendScope.of(context).counter;
    final approval = await showDialog<ManagerApproval>(
      context: context,
      builder: (_) => ManagerApprovalDialog(
        title: 'Void #${order.ticket}',
        action: 'Void order',
      ),
    );
    if (approval == null || !context.mounted) return;
    await _run(
      context,
      () => counter.voidOrder(
        order,
        reason: approval.reason,
        managerPin: approval.pin,
      ),
    );
  }

  Future<void> _act(BuildContext context, _Action action) => switch (action) {
    _Action.receipt => _reprintReceipt(context),
    _Action.kitchen => printKitchen(
      context,
      order: order,
      hardware: hardware,
      reprint: true,
    ),
    _Action.refund => _refund(context),
    _Action.voidOrder => _void(context),
  };

  Future<void> _run(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(errorText(e))));
    }
  }

  Future<void> _takeCash(BuildContext context) async {
    final orders = BackendScope.of(context).orders;
    final tendered = await showDialog<int>(
      context: context,
      builder: (_) => CashDialog(totalCents: order.totals.totalCents),
    );
    if (tendered == null || !context.mounted) return;
    final printing = BackendScope.printingOf(context);
    final messenger = ScaffoldMessenger.of(context);
    await _run(
      context,
      () => orders.recordCashPayment(order, staffUid: staff.uid),
    );
    if (!context.mounted) return;
    final payments = [
      ReceiptPayment(
        label: 'Cash',
        amountCents: order.totals.totalCents,
        tenderedCents: tendered,
      ),
    ];
    if (hardware.autoPrintReceipt) {
      await printReceipt(
        context,
        order: order,
        hardware: hardware,
        payments: payments,
        openDrawer: true,
      );
    } else if (hardware.drawerPrinter != null) {
      showPrintErrors(messenger, await printing.openDrawer(hardware));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final orders = BackendScope.of(context).orders;
    final unpaid =
        order.paymentStatus == PaymentStatus.unpaid &&
        order.status != OrderStatus.awaitingPayment &&
        order.status != OrderStatus.canceled &&
        order.status != OrderStatus.voided;
    final who = order.customer?.name;
    return ListTile(
      key: Key('order-${order.id}'),
      leading: CircleAvatar(
        child: Text(order.ticket, textScaler: const TextScaler.linear(0.7)),
      ),
      title: Text(['#${order.ticket}', sourceLabel(order), ?who].join(' · ')),
      subtitle: Text(
        '${statusLabel(order.status)} · ${formatCad(order.totals.totalCents)}'
        '${unpaid ? ' · not paid' : ''}\n'
        '${order.items.map((l) => '${l.qty}× ${l.name}').join(', ')}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      isThreeLine: true,
      trailing: Wrap(
        spacing: 8,
        children: [
          if (unpaid)
            OutlinedButton(
              key: Key('take-cash-${order.id}'),
              onPressed: () => _takeCash(context),
              child: const Text('Take cash'),
            ),
          if (unpaid && payments.cardsEnabled)
            OutlinedButton(
              key: Key('take-card-${order.id}'),
              onPressed: () => _chargeCard(context),
              child: const Text('Card'),
            ),
          if (order.status == OrderStatus.ready ||
              (order.status.isActive && order.source == OrderSource.pos))
            FilledButton.tonal(
              key: Key('hand-over-${order.id}'),
              onPressed: unpaid
                  ? null
                  : () => _run(
                      context,
                      () => orders.setOrderStatus(order, OrderStatus.completed),
                    ),
              child: const Text('Picked up'),
            ),
          PopupMenuButton<_Action>(
            key: Key('more-${order.id}'),
            tooltip: 'More',
            onSelected: (a) => _act(context, a),
            itemBuilder: (_) => [
              if (hardware.receiptPrinter != null)
                const PopupMenuItem(
                  value: _Action.receipt,
                  child: Text('Print receipt'),
                ),
              if (hardware.kitchenPrinters.isNotEmpty)
                const PopupMenuItem(
                  value: _Action.kitchen,
                  child: Text('Print kitchen ticket'),
                ),
              if (order.paymentStatus == PaymentStatus.paid ||
                  order.paymentStatus == PaymentStatus.partiallyRefunded)
                const PopupMenuItem(
                  key: Key('action-refund'),
                  value: _Action.refund,
                  child: Text('Refund…'),
                ),
              if (unpaid)
                const PopupMenuItem(
                  key: Key('action-void'),
                  value: _Action.voidOrder,
                  child: Text('Void…'),
                ),
            ],
          ),
        ],
      ),
      tileColor: order.status == OrderStatus.ready
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.4)
          : null,
    );
  }
}
