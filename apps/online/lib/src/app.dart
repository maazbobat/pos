import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:pos_shared/pos_shared.dart';
import 'package:url_launcher/url_launcher.dart';

import 'analytics.dart';
import 'legal.dart';
import 'platform/browser.dart' show hideLoadingSplash;
import 'site_chrome.dart';

export 'site_chrome.dart' show SiteScope, UrlOpener, errorMessage;

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

/// The ordering site. Routes (keep in step with functions/src/site/seo.ts):
///   `/`                               home
///   `/privacy`, `/terms`              the generic legal pages
///   `/<slug>`                         the store's menu
///   `/<slug>/privacy`, `/<slug>/terms`  the store's legal pages
///   `/<slug>/order/<orderId>?t=...`   an order's progress: the thank-you page
///   anything else                     not found
class OnlineApp extends StatefulWidget {
  const OnlineApp({
    super.key,
    required this.backend,
    this.openUrl = openInSameTab,
    this.initialRoute,
    this.analyticsSink,
    this.consent,
  });
  final StorefrontBackend backend;
  final UrlOpener openUrl;
  final String? initialRoute;

  /// Where analytics go once the guest agrees. Null: no analytics, no banner.
  final AnalyticsSink? analyticsSink;
  final ConsentController? consent;

  static Route<void> route(RouteSettings settings) {
    final uri = Uri.parse(settings.name ?? '/');
    final parts = uri.pathSegments.where((p) => p.isNotEmpty).toList();
    final legal = {for (final p in LegalPage.values) p.path: p};
    final Widget page = switch (parts) {
      [] => const LandingScreen(),
      [final p] when legal.containsKey(p) => LegalScreen(page: legal[p]!),
      [final slug] => StoreScreen(slug: slug),
      [final slug, final p] when legal.containsKey(p) => LegalScreen(
        page: legal[p]!,
        slug: slug,
      ),
      [final slug, 'order', final orderId] => OrderStatusScreen(
        slug: slug,
        orderId: orderId,
        token: uri.queryParameters['t'] ?? '',
      ),
      _ => const NotFoundScreen(),
    };
    return MaterialPageRoute<void>(settings: settings, builder: (_) => page);
  }

  @override
  State<OnlineApp> createState() => _OnlineAppState();
}

class _OnlineAppState extends State<OnlineApp> {
  final _navigator = GlobalKey<NavigatorState>();
  final _routes = RouteObserver<ModalRoute<void>>();
  late final _consent = widget.consent ?? ConsentController();
  late final _analytics = ConsentGatedAnalytics(
    consent: _consent,
    sink: widget.analyticsSink,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => hideLoadingSplash());
  }

  @override
  void dispose() {
    _analytics.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SiteScope(
      backend: widget.backend,
      openUrl: widget.openUrl,
      analytics: _analytics,
      routes: _routes,
      child: MaterialApp(
        title: 'Order online',
        navigatorKey: _navigator,
        navigatorObservers: [_routes],
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: Colors.deepOrange,
          useMaterial3: true,
        ),
        initialRoute: widget.initialRoute,
        onGenerateRoute: OnlineApp.route,
        onGenerateInitialRoutes: (name) => [
          OnlineApp.route(RouteSettings(name: name)),
        ],
        builder: (context, child) => ListenableBuilder(
          listenable: _consent,
          builder: (context, _) => Column(
            children: [
              Expanded(child: child!),
              if (_analytics.enabled && _consent.asking)
                CookieBanner(
                  consent: _consent,
                  onPrivacy: () =>
                      _navigator.currentState?.pushNamed('/privacy'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The site's home page. There's no marketing site yet: guests arrive from
/// a restaurant's own link, so this only points them back to it.
class LandingScreen extends StatelessWidget {
  const LandingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SitePage(
      title: 'Order online for pickup',
      path: '/',
      child: Scaffold(
        body: ResponsiveBody(
          maxWidth: 560,
          children: [
            const SizedBox(height: 48),
            Icon(
              Icons.takeout_dining_outlined,
              size: 64,
              color: theme.colorScheme.primary,
              semanticLabel: 'Takeout bag',
            ),
            const SizedBox(height: 16),
            Text(
              'Order ahead, skip the line',
              style: theme.textTheme.headlineMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Restaurants use this site to take pickup orders. Open the '
              'ordering link your restaurant shared to see its menu.',
              textAlign: TextAlign.center,
            ),
            const SiteFooter(),
          ],
        ),
      ),
    );
  }
}

/// The store's menu and the guest's cart.
class StoreScreen extends StatefulWidget {
  const StoreScreen({super.key, required this.slug});
  final String slug;

  @override
  State<StoreScreen> createState() => _StoreScreenState();
}

class _StoreScreenState extends State<StoreScreen> {
  Future<Storefront>? _store;
  Cart _cart = const Cart(fulfillment: Fulfillment.pickup);
  var _lineNo = 0;
  final _menuKey = GlobalKey();
  var _viewed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _store ??= _load();
  }

  Future<Storefront> _load() async {
    final store = await SiteScope.of(context).backend.storefront(widget.slug);
    if (mounted && !_viewed) {
      _viewed = true;
      SiteScope.of(context).analytics
          .event('view_store', {'store': store.slug});
    }
    return store;
  }

  void _retry() {
    final next = _load();
    setState(() {
      _store = next;
    });
  }

  Future<void> _add(Storefront store, LocationMenuItem entry) async {
    final lineId = 'l${++_lineNo}';
    final line = await showModalBottomSheet<OrderLine>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ItemSheet(entry: entry, lineId: lineId),
    );
    if (line != null && mounted) {
      setState(() => _cart = _cart.add(line).withTaxRates(store.taxRates));
      SiteScope.of(context).analytics.event('add_to_cart', {
        'item_id': entry.item.id,
        'quantity': line.qty,
        'value': line.lineTotalCents / 100,
        'currency': 'CAD',
      });
      announce(context, 'Added ${line.qty} ${line.name} to your order.');
    }
  }

  void _startOrder() {
    final menu = _menuKey.currentContext;
    if (menu != null) {
      Scrollable.ensureVisible(
        menu,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Storefront>(
      future: _store,
      builder: (context, snap) {
        if (snap.hasError) {
          if (isNotFound(snap.error!)) return const NotFoundScreen();
          return SitePage(
            title: 'Order online',
            noindex: true,
            path: '/${widget.slug}',
            child: Scaffold(
              body: ErrorState(
                message: errorMessage(snap.error!),
                onRetry: _retry,
              ),
            ),
          );
        }
        if (!snap.hasData) {
          return SitePage(
            title: 'Order online',
            path: '/${widget.slug}',
            child: const Scaffold(
              key: Key('store-loading'),
              body: LoadingState('Loading the menu…'),
            ),
          );
        }
        final store = snap.data!;
        final theme = Theme.of(context);
        final where = store.address == null ? '' : ' at ${store.address}';
        return SitePage(
          title: '${store.displayName} · Order online for pickup',
          description:
              'Order ${store.brandName.isEmpty ? store.displayName : store.brandName} '
              'ahead for pickup$where. Ready in about '
              '${store.pickupLeadMinutes} minutes.',
          path: '/${store.slug}',
          child: Scaffold(
            appBar: AppBar(title: Text(store.displayName)),
            body: ResponsiveBody(
              maxWidth: 720,
              bottomPadding: 96,
              children: [
                _StoreHeader(
                  store: store,
                  onStart: store.open ? _startOrder : null,
                ),
                SizedBox(key: _menuKey, height: 8),
                for (final section in store.sections) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 16, bottom: 4),
                    child: Semantics(
                      header: true,
                      child: Text(
                        section.category.name,
                        style: theme.textTheme.titleLarge,
                      ),
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
                if (store.sections.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text('The menu is empty right now.'),
                  ),
                SiteFooter(store: store),
              ],
            ),
            // The sticky call to action: always within thumb reach on a phone.
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
                          SiteScope.of(context).analytics
                              .event('begin_checkout', {
                                'value': _cart.totals.totalCents / 100,
                                'currency': 'CAD',
                              });
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
          ),
        );
      },
    );
  }
}

/// The top of the store page: who, where, when, and the button to start.
class _StoreHeader extends StatelessWidget {
  const _StoreHeader({required this.store, required this.onStart});
  final Storefront store;
  final VoidCallback? onStart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              store.brandName.isEmpty ? store.displayName : store.brandName,
              style: theme.textTheme.headlineMedium,
            ),
          ),
          if (store.brandName.isNotEmpty && store.locationName.isNotEmpty)
            Text(store.locationName, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (!store.open)
            Card(
              key: const Key('closed'),
              margin: const EdgeInsets.symmetric(vertical: 8),
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
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(
                    Icons.schedule,
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'Pickup in about ${store.pickupLeadMinutes} minutes',
                      style: theme.textTheme.bodyLarge,
                    ),
                  ),
                ],
              ),
            ),
          StoreContact(address: store.address, phone: store.phone),
          if (onStart != null) ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const Key('start-order'),
              style: FilledButton.styleFrom(minimumSize: const Size(200, 48)),
              onPressed: onStart,
              icon: const Icon(Icons.restaurant_menu),
              label: const Text('Start your order'),
            ),
          ],
        ],
      ),
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
                  tooltip: 'One fewer',
                  onPressed: _qty > 1 ? () => setState(() => _qty--) : null,
                  icon: const Icon(Icons.remove_circle_outline),
                ),
                Semantics(
                  label: 'Quantity $_qty',
                  excludeSemantics: true,
                  child: Text('$_qty', style: theme.textTheme.titleLarge),
                ),
                IconButton(
                  tooltip: 'One more',
                  onPressed: _qty < 20 ? () => setState(() => _qty++) : null,
                  icon: const Icon(Icons.add_circle_outline),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
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
                ),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: ErrorBanner(_error!),
              ),
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

/// Optional, but if given it must be dialable: 10 to 15 digits.
String? validatePhone(String? value) {
  final v = (value ?? '').trim();
  if (v.isEmpty) return null;
  final digits = v.replaceAll(RegExp(r'\D'), '');
  if (!RegExp(r'^\+?[0-9 ().-]+$').hasMatch(v) ||
      digits.length < 10 ||
      digits.length > 15) {
    return 'Enter a phone number with area code, like 519-555-0100.';
  }
  return null;
}

/// Optional, but if given it must look like an email address.
String? validateEmail(String? value) {
  final v = (value ?? '').trim();
  if (v.isEmpty) return null;
  if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$').hasMatch(v)) {
    return 'Enter an email address, like sam@example.com.';
  }
  return null;
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
  var _submitted = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _place() async {
    setState(() {
      _submitted = true;
      _error = null;
    });
    if (!_form.currentState!.validate()) {
      setState(() => _error = 'Check the highlighted fields.');
      return;
    }
    final site = SiteScope.of(context);
    final navigator = Navigator.of(context);
    setState(() => _busy = true);
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
      // Counted when the order exists; paid online orders finish at Stripe.
      site.analytics.event('purchase', {
        'transaction_id': placed.orderId,
        'value': placed.totalCents / 100,
        'currency': 'CAD',
        'payment_type': _payment.wire,
      });
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
    final online = _payment == OnlinePayment.online;
    final go = Navigator.of(context).pushNamed;
    return SitePage(
      title: 'Checkout · ${store.displayName}',
      noindex: true,
      path: '/${store.slug}',
      child: PopScope<Cart>(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) Navigator.of(context).pop(_cart);
        },
        child: Scaffold(
          appBar: AppBar(title: const Text('Your order')),
          body: Form(
            key: _form,
            autovalidateMode: _submitted
                ? AutovalidateMode.onUserInteraction
                : AutovalidateMode.disabled,
            child: AutofillGroup(
              child: ResponsiveBody(
                maxWidth: 560,
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
                            tooltip: 'Remove one ${line.name}',
                            onPressed: _busy
                                ? null
                                : () => setState(
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
                  if (_cart.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        'Your order is empty. Go back to add something.',
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
                    enabled: !_busy,
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.next,
                    autofillHints: const [AutofillHints.name],
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
                    enabled: !_busy,
                    keyboardType: TextInputType.phone,
                    textInputAction: TextInputAction.next,
                    autofillHints: const [AutofillHints.telephoneNumber],
                    decoration: const InputDecoration(
                      labelText: 'Phone (optional, in case of a problem)',
                    ),
                    validator: validatePhone,
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    key: const Key('email'),
                    controller: _email,
                    enabled: !_busy,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.done,
                    autofillHints: const [AutofillHints.email],
                    decoration: const InputDecoration(
                      labelText: 'Email (optional, for a receipt)',
                    ),
                    validator: validateEmail,
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
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _pickupAt = v),
                  ),
                  if (store.address != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Pick up at ${store.address}',
                        style: theme.textTheme.bodyMedium,
                      ),
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
                      onSelectionChanged: _busy
                          ? null
                          : (s) => setState(() => _payment = s.single),
                    )
                  else
                    Text(
                      online
                          ? 'You\'ll pay by card on the next page.'
                          : 'Pay when you pick up.',
                    ),
                  const SizedBox(height: 16),
                  Text(
                    'Prices include the restaurant\'s current menu and taxes; '
                    'the restaurant confirms the final total.',
                    style: theme.textTheme.bodySmall,
                  ),
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        'By placing your order you agree to the',
                        style: theme.textTheme.bodySmall,
                      ),
                      TextButton(
                        onPressed: () => go('/${store.slug}/terms'),
                        child: const Text('Terms'),
                      ),
                      Text('and', style: theme.textTheme.bodySmall),
                      TextButton(
                        onPressed: () => go('/${store.slug}/privacy'),
                        child: const Text('Privacy policy'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          // The order button stays on screen on phones, with the error above it.
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Center(
                heightFactor: 1,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 536),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_error != null)
                        ErrorBanner(_error!, key: const Key('checkout-error')),
                      FilledButton(
                        key: const Key('place-order'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(52),
                        ),
                        onPressed: _busy || _cart.isEmpty ? null : _place,
                        child: _busy
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Text(
                                    online
                                        ? 'Opening secure payment…'
                                        : 'Placing your order…',
                                  ),
                                ],
                              )
                            : Text(
                                online
                                    ? 'Continue to payment · ${formatCad(totals.totalCents)}'
                                    : 'Place order · ${formatCad(totals.totalCents)}',
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The thank-you page: the order's number, where to get it, and its
/// progress, refreshed every 10 seconds while open.
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
    if (_progress == null && _error == null) _load();
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

  void _retry() {
    setState(() => _error = null);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = _progress;
    final path = '/${widget.slug}/order/${widget.orderId}';
    if (p == null) {
      final e = _error;
      return SitePage(
        title: 'Your order',
        noindex: true,
        path: path,
        child: Scaffold(
          body: e == null
              ? const LoadingState('Checking on your order…')
              : isNotFound(e)
              ? ErrorState(
                  message:
                      "We couldn't find that order. Use the link from the "
                      'page you ordered on, or call the restaurant.',
                  onRetry: _retry,
                )
              : ErrorState(message: errorMessage(e), onRetry: _retry),
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
    final thanks = switch (p.status) {
      OrderStatus.newOrder ||
      OrderStatus.inProgress ||
      OrderStatus.ready ||
      OrderStatus.completed => true,
      _ => false,
    };
    final pickup = p.pickupAt;
    return SitePage(
      title:
          'Order ${p.ticket}${p.storeName.isEmpty ? '' : ' · ${p.storeName}'}',
      noindex: true,
      path: path,
      child: Scaffold(
        appBar: AppBar(title: Text('Order ${p.ticket}')),
        body: ResponsiveBody(
          maxWidth: 560,
          children: [
            if (thanks) ...[
              Icon(
                Icons.check_circle_outline,
                size: 56,
                color: theme.colorScheme.primary,
                semanticLabel: 'Order placed',
              ),
              const SizedBox(height: 8),
              Text(
                'Thank you for your order!',
                key: const Key('thank-you'),
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
            ],
            Semantics(
              liveRegion: true,
              child: Text(
                headline,
                key: const Key('status-headline'),
                style: theme.textTheme.headlineMedium,
              ),
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
                      SiteScope.of(context).openUrl(Uri.parse(p.checkoutUrl!)),
                  child: const Text('Pay now'),
                ),
              ),
            if (p.storeName.isNotEmpty || p.address != null || p.phone != null)
              Card(
                margin: const EdgeInsets.only(top: 16),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Pick up at', style: theme.textTheme.labelLarge),
                      if (p.storeName.isNotEmpty)
                        Text(p.storeName, style: theme.textTheme.titleMedium),
                      StoreContact(address: p.address, phone: p.phone),
                    ],
                  ),
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
            const SizedBox(height: 16),
            Text(
              'Keep this page open or bookmark it to follow your order.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                key: const Key('order-again'),
                onPressed: () => Navigator.of(context)
                    .pushNamedAndRemoveUntil('/${widget.slug}', (_) => false),
                child: const Text('Order something else'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
