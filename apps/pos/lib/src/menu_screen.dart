import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pos_shared/pos_shared.dart';

import 'app.dart';
import 'counter_widgets.dart';
import 'device_shell.dart';
import 'order_widgets.dart';
import 'orders_screen.dart';

/// Ringing up orders: the store's live menu on the left, the order on the
/// right (or behind a bar at the bottom on a narrow screen). Tap an item to
/// add it, choosing options first if it has any; long-press to mark it sold
/// out or back in stock.
class MenuScreen extends StatefulWidget {
  const MenuScreen({
    super.key,
    required this.device,
    required this.staff,
    required this.onLock,
  });
  final DeviceContext device;
  final StaffSession staff;
  final VoidCallback onLock;

  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends State<MenuScreen> {
  Cart _cart = const Cart();
  var _lineNo = 0;

  /// The location's tax rates, from the latest snapshot. Applied whenever
  /// the cart is read, so what is charged always includes tax.
  List<TaxRate> _taxRates = const [];

  PaymentSettings _payments = const PaymentSettings();
  HardwareSettings _hardware = const HardwareSettings();
  final List<StreamSubscription<Object?>> _subs = [];

  DeviceContext get device => widget.device;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_subs.isNotEmpty) return;
    final counter = BackendScope.of(context).counter;
    _subs
      ..add(
        counter
            .paymentSettings(device.orgId, device.locationId)
            .listen((s) => setState(() => _payments = s)),
      )
      ..add(
        counter
            .hardware(device.orgId, device.locationId)
            .listen((s) => setState(() => _hardware = s)),
      );
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  PosOrderDraft _draft(Cart cart) => PosOrderDraft(
    orgId: device.orgId,
    locationId: device.locationId,
    orderId: BackendScope.of(context).orders
        .newOrderId(device.orgId, device.locationId),
    deviceId: device.deviceId,
    staffUid: widget.staff.uid,
    cart: cart,
  );

  Order _orderOf(PosOrderDraft draft, PaymentStatus status) =>
      Order.fromMap(draft.orderId, {
        ...draft.toMap(createdBy: device.deviceId, paymentStatus: status),
        'createdAt': DateTime.now(),
      });

  /// After a sale: kitchen tickets, the drawer for cash, and the receipt
  /// (printed now, or offered on the confirmation).
  void _afterSale(
    Order order,
    List<ReceiptPayment> payments, {
    required bool cash,
  }) {
    final hw = _hardware;
    if (hw.autoPrintKitchen) printKitchen(context, order: order, hardware: hw);
    if (hw.autoPrintReceipt) {
      printReceipt(
        context,
        order: order,
        hardware: hw,
        payments: payments,
        openDrawer: cash,
      );
    } else if (cash && hw.drawerPrinter != null) {
      final messenger = ScaffoldMessenger.of(context);
      BackendScope.printingOf(context)
          .openDrawer(hw)
          .then((e) => showPrintErrors(messenger, e));
    }
  }

  SnackBarAction? _receiptAction(Order order, List<ReceiptPayment> payments) =>
      _hardware.receiptPrinter == null || _hardware.autoPrintReceipt
      ? null
      : SnackBarAction(
          key: const Key('print-receipt'),
          label: 'Print receipt',
          onPressed: () => printReceipt(
            context,
            order: order,
            hardware: _hardware,
            payments: payments,
          ),
        );

  Future<void> _payCard() async {
    final backend = BackendScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final cart = _cart.withTaxRates(_taxRates);
    final draft = _draft(cart);
    var placed = false;
    final done = await showDialog<CardPaymentDone>(
      context: context,
      barrierDismissible: false,
      builder: (_) => CardPaymentDialog(
        totalCents: cart.totals.totalCents,
        readers: _payments.readers,
        ensureOrder: () async {
          await backend.counter.placeUnpaidOrder(draft);
          placed = true;
          return _orderOf(draft, PaymentStatus.unpaid);
        },
      ),
    );
    if (!mounted) return;
    if (placed) _setCart(cart.clear());
    if (done == null) {
      if (placed) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Order ${draft.ticket} is saved as not paid. Take payment from Orders.',
            ),
          ),
        );
      }
      return;
    }
    final order = _orderOf(draft, PaymentStatus.paid);
    final payments = [done.payment.toReceipt()];
    _afterSale(order, payments, cash: false);
    messenger.showSnackBar(
      SnackBar(
        key: const Key('sale-done'),
        duration: const Duration(seconds: 6),
        // It may carry "Print receipt"; still go away for the next guest.
        persist: false,
        content: Text('Order ${draft.ticket} paid by card.'),
        action: _receiptAction(order, payments),
      ),
    );
  }

  void _setCart(Cart cart) => setState(() => _cart = cart);

  Future<void> _add(LocationMenuItem entry) async {
    if (!entry.available) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${entry.item.name} is sold out.')),
      );
      return;
    }
    final lineId = 'l${++_lineNo}';
    final OrderLine? line = entry.modifierGroups.isEmpty
        ? OrderLine.fromMenu(lineId: lineId, entry: entry, selections: const {})
        : await showDialog<OrderLine>(
            context: context,
            builder: (_) => ItemOptionsDialog(entry: entry, lineId: lineId),
          );
    if (line != null) _setCart(_cart.add(line));
  }

  Future<void> _payCash() async {
    final backend = BackendScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final cart = _cart.withTaxRates(_taxRates);
    final tendered = await showDialog<int>(
      context: context,
      builder: (_) => CashDialog(totalCents: cart.totals.totalCents),
    );
    if (tendered == null || !mounted) return;
    final draft = _draft(cart);
    try {
      await backend.orders.placeCashOrder(draft);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(errorText(e))));
      return;
    }
    _setCart(cart.clear());
    final change = changeDue(cart.totals.totalCents, tendered) ?? 0;
    final order = _orderOf(draft, PaymentStatus.paid);
    final payments = [
      ReceiptPayment(
        label: 'Cash',
        amountCents: cart.totals.totalCents,
        tenderedCents: tendered,
      ),
    ];
    _afterSale(order, payments, cash: true);
    messenger.showSnackBar(
      SnackBar(
        key: const Key('sale-done'),
        duration: const Duration(seconds: 6),
        // It may carry "Print receipt"; still go away for the next guest.
        persist: false,
        action: _receiptAction(order, payments),
        content: Text(
          'Order ${draft.ticket} paid. '
          '${change > 0 ? 'Change: ${formatCad(change)}' : 'No change.'}',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final backend = BackendScope.of(context);
    final data = backend.data;
    return StreamBuilder<List<TaxRate>>(
      stream: backend.orders.taxRates(device.orgId, device.locationId),
      builder: (context, taxSnap) {
        _taxRates = taxSnap.data ?? const [];
        final cart = _cart.withTaxRates(_taxRates);
        return Scaffold(
          appBar: AppBar(
            title: Text(widget.staff.label),
            actions: [
              OnlinePauseButton(device: device),
              TextButton.icon(
                key: const Key('orders'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        OrdersScreen(device: device, staff: widget.staff),
                  ),
                ),
                icon: const Icon(Icons.receipt_long_outlined),
                label: const Text('Orders'),
              ),
              TextButton.icon(
                key: const Key('lock'),
                onPressed: widget.onLock,
                icon: const Icon(Icons.lock_outline),
                label: const Text('Switch user'),
              ),
            ],
          ),
          body: StreamBuilder<List<MenuCategory>>(
            stream: data.menuCategories(device.orgId),
            builder: (context, cats) => StreamBuilder<List<MenuItem>>(
              stream: data.menuItems(device.orgId),
              builder: (context, items) => StreamBuilder<List<ModifierGroup>>(
                stream: data.modifierGroups(device.orgId),
                builder: (context, groups) => StreamBuilder<List<MenuOverride>>(
                  stream: data.menuOverrides(device.orgId, device.locationId),
                  builder: (context, overrides) {
                    if (!cats.hasData ||
                        !items.hasData ||
                        !groups.hasData ||
                        !overrides.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final menu = buildLocationMenu(
                      categories: cats.data!,
                      items: items.data!,
                      modifierGroups: groups.data!,
                      overrides: overrides.data!,
                    );
                    final menuView = menu.isEmpty
                        ? const Center(
                            child: Text(
                              'No menu yet. An owner can add items in the manager app.',
                            ),
                          )
                        : _MenuGrid(device: device, menu: menu, onTap: _add);
                    final cartPanel = CartPanel(
                      cart: cart,
                      onChanged: _setCart,
                      onPayCash: _payCash,
                      onPayCard: _payments.cardsEnabled ? _payCard : null,
                    );
                    return LayoutBuilder(
                      builder: (context, box) {
                        if (box.maxWidth >= 840) {
                          return Row(
                            children: [
                              Expanded(child: menuView),
                              const VerticalDivider(width: 1),
                              SizedBox(width: 360, child: cartPanel),
                            ],
                          );
                        }
                        return Column(
                          children: [
                            Expanded(child: menuView),
                            CartBar(
                              cart: cart,
                              onOpen: () => showModalBottomSheet<void>(
                                context: context,
                                isScrollControlled: true,
                                builder: (sheetContext) => SizedBox(
                                  height:
                                      MediaQuery.sizeOf(sheetContext).height *
                                      0.85,
                                  child: StatefulBuilder(
                                    builder: (_, setSheet) => CartPanel(
                                      cart: _cart.withTaxRates(
                                        taxSnap.data ?? const [],
                                      ),
                                      onChanged: (c) {
                                        _setCart(c);
                                        setSheet(() {});
                                      },
                                      onPayCash: () {
                                        Navigator.of(sheetContext).pop();
                                        _payCash();
                                      },
                                      onPayCard: _payments.cardsEnabled
                                          ? () {
                                              Navigator.of(sheetContext).pop();
                                              _payCard();
                                            }
                                          : null,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MenuGrid extends StatelessWidget {
  const _MenuGrid({
    required this.device,
    required this.menu,
    required this.onTap,
  });
  final DeviceContext device;
  final List<LocationMenuSection> menu;
  final ValueChanged<LocationMenuItem> onTap;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final section in menu) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              section.category.name,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final entry in section.items)
                _ItemTile(
                  device: device,
                  entry: entry,
                  onTap: () => onTap(entry),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({
    required this.device,
    required this.entry,
    required this.onTap,
  });
  final DeviceContext device;
  final LocationMenuItem entry;
  final VoidCallback onTap;

  Future<void> _toggleSoldOut(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await BackendScope.of(context).data.saveMenuOverride(
        MenuOverride(
          itemId: entry.item.id,
          orgId: device.orgId,
          locationId: device.locationId,
          available: !entry.available,
        ),
      );
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${entry.item.name} ${entry.available ? 'marked sold out' : 'back in stock'}',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(errorText(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 160,
      height: 110,
      child: Card(
        key: Key('item-${entry.item.id}'),
        color: entry.available
            ? null
            : theme.colorScheme.surfaceContainerHighest,
        child: InkWell(
          onTap: onTap,
          onLongPress: () => _toggleSoldOut(context),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.item.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
                const Spacer(),
                Text(
                  entry.available ? formatCad(entry.priceCents) : 'Sold out',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
