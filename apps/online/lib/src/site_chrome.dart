import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:pos_shared/pos_shared.dart';
import 'package:url_launcher/url_launcher.dart';

import 'analytics.dart';
import 'platform/browser.dart' as browser;

typedef UrlOpener = Future<void> Function(Uri url);

/// Narrower than this is a phone: tighter padding, sticky buttons.
const compactWidth = 600.0;

bool isCompact(BuildContext context) =>
    MediaQuery.sizeOf(context).width < compactWidth;

/// What every screen of the site can reach.
class SiteScope extends InheritedWidget {
  const SiteScope({
    super.key,
    required this.backend,
    required this.openUrl,
    required this.analytics,
    required this.routes,
    required super.child,
  });
  final StorefrontBackend backend;
  final UrlOpener openUrl;
  final ConsentGatedAnalytics analytics;
  final RouteObserver<ModalRoute<void>> routes;

  static SiteScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SiteScope>()!;

  @override
  bool updateShouldNotify(SiteScope old) =>
      backend != old.backend || analytics != old.analytics;
}

String errorMessage(Object e) =>
    e is BackendException || e is MenuValidationError
    ? e.toString()
    : 'Something went wrong. Check your connection and try again.';

bool isNotFound(Object e) => e is BackendException && e.code == 'not-found';

/// Sets the browser tab's title, the page's meta description and robots tag,
/// and counts a page view, whenever this screen is the one on top.
/// The server sets the same tags for crawlers (functions/src/site/seo.ts).
class SitePage extends StatefulWidget {
  const SitePage({
    super.key,
    required this.title,
    this.description = defaultDescription,
    this.noindex = false,
    this.path,
    required this.child,
  });

  static const defaultDescription =
      'Order ahead from your favourite local restaurant and skip the line.';

  final String title;
  final String description;
  final bool noindex;

  /// The page's path for its canonical link and analytics, without any
  /// query string (order links carry a secret).
  final String? path;
  final Widget child;

  @override
  State<SitePage> createState() => _SitePageState();
}

class _SitePageState extends State<SitePage> with RouteAware {
  RouteObserver<ModalRoute<void>>? _routes;
  String? _applied;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final routes = SiteScope.of(context).routes;
    final route = ModalRoute.of(context);
    if (routes != _routes && route != null) {
      _routes?.unsubscribe(this);
      _routes = routes..subscribe(this, route);
    }
  }

  @override
  void didUpdateWidget(SitePage old) {
    super.didUpdateWidget(old);
    if (old.title != widget.title || old.description != widget.description) {
      _apply();
    }
  }

  @override
  void dispose() {
    _routes?.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPush() => _apply();

  @override
  void didPopNext() => _apply();

  void _apply() {
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) return;
    browser.setPageMeta(
      title: widget.title,
      description: widget.description,
      noindex: widget.noindex,
      canonicalPath: widget.path,
    );
    final key = '${widget.title}|${widget.path}';
    if (_applied == key) return;
    _applied = key;
    SiteScope.of(context).analytics
        .pageView(widget.title, widget.path ?? '/(unknown)');
  }

  @override
  Widget build(BuildContext context) => Title(
    title: widget.title,
    color: Theme.of(context).colorScheme.primary,
    child: widget.child,
  );
}

/// A centred column that is phone-width on phones and capped on desktops.
class ResponsiveBody extends StatelessWidget {
  const ResponsiveBody({
    super.key,
    required this.children,
    this.maxWidth = 720,
    this.controller,
    this.bottomPadding = 24,
  });
  final List<Widget> children;
  final double maxWidth;
  final ScrollController? controller;
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    final side = isCompact(context) ? 16.0 : 24.0;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: ListView(
          controller: controller,
          padding: EdgeInsets.fromLTRB(side, 8, side, bottomPadding),
          children: children,
        ),
      ),
    );
  }
}

/// A spinner with words, announced to screen readers.
class LoadingState extends StatelessWidget {
  const LoadingState(this.label, {super.key});
  final String label;

  @override
  Widget build(BuildContext context) => Center(
    child: Semantics(
      liveRegion: true,
      label: label,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          ExcludeSemantics(child: Text(label)),
        ],
      ),
    ),
  );
}

/// Something failed to load: say what, and offer to try again.
class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.wifi_off_rounded,
              size: 48,
              color: theme.colorScheme.error,
              semanticLabel: 'Problem loading',
            ),
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(message, textAlign: TextAlign.center),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('retry'),
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}

/// A form or request error, shown as a banner where the guest is looking.
class ErrorBanner extends StatelessWidget {
  const ErrorBanner(this.message, {super.key});
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Card(
        color: scheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.error_outline,
                color: scheme.onErrorContainer,
                semanticLabel: 'Error',
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(color: scheme.onErrorContainer),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The 404 page: an unknown store, an old link or a typo.
class NotFoundScreen extends StatelessWidget {
  const NotFoundScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SitePage(
      title: 'Page not found',
      description: "We couldn't find that page.",
      noindex: true,
      child: Scaffold(
        body: ResponsiveBody(
          maxWidth: 560,
          children: [
            const SizedBox(height: 48),
            Icon(
              Icons.storefront_outlined,
              size: 64,
              color: theme.colorScheme.primary,
              semanticLabel: 'Shop front',
            ),
            const SizedBox(height: 16),
            Text(
              "We couldn't find that page",
              key: const Key('not-found'),
              style: theme.textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'The link may be old or mistyped. Check the ordering link from '
              'the restaurant, or ask them for it.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Center(
              child: OutlinedButton(
                onPressed: () =>
                    Navigator.of(context)
                        .pushNamedAndRemoveUntil('/', (_) => false),
                child: const Text('Go to the home page'),
              ),
            ),
            const SiteFooter(),
          ],
        ),
      ),
    );
  }
}

Uri mapsLink(String address) => Uri.https('www.google.com', '/maps/search/', {
  'api': '1',
  'query': address,
});

Uri phoneLink(String phone) =>
    Uri(scheme: 'tel', path: phone.replaceAll(RegExp(r'[^0-9+]'), ''));

Future<void> openExternal(Uri url) =>
    launchUrl(url, webOnlyWindowName: '_blank');

/// The store's address, phone and email, each a link. Shows nothing it
/// doesn't have: the address is always the restaurant's own.
class StoreContact extends StatelessWidget {
  const StoreContact({
    super.key,
    this.address,
    this.phone,
    this.email,
    this.dense = false,
    this.keyPrefix = 'store',
  });
  final String? address;
  final String? phone;
  final String? email;
  final bool dense;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final rows = [
      if (address != null)
        _row(
          context,
          Icons.place_outlined,
          address!,
          'Directions',
          mapsLink(address!),
          Key('$keyPrefix-address'),
        ),
      if (phone != null)
        _row(
          context,
          Icons.call_outlined,
          phone!,
          'Call',
          phoneLink(phone!),
          Key('$keyPrefix-phone'),
        ),
      if (email != null)
        _row(
          context,
          Icons.mail_outline,
          email!,
          'Email',
          Uri(scheme: 'mailto', path: email),
          Key('$keyPrefix-email'),
        ),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  Widget _row(
    BuildContext context,
    IconData icon,
    String text,
    String action,
    Uri link,
    Key key,
  ) => InkWell(
    key: key,
    onTap: () => openExternal(link),
    child: Semantics(
      link: true,
      label: '$action: $text',
      excludeSemantics: true,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: dense ? 2 : 6),
        child: Row(
          children: [
            Icon(icon, size: 20),
            const SizedBox(width: 8),
            Flexible(child: Text(text)),
          ],
        ),
      ),
    ),
  );
}

/// Contact details, the legal pages and cookie settings, on every page.
class SiteFooter extends StatelessWidget {
  const SiteFooter({super.key, this.store});
  final Storefront? store;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = store;
    final site = SiteScope.of(context);
    final prefix = s == null ? '' : '/${s.slug}';
    void go(String path) => Navigator.of(context).pushNamed(path);
    return Padding(
      padding: const EdgeInsets.only(top: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(),
          if (s != null) ...[
            Text(s.displayName, style: theme.textTheme.titleSmall),
            StoreContact(
              address: s.address,
              phone: s.phone,
              email: s.email,
              dense: true,
              keyPrefix: 'footer',
            ),
          ],
          Wrap(
            spacing: 4,
            children: [
              TextButton(
                key: const Key('footer-privacy'),
                onPressed: () => go('$prefix/privacy'),
                child: const Text('Privacy policy'),
              ),
              TextButton(
                key: const Key('footer-terms'),
                onPressed: () => go('$prefix/terms'),
                child: const Text('Terms of use'),
              ),
              if (site.analytics.enabled)
                TextButton(
                  key: const Key('footer-cookies'),
                  onPressed: site.analytics.consent.reopen,
                  child: const Text('Cookie settings'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Asks once whether analytics cookies are OK. Shown only when the site has
/// analytics built in; nothing optional loads until the guest says yes.
class CookieBanner extends StatelessWidget {
  const CookieBanner({
    super.key,
    required this.consent,
    required this.onPrivacy,
  });
  final ConsentController consent;
  final VoidCallback onPrivacy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      key: const Key('cookie-banner'),
      elevation: 8,
      color: theme.colorScheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Semantics(
                container: true,
                explicitChildNodes: true,
                label: 'Cookie choice',
                child: Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 440),
                      child: const Text(
                        'We use cookies for analytics to improve this page, '
                        'only if you agree. Ordering works either way.',
                      ),
                    ),
                    TextButton(
                      onPressed: onPrivacy,
                      child: const Text('Learn more'),
                    ),
                    OutlinedButton(
                      key: const Key('cookies-decline'),
                      onPressed: () => consent.choose(analytics: false),
                      child: const Text('Decline'),
                    ),
                    FilledButton(
                      key: const Key('cookies-accept'),
                      onPressed: () => consent.choose(analytics: true),
                      child: const Text('Accept'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Announces [message] to screen readers, for results that appear without
/// focus moving (an item added to the cart).
void announce(BuildContext context, String message) {
  SemanticsService.sendAnnouncement(
    View.of(context),
    message,
    Directionality.of(context),
  );
}
