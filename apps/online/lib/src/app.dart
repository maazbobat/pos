import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:pos_shared/pos_shared.dart';
import 'package:url_launcher/url_launcher.dart';

typedef UrlOpener = Future<void> Function(Uri url);

Future<void> openInSameTab(Uri url) async {
  await launchUrl(url, webOnlyWindowName: '_self');
}

/// A random token for one checkout: the order's idempotency key and the
/// secret that lets this guest see its progress.
String newOrderToken([Random? random]) {
  final r = random ?? Random.secure();
  const chars =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_';
  return List.generate(32, (_) => chars[r.nextInt(chars.length)]).join();
}

/// The ordering site. Routes:
///   `/<slug>`                         the store's menu
///   `/<slug>/order/<orderId>?t=...`   an order's progress
class OnlineApp extends StatelessWidget {
  const OnlineApp({
    super.key,
    required this.backend,
    this.openUrl = openInSameTab,
    this.initialRoute,
  });
  final StorefrontBackend backend;
  final UrlOpener openUrl;
  final String? initialRoute;

  Route<void> _route(RouteSettings settings) {
    final uri = Uri.parse(settings.name ?? '/');
    final parts = uri.pathSegments.where((p) => p.isNotEmpty).toList();
    final Widget page;
    if (parts.length == 3 && parts[1] == 'order') {
      page = OrderStatusScreen(
        slug: parts[0],
        orderId: parts[2],
        token: uri.queryParameters['t'] ?? '',
      );
    } else if (parts.length == 1) {
      page = StoreScreen(slug: parts[0]);
    } else {
      page = const _Landing();
    }
    return MaterialPageRoute<void>(settings: settings, builder: (_) => page);
  }

  @override
  Widget build(BuildContext context) {
    return SiteScope(
      backend: backend,
      openUrl: openUrl,
      child: MaterialApp(
        title: 'Order online',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: Colors.deepOrange,
          useMaterial3: true,
        ),
        initialRoute: initialRoute,
        onGenerateRoute: _route,
        onGenerateInitialRoutes: (name) => [_route(RouteSettings(name: name))],
      ),
    );
  }
}

class SiteScope extends InheritedWidget {
  const SiteScope({
    super.key,
    required this.backend,
    required this.openUrl,
    required super.child,
  });
  final StorefrontBackend backend;
  final UrlOpener openUrl;

  static SiteScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SiteScope>()!;

  @override
  bool updateShouldNotify(SiteScope old) => backend != old.backend;
}

String errorMessage(Object e) =>
    e is BackendException || e is MenuValidationError
    ? e.toString()
    : 'Something went wrong. Check your connection and try again.';

class _Landing extends StatelessWidget {
  const _Landing();
  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'Open your restaurant\'s ordering link to see its menu.',
          textAlign: TextAlign.center,
        ),
      ),
    ),
  );
}

/// The store's menu and the guest's cart.
class StoreScreen extends StatefulWidget {
  const StoreScreen({super.key, required this.slug});
  final String slug;

  @override
  State<StoreScreen> createState() => _StoreScreenState();
}

class _StoreScreenState extends State<StoreScreen> {
  late Future<Storefront> _store;
  Cart _cart = const Cart(fulfillment: Fulfillment.pickup);
  var _lineNo = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _store = SiteScope.of(context).backend.storefront(widget.slug);
  }

  Future<void> _add(Storefront store, LocationMenuItem entry) async {
    final lineId = 'l${++_lineNo}';
    final line = await showModalBottomSheet<OrderLine>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ItemSheet(entry: entry, lineId: lineId),
    );
    if (line != null) {
      setState(() => _cart = _cart.add(line).withTaxRates(store.taxRates));
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Storefront>(
      future: _store,
      builder: (context, snap) {
        if (snap.hasError) {
          return Scaffold(body: Center(child: Text(errorMessage(snap.error!))));
        }
        if (!snap.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final store = snap.data!;
        final theme = Theme.of(context);
        return Scaffold(
          appBar: AppBar(
            title: Text(
              [
                store.brandName,
                store.locationName,
              ].where((s) => s.isNotEmpty).join(' · '),
            ),
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                children: [
                  if (!store.open)
                    Card(
                      key: const Key('closed'),
                      color: theme.colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          store.closedReason ?? 'Not taking orders right now.',
                        ),
                      ),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'Pickup in about ${store.pickupLeadMinutes} minutes.',
                        style: theme.textTheme.bodyLarge,
                      ),
                    ),
                  for (final section in store.sections) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 16, bottom: 4),
                      child: Text(
                        section.category.name,
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                    for (final entry in section.items)
                      ListTile(
                        key: Key('menu-${entry.item.id}'),
                        contentPadding: EdgeInsets.zero,
                        enabled: store.open && entry.available,
                        title: Text(entry.item.name),
                        subtitle: entry.item.description == null
                            ? null
                            : Text(entry.item.description!),
                        trailing: Text(
                          entry.available
                              ? formatCad(entry.priceCents)
                              : 'Sold out',
                        ),
                        onTap: () => _add(store, entry),
                      ),
                  ],
                ],
              ),
            ),
          ),
          bottomNavigationBar: _cart.isEmpty || !store.open
              ? null
              : SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: FilledButton(
                      key: const Key('view-order'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                      ),
                      onPressed: () async {
                        final result = await Navigator.of(context).push<Cart>(
                          MaterialPageRoute(
                            builder: (_) =>
                                CheckoutScreen(store: store, cart: _cart),
                          ),
                        );
                        if (result != null) setState(() => _cart = result);
                      },
                      child: Text(
                        'View order · ${_cart.itemCount} · ${formatCad(_cart.totals.totalCents)}',
                      ),
                    ),
                  ),
                ),
        );
      },
    );
  }
}

class _ItemSheet extends StatefulWidget {
  const _ItemSheet({required this.entry, required this.lineId});
  final LocationMenuItem entry;
  final String lineId;

  @override
  State<_ItemSheet> createState() => _ItemSheetState();
}

class _ItemSheetState extends State<_ItemSheet> {
  final Map<String, List<String>> _picks = {};
  final _notes = TextEditingController();
  var _qty = 1;
  String? _error;

  @override
  void initState() {
    super.initState();
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

  OrderLine? _build({bool report = false}) {
    try {
      return OrderLine.fromMenu(
        lineId: widget.lineId,
        entry: widget.entry,
        selections: _picks,
        qty: _qty,
        notes: _notes.text,
      );
    } on MenuValidationError catch (e) {
      if (report) setState(() => _error = e.message);
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final line = _build();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.entry.item.name, style: theme.textTheme.headlineSmall),
            if (widget.entry.item.description != null)
              Text(widget.entry.item.description!),
            for (final g in widget.entry.modifierGroups) ...[
              Padding(
                padding: const EdgeInsets.only(top: 16, bottom: 6),
                child: Text(
                  g.required ? '${g.name} (required)' : g.name,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final o in g.options)
                    FilterChip(
                      key: Key('pick-${g.id}-${o.id}'),
                      label: Text(
                        o.priceDeltaCents > 0
                            ? '${o.name} +${formatCad(o.priceDeltaCents)}'
                            : o.name,
                      ),
                      selected: _picks[g.id]!.contains(o.id),
                      onSelected: (_) => setState(() {
                        _error = null;
                        final picks = _picks[g.id]!;
                        if (g.maxSelect == 1) {
                          _picks[g.id] = [o.id];
                        } else if (picks.contains(o.id)) {
                          picks.remove(o.id);
                        } else if (picks.length < g.maxSelect) {
                          picks.add(o.id);
                        }
                      }),
                    ),
                ],
              ),
            ],
            TextField(
              controller: _notes,
              maxLength: 140,
              decoration: const InputDecoration(labelText: 'Special requests'),
            ),
            Row(
              children: [
                IconButton(
                  onPressed: _qty > 1 ? () => setState(() => _qty--) : null,
                  icon: const Icon(Icons.remove_circle_outline),
                ),
                Text('$_qty', style: theme.textTheme.titleLarge),
                IconButton(
                  onPressed: _qty < 20 ? () => setState(() => _qty++) : null,
                  icon: const Icon(Icons.add_circle_outline),
                ),
                const Spacer(),
                FilledButton(
                  key: const Key('add'),
                  onPressed: () {
                    final built = _build(report: true);
                    if (built != null) Navigator.of(context).pop(built);
                  },
                  child: Text(
                    line == null
                        ? 'Add'
                        : 'Add · ${formatCad(line.lineTotalCents)}',
                  ),
                ),
              ],
            ),
            if (_error != null)
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
        ),
      ),
    );
  }
}

/// Pickup slots: as soon as possible, then every 15 minutes for 6 hours.
List<DateTime?> pickupSlots(DateTime now, int leadMinutes) {
  final earliest = now.add(Duration(minutes: leadMinutes));
  final firstSlot = DateTime(
    earliest.year,
    earliest.month,
    earliest.day,
    earliest.hour,
    (earliest.minute ~/ 15 + 1) * 15,
  );
  return [
    null,
    for (var i = 0; i < 24; i++) firstSlot.add(Duration(minutes: 15 * i)),
  ];
}

/// Review the order, say who it's for and when, and how to pay.
class CheckoutScreen extends StatefulWidget {
  const CheckoutScreen({
    super.key,
    required this.store,
    required this.cart,
    this.now,
  });
  final Storefront store;
  final Cart cart;
  final DateTime? now;

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  late Cart _cart = widget.cart;
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _token = newOrderToken();
  late final _slots = pickupSlots(
    widget.now ?? DateTime.now(),
    widget.store.pickupLeadMinutes,
  );
  DateTime? _pickupAt;
  late OnlinePayment _payment = widget.store.payAtPickup
      ? OnlinePayment.atPickup
      : OnlinePayment.online;
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _place() async {
    if (!_form.currentState!.validate()) return;
    final site = SiteScope.of(context);
    final navigator = Navigator.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    String? opt(TextEditingController c) =>
        c.text.trim().isEmpty ? null : c.text.trim();
    try {
      final placed = await site.backend.placeOrder(
        slug: widget.store.slug,
        orderToken: _token,
        cart: _cart,
        payment: _payment,
        customerName: _name.text.trim(),
        phone: opt(_phone),
        email: opt(_email),
        pickupAt: _pickupAt,
      );
      if (placed.checkoutUrl != null) {
        await site.openUrl(Uri.parse(placed.checkoutUrl!));
        return;
      }
      navigator.pushNamedAndRemoveUntil(
        '/${widget.store.slug}/order/${placed.orderId}?t=$_token',
        (_) => false,
      );
    } catch (e) {
      setState(() => _error = errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final totals = _cart.totals;
    final store = widget.store;
    return PopScope<Cart>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_cart);
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Your order')),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Form(
              key: _form,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  for (final line in _cart.lines)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
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
                            tooltip: 'Remove one',
                            onPressed: () => setState(
                              () => _cart = _cart.setQty(
                                line.lineId,
                                line.qty - 1,
                              ),
                            ),
                            icon: const Icon(Icons.remove_circle_outline),
                          ),
                        ],
                      ),
                    ),
                  const Divider(),
                  for (final (label, cents) in [
                    ('Subtotal', totals.subtotalCents),
                    for (final t in totals.taxes) (t.name, t.cents),
                    ('Total', totals.totalCents),
                  ])
                    Row(
                      children: [
                        Expanded(child: Text(label)),
                        Text(
                          formatCad(cents),
                          key: label == 'Total'
                              ? const Key('checkout-total')
                              : null,
                        ),
                      ],
                    ),
                  const SizedBox(height: 16),
                  TextFormField(
                    key: const Key('name'),
                    controller: _name,
                    maxLength: 60,
                    decoration: const InputDecoration(
                      labelText: 'Name for the order',
                    ),
                    validator: (v) => (v ?? '').trim().isEmpty
                        ? 'We need a name to call out.'
                        : null,
                  ),
                  TextFormField(
                    key: const Key('phone'),
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'Phone (optional, in case of a problem)',
                    ),
                  ),
                  TextFormField(
                    key: const Key('email'),
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'Email (optional, for a receipt)',
                    ),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<DateTime?>(
                    key: const Key('pickup'),
                    isExpanded: true,
                    initialValue: _pickupAt,
                    decoration: const InputDecoration(labelText: 'Pickup'),
                    items: [
                      for (final slot in _slots)
                        DropdownMenuItem(
                          value: slot,
                          child: Text(
                            slot == null
                                ? 'As soon as possible (about ${store.pickupLeadMinutes} min)'
                                : TimeOfDay.fromDateTime(slot).format(context),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) => setState(() => _pickupAt = v),
                  ),
                  const SizedBox(height: 16),
                  if (store.payAtPickup && store.payOnline)
                    SegmentedButton<OnlinePayment>(
                      segments: const [
                        ButtonSegment(
                          value: OnlinePayment.online,
                          label: Text('Pay now by card'),
                        ),
                        ButtonSegment(
                          value: OnlinePayment.atPickup,
                          label: Text('Pay at pickup'),
                        ),
                      ],
                      selected: {_payment},
                      onSelectionChanged: (s) =>
                          setState(() => _payment = s.single),
                    )
                  else
                    Text(
                      _payment == OnlinePayment.online
                          ? 'You\'ll pay by card on the next page.'
                          : 'Pay when you pick up.',
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        _error!,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                  const SizedBox(height: 16),
                  FilledButton(
                    key: const Key('place-order'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                    ),
                    onPressed: _busy || _cart.isEmpty ? null : _place,
                    child: Text(
                      _payment == OnlinePayment.online
                          ? 'Continue to payment · ${formatCad(totals.totalCents)}'
                          : 'Place order · ${formatCad(totals.totalCents)}',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Prices include the restaurant\'s current menu and taxes; '
                    'the restaurant confirms the final total.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// An order's progress, refreshed every 10 seconds while open.
class OrderStatusScreen extends StatefulWidget {
  const OrderStatusScreen({
    super.key,
    required this.slug,
    required this.orderId,
    required this.token,
    this.refreshEvery = const Duration(seconds: 10),
  });
  final String slug;
  final String orderId;
  final String token;
  final Duration refreshEvery;

  @override
  State<OrderStatusScreen> createState() => _OrderStatusScreenState();
}

class _OrderStatusScreenState extends State<OrderStatusScreen> {
  OnlineOrderProgress? _progress;
  Object? _error;
  Timer? _timer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _timer ??= Timer.periodic(widget.refreshEvery, (_) => _load());
    if (_progress == null) _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final p = await SiteScope.of(context).backend.orderStatus(
        slug: widget.slug,
        orderId: widget.orderId,
        orderToken: widget.token,
      );
      if (!mounted) return;
      setState(() {
        _progress = p;
        _error = null;
      });
      if (p.status == OrderStatus.completed ||
          p.status == OrderStatus.canceled ||
          p.status == OrderStatus.voided) {
        _timer?.cancel();
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = _progress;
    if (p == null) {
      return Scaffold(
        body: Center(
          child: _error == null
              ? const CircularProgressIndicator()
              : Text(errorMessage(_error!)),
        ),
      );
    }
    final (headline, detail) = switch (p.status) {
      OrderStatus.awaitingPayment => (
        'Waiting for payment',
        'Finish paying to send your order to the kitchen.',
      ),
      OrderStatus.newOrder => ('Order received', 'The kitchen has your order.'),
      OrderStatus.inProgress => ('Being made', 'Almost there.'),
      OrderStatus.ready => ('Ready for pickup', 'Come on in!'),
      OrderStatus.completed => ('Picked up', 'Enjoy!'),
      OrderStatus.canceled => (
        'Canceled',
        'This order wasn\'t paid, so it was canceled.',
      ),
      OrderStatus.voided => (
        'Canceled by the restaurant',
        'Contact the restaurant if you have questions.',
      ),
    };
    final pickup = p.pickupAt;
    return Scaffold(
      appBar: AppBar(title: Text('Order ${p.ticket}')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                headline,
                key: const Key('status-headline'),
                style: theme.textTheme.headlineMedium,
              ),
              Text(detail, style: theme.textTheme.bodyLarge),
              const SizedBox(height: 8),
              Text(
                'Your number is ${p.ticket}.'
                '${pickup == null ? '' : ' Pickup around ${TimeOfDay.fromDateTime(pickup).format(context)}.'}',
              ),
              if (p.status == OrderStatus.awaitingPayment &&
                  p.checkoutUrl != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: FilledButton(
                    onPressed: () =>
                        SiteScope.of(context)
                            .openUrl(Uri.parse(p.checkoutUrl!)),
                    child: const Text('Pay now'),
                  ),
                ),
              const Divider(height: 32),
              for (final l in p.items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    '${l.qty} × ${l.name}'
                    '${l.modifiers.isEmpty ? '' : ' (${l.modifiers.join(', ')})'}',
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                'Total ${formatCad(p.totalCents)}'
                '${p.paymentStatus == PaymentStatus.paid ? ' · paid' : ' · pay at pickup'}',
                style: theme.textTheme.titleMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
