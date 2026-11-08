import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:pos_shared/pos_shared.dart';
import 'package:url_launcher/url_launcher.dart';

import 'analytics.dart';
import 'legal.dart';
import 'platform/browser.dart' show hideLoadingSplash;
import 'site_chrome.dart';
import 'store_screen.dart';
import 'theme.dart';

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
        theme: siteTheme(),
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
                maxWidth: 640,
                bottomPadding: 32,
                children: [
                  CheckoutSection(
                    icon: Icons.receipt_long_outlined,
                    title: 'Your order',
                    child: Column(
                      children: [
                        for (final line in _cart.lines)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${line.qty} × ${line.name}',
                                        style: theme.textTheme.titleSmall,
                                      ),
                                      if (line.modifiers.isNotEmpty ||
                                          line.notes != null)
                                        Text(
                                          [
                                            ...line.modifiers.map(
                                              (m) => m.name,
                                            ),
                                            ?line.notes,
                                          ].join(', '),
                                          style: theme.textTheme.bodySmall,
                                        ),
                                    ],
                                  ),
                                ),
                                Text(formatCad(line.lineTotalCents)),
                                IconButton(
                                  visualDensity: VisualDensity.compact,
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
                            padding: EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              'Your order is empty. Go back to add something.',
                            ),
                          ),
                        const Divider(height: 24),
                        for (final (label, cents) in [
                          ('Subtotal', totals.subtotalCents),
                          for (final t in totals.taxes) (t.name, t.cents),
                          ('Total', totals.totalCents),
                        ])
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    label,
                                    style: label == 'Total'
                                        ? theme.textTheme.titleMedium
                                        : null,
                                  ),
                                ),
                                Text(
                                  formatCad(cents),
                                  key: label == 'Total'
                                      ? const Key('checkout-total')
                                      : null,
                                  style: label == 'Total'
                                      ? theme.textTheme.titleMedium
                                      : null,
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  CheckoutSection(
                    icon: Icons.person_outline,
                    title: 'Who it\'s for',
                    child: Column(
                      children: [
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
                            prefixIcon: Icon(Icons.badge_outlined),
                          ),
                          validator: (v) => (v ?? '').trim().isEmpty
                              ? 'We need a name to call out.'
                              : null,
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          key: const Key('phone'),
                          controller: _phone,
                          enabled: !_busy,
                          keyboardType: TextInputType.phone,
                          textInputAction: TextInputAction.next,
                          autofillHints: const [AutofillHints.telephoneNumber],
                          decoration: const InputDecoration(
                            labelText: 'Phone (optional, in case of a problem)',
                            prefixIcon: Icon(Icons.call_outlined),
                          ),
                          validator: validatePhone,
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          key: const Key('email'),
                          controller: _email,
                          enabled: !_busy,
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.done,
                          autofillHints: const [AutofillHints.email],
                          decoration: const InputDecoration(
                            labelText: 'Email (optional, for a receipt)',
                            prefixIcon: Icon(Icons.mail_outline),
                          ),
                          validator: validateEmail,
                        ),
                      ],
                    ),
                  ),
                  CheckoutSection(
                    icon: Icons.schedule,
                    title: 'Pickup',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        DropdownButtonFormField<DateTime?>(
                          key: const Key('pickup'),
                          isExpanded: true,
                          initialValue: _pickupAt,
                          decoration: const InputDecoration(labelText: 'When'),
                          items: [
                            for (final slot in _slots)
                              DropdownMenuItem(
                                value: slot,
                                child: Text(
                                  slot == null
                                      ? 'As soon as possible (about ${store.pickupLeadMinutes} min)'
                                      : TimeOfDay.fromDateTime(slot)
                                            .format(context),
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
                            padding: const EdgeInsets.only(top: 12),
                            child: Row(
                              children: [
                                const Icon(Icons.place_outlined, size: 20),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text('Pick up at ${store.address}'),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  CheckoutSection(
                    icon: Icons.payments_outlined,
                    title: 'Payment',
                    child: store.payAtPickup && store.payOnline
                        ? Column(
                            children: [
                              PaymentOption(
                                key: const Key('pay-online'),
                                icon: Icons.credit_card,
                                title: 'Pay now by card',
                                subtitle: 'Secure checkout by Stripe',
                                selected: online,
                                onTap: _busy
                                    ? null
                                    : () => setState(
                                        () => _payment = OnlinePayment.online,
                                      ),
                              ),
                              const SizedBox(height: 8),
                              PaymentOption(
                                key: const Key('pay-at-pickup'),
                                icon: Icons.storefront_outlined,
                                title: 'Pay at pickup',
                                subtitle: 'Cash or card at the counter',
                                selected: !online,
                                onTap: _busy
                                    ? null
                                    : () => setState(
                                        () => _payment = OnlinePayment.atPickup,
                                      ),
                              ),
                            ],
                          )
                        : Text(
                            online
                                ? 'You\'ll pay by card on the next page.'
                                : 'Pay when you pick up.',
                          ),
                  ),
                  const SizedBox(height: 8),
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

/// A titled white card grouping one step of checkout.
class CheckoutSection extends StatelessWidget {
  const CheckoutSection({
    super.key,
    required this.icon,
    required this.title,
    required this.child,
  });
  final IconData icon;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(icon, size: 22, color: SiteColors.brand),
                  const SizedBox(width: 8),
                  Semantics(
                    header: true,
                    child: Text(title, style: theme.textTheme.titleMedium),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

/// One way to pay, as a big tappable card with a radio mark.
class PaymentOption extends StatelessWidget {
  const PaymentOption({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      button: true,
      label: '$title. $subtitle',
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(SiteRadius.button),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: selected
                ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5)
                : Colors.white,
            borderRadius: BorderRadius.circular(SiteRadius.button),
            border: Border.all(
              color: selected
                  ? SiteColors.brand
                  : theme.colorScheme.outlineVariant,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Icon(icon, color: selected ? SiteColors.brand : null),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleSmall),
                    Text(subtitle, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                color: selected ? SiteColors.brand : theme.colorScheme.outline,
              ),
            ],
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
          maxWidth: 600,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    if (thanks) ...[
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: SiteColors.success.withValues(alpha: 0.12),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.check_rounded,
                          size: 44,
                          color: SiteColors.success,
                          semanticLabel: 'Order placed',
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Thank you for your order!',
                        key: const Key('thank-you'),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleLarge,
                      ),
                      const SizedBox(height: 16),
                    ],
                    Text(
                      'Your number',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Container(
                      margin: const EdgeInsets.only(top: 4, bottom: 16),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer.withValues(
                          alpha: 0.6,
                        ),
                        borderRadius: BorderRadius.circular(SiteRadius.button),
                      ),
                      child: Semantics(
                        label: 'Your number is ${p.ticket}',
                        excludeSemantics: true,
                        child: Text(
                          p.ticket,
                          key: const Key('ticket'),
                          style: theme.textTheme.displaySmall?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: SiteColors.brand,
                          ),
                        ),
                      ),
                    ),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        headline,
                        key: const Key('status-headline'),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      detail,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 4),
                    if (pickup != null)
                      Text(
                        'Pickup around ${TimeOfDay.fromDateTime(pickup).format(context)}.',
                        textAlign: TextAlign.center,
                      ),
                    if (OrderTracker.stepOf(p.status) != null) ...[
                      const SizedBox(height: 20),
                      OrderTracker(status: p.status),
                    ],
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
                  ],
                ),
              ),
            ),
            if (p.storeName.isNotEmpty || p.address != null || p.phone != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: CheckoutSection(
                  icon: Icons.storefront_outlined,
                  title: 'Pick up at',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (p.storeName.isNotEmpty)
                        Text(p.storeName, style: theme.textTheme.titleMedium),
                      StoreContact(address: p.address, phone: p.phone),
                    ],
                  ),
                ),
              ),
            CheckoutSection(
              icon: Icons.receipt_long_outlined,
              title: 'Your order',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final l in p.items)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        '${l.qty} × ${l.name}'
                        '${l.modifiers.isEmpty ? '' : ' (${l.modifiers.join(', ')})'}',
                      ),
                    ),
                  const Divider(height: 20),
                  Text(
                    'Total ${formatCad(p.totalCents)}'
                    '${p.paymentStatus == PaymentStatus.paid ? ' · paid' : ' · pay at pickup'}',
                    style: theme.textTheme.titleMedium,
                  ),
                ],
              ),
            ),
            Text(
              'This page updates by itself. Keep it open or bookmark it to '
              'follow your order.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const Key('order-again'),
              onPressed: () =>
                  Navigator.of(context)
                      .pushNamedAndRemoveUntil('/${widget.slug}', (_) => false),
              icon: const Icon(Icons.add_shopping_cart),
              label: const Text('Order something else'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Received → Being made → Ready → Picked up, with the current step lit.
class OrderTracker extends StatelessWidget {
  const OrderTracker({super.key, required this.status});
  final OrderStatus status;

  static const steps = ['Received', 'Being made', 'Ready', 'Picked up'];

  /// Which step [status] is, or null when it's off the happy path.
  static int? stepOf(OrderStatus status) => switch (status) {
    OrderStatus.newOrder => 0,
    OrderStatus.inProgress => 1,
    OrderStatus.ready => 2,
    OrderStatus.completed => 3,
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = stepOf(status) ?? 0;
    final idle = theme.colorScheme.outlineVariant;
    return Semantics(
      key: const Key('order-tracker'),
      container: true,
      label: 'Step ${current + 1} of ${steps.length}: ${steps[current]}',
      excludeSemantics: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < steps.length; i++)
            Expanded(
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          height: 3,
                          color: i == 0
                              ? Colors.transparent
                              : (i <= current ? SiteColors.success : idle),
                        ),
                      ),
                      Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i <= current ? SiteColors.success : idle,
                        ),
                        child: i < current || current == steps.length - 1
                            ? const Icon(
                                Icons.check,
                                size: 16,
                                color: Colors.white,
                              )
                            : i == current
                            ? const Icon(
                                Icons.circle,
                                size: 10,
                                color: Colors.white,
                              )
                            : null,
                      ),
                      Expanded(
                        child: Container(
                          height: 3,
                          color: i == steps.length - 1
                              ? Colors.transparent
                              : (i < current ? SiteColors.success : idle),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    steps[i],
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: i == current ? FontWeight.w700 : null,
                      color: i <= current
                          ? SiteColors.ink
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
