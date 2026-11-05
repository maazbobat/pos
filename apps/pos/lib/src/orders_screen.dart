import 'package:flutter/material.dart';
import 'package:pos_shared/pos_shared.dart';

import 'app.dart';
import 'device_shell.dart';
import 'order_widgets.dart';

/// Recent orders at this store, counter, online and delivery together.
/// Staff hand orders over here and take cash for online orders paid at
/// pickup.
class OrdersScreen extends StatelessWidget {
  const OrdersScreen({super.key, required this.device, required this.staff});
  final DeviceContext device;
  final StaffSession staff;

  @override
  Widget build(BuildContext context) {
    final orders = BackendScope.of(context).orders;
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
            itemBuilder: (context, i) =>
                _OrderTile(order: list[i], staff: staff),
          );
        },
      ),
    );
  }
}

class _OrderTile extends StatelessWidget {
  const _OrderTile({required this.order, required this.staff});
  final Order order;
  final StaffSession staff;

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
    await _run(
      context,
      () => orders.recordCashPayment(order, staffUid: staff.uid),
    );
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
        ],
      ),
      tileColor: order.status == OrderStatus.ready
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.4)
          : null,
    );
  }
}
