import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pos_shared/pos_shared.dart';

import 'app.dart';
import 'device_shell.dart';
import 'order_widgets.dart';

/// The kitchen display: every open ticket from the counter, the ordering
/// site and delivery apps, oldest first. Tap a ticket's button to move it
/// along (new → making → ready → picked up). Filter by station to show only
/// the bar's or the grill's items.
///
/// Orders live in Firestore, so a display that drops off the network shows
/// new tickets as soon as it is back, and nothing is lost meanwhile.
class KitchenScreen extends StatefulWidget {
  const KitchenScreen({super.key, required this.device});
  final DeviceContext device;

  @override
  State<KitchenScreen> createState() => _KitchenScreenState();
}

class _KitchenScreenState extends State<KitchenScreen> {
  String? _station;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // Ticket ages count up.
    _tick = Timer.periodic(const Duration(seconds: 30), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final device = widget.device;
    final orders = BackendScope.of(context).orders;
    return StreamBuilder<List<Order>>(
      stream: orders.kitchenOrders(device.orgId, device.locationId),
      builder: (context, snap) {
        final all = snap.data ?? const <Order>[];
        final stations = {
          for (final o in all)
            for (final l in o.items) ?l.kitchenStation,
        }.toList()..sort();
        final station = stations.contains(_station) ? _station : null;
        final tickets = [
          for (final o in all)
            if (station == null ||
                o.items.any((l) => l.kitchenStation == station))
              o,
        ];
        return Scaffold(
          appBar: AppBar(
            title: Text('Kitchen · ${tickets.length} open'),
            actions: [
              OnlinePauseButton(device: device),
              if (stations.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: DropdownButton<String?>(
                    key: const Key('station'),
                    value: station,
                    hint: const Text('All stations'),
                    items: [
                      const DropdownMenuItem(
                        value: null,
                        child: Text('All stations'),
                      ),
                      for (final s in stations)
                        DropdownMenuItem(value: s, child: Text(s)),
                    ],
                    onChanged: (s) => setState(() => _station = s),
                  ),
                ),
            ],
          ),
          body: snap.hasError
              ? Center(child: Text(errorText(snap.error!)))
              : !snap.hasData
              ? const Center(child: CircularProgressIndicator())
              : tickets.isEmpty
              ? const Center(child: Text('No open orders.'))
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final o in tickets)
                        _Ticket(order: o, station: station),
                    ],
                  ),
                ),
        );
      },
    );
  }
}

class _Ticket extends StatelessWidget {
  const _Ticket({required this.order, required this.station});
  final Order order;
  final String? station;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final orders = BackendScope.of(context).orders;
    final created = order.createdAt;
    final minutes = created == null
        ? 0
        : DateTime.now().difference(created).inMinutes;
    final next = order.status.next;
    final color = switch (order.status) {
      OrderStatus.newOrder => theme.colorScheme.errorContainer,
      OrderStatus.inProgress => theme.colorScheme.tertiaryContainer,
      _ => theme.colorScheme.primaryContainer,
    };
    final pickup = order.pickupAt;
    return SizedBox(
      width: 260,
      child: Card(
        key: Key('ticket-${order.id}'),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              color: color,
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        '#${order.ticket}',
                        style: theme.textTheme.titleLarge,
                      ),
                      const Spacer(),
                      Text('${minutes}m'),
                    ],
                  ),
                  Text(
                    [
                      sourceLabel(order),
                      switch (order.fulfillment) {
                        Fulfillment.here => 'For here',
                        Fulfillment.takeout => 'To go',
                        Fulfillment.pickup => 'Pickup',
                        Fulfillment.delivery => 'Delivery',
                      },
                      ?order.customer?.name,
                      if (pickup != null)
                        'at ${TimeOfDay.fromDateTime(pickup).format(context)}',
                    ].join(' · '),
                  ),
                ],
              ),
            ),
            for (final line in order.items)
              Opacity(
                opacity: station == null || line.kitchenStation == station
                    ? 1
                    : 0.35,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${line.qty} × ${line.name}',
                        style: theme.textTheme.titleMedium,
                      ),
                      for (final m in line.modifiers) Text('   ${m.name}'),
                      if (line.notes != null)
                        Text(
                          '   “${line.notes}”',
                          style: const TextStyle(fontStyle: FontStyle.italic),
                        ),
                    ],
                  ),
                ),
              ),
            if (order.notes != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                child: Text(
                  'Note: ${order.notes}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: next == null
                  ? const SizedBox.shrink()
                  : FilledButton(
                      key: Key('advance-${order.id}'),
                      onPressed: () => orders.setOrderStatus(order, next),
                      child: Text(switch (next) {
                        OrderStatus.inProgress => 'Start',
                        OrderStatus.ready => 'Ready',
                        _ => 'Picked up',
                      }),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
