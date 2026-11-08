import 'dart:math';

import 'package:flutter/material.dart';
import 'package:pos_shared/pos_shared.dart';

import 'app.dart' show CheckoutScreen;
import 'site_chrome.dart';
import 'theme.dart';

/// Wider than this, the cart sits beside the menu instead of in a bar.
const sideCartWidth = 1100.0;

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
  var _viewed = false;
  final _scroll = ScrollController();
  final _menuKey = GlobalKey();
  final Map<String, GlobalKey> _sectionKeys = {};
  final _search = TextEditingController();
  var _query = '';
  String? _activeSection;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _store ??= _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _search.dispose();
    super.dispose();
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
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (_) => ItemSheet(entry: entry, lineId: lineId),
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

  Future<void> _checkout(Storefront store) async {
    SiteScope.of(context).analytics.event('begin_checkout', {
      'value': _cart.totals.totalCents / 100,
      'currency': 'CAD',
    });
    final result = await Navigator.of(context).push<Cart>(
      MaterialPageRoute(
        builder: (_) => CheckoutScreen(store: store, cart: _cart),
      ),
    );
    if (result != null) setState(() => _cart = result);
  }

  /// Scrolls so [key]'s widget sits just under the pinned category bar.
  Future<void> _jumpTo(GlobalKey key) async {
    final target = key.currentContext;
    if (target == null) return;
    await Scrollable.ensureVisible(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
    if (!_scroll.hasClients) return;
    final back = max(0.0, _scroll.offset - _CategoryBar.height - 8);
    await _scroll.animateTo(
      back,
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
    );
  }

  bool _matches(LocationMenuItem e) {
    if (_query.isEmpty) return true;
    final q = _query.toLowerCase();
    return e.item.name.toLowerCase().contains(q) ||
        (e.item.description ?? '').toLowerCase().contains(q);
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
        final where = store.address == null ? '' : ' at ${store.address}';
        return SitePage(
          title: '${store.displayName} · Order online for pickup',
          description:
              'Order ${store.brandName.isEmpty ? store.displayName : store.brandName} '
              'ahead for pickup$where. Ready in about '
              '${store.pickupLeadMinutes} minutes.',
          path: '/${store.slug}',
          child: LayoutBuilder(
            builder: (context, box) {
              final wide = box.maxWidth >= sideCartWidth;
              final menu = _menu(context, store, wide: wide);
              return Scaffold(
                body: wide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: menu),
                          SizedBox(
                            width: 380,
                            child: _SideCart(
                              store: store,
                              cart: _cart,
                              onCheckout: () => _checkout(store),
                              onRemove: (lineId, qty) => setState(
                                () => _cart = _cart.setQty(lineId, qty),
                              ),
                            ),
                          ),
                        ],
                      )
                    : menu,
                // The sticky call to action: always within thumb reach on a phone.
                bottomNavigationBar: wide || _cart.isEmpty || !store.open
                    ? null
                    : _CartBar(cart: _cart, onTap: () => _checkout(store)),
              );
            },
          ),
        );
      },
    );
  }

  Widget _menu(BuildContext context, Storefront store, {required bool wide}) {
    final theme = Theme.of(context);
    final sections = [
      for (final s in store.sections)
        (section: s, items: s.items.where(_matches).toList()),
    ].where((s) => s.items.isNotEmpty).toList();
    for (final s in store.sections) {
      _sectionKeys.putIfAbsent(s.category.id, GlobalKey.new);
    }
    final side = isCompact(context) ? 16.0 : 24.0;
    Widget capped(Widget child) => Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: side),
          child: SizedBox(width: double.infinity, child: child),
        ),
      ),
    );
    return CustomScrollView(
      key: const Key('store-scroll'),
      controller: _scroll,
      slivers: [
        SliverToBoxAdapter(
          child: _StoreHero(
            store: store,
            onStart: store.open ? () => _jumpTo(_menuKey) : null,
          ),
        ),
        SliverPersistentHeader(
          pinned: true,
          delegate: _CategoryBar(
            sections: [for (final s in store.sections) s.category],
            active: _activeSection,
            search: _search,
            onSearch: (q) => setState(() => _query = q.trim()),
            onPick: (id) {
              setState(() {
                _activeSection = id;
                _query = '';
                _search.clear();
              });
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => _jumpTo(_sectionKeys[id]!),
              );
            },
          ),
        ),
        SliverToBoxAdapter(child: SizedBox(key: _menuKey, height: 8)),
        if (sections.isEmpty)
          SliverToBoxAdapter(
            child: capped(
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Text(
                  _query.isEmpty
                      ? 'The menu is empty right now.'
                      : 'Nothing on the menu matches "$_query".',
                  key: const Key('menu-empty'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge,
                ),
              ),
            ),
          ),
        for (final s in sections) ...[
          SliverToBoxAdapter(
            child: capped(
              Padding(
                key: _sectionKeys[s.section.category.id],
                padding: const EdgeInsets.only(top: 20, bottom: 12),
                child: Semantics(
                  header: true,
                  child: Text(
                    s.section.category.name,
                    style: theme.textTheme.headlineSmall,
                  ),
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: capped(
              LayoutBuilder(
                builder: (context, box) {
                  final columns = box.maxWidth >= 640 ? 2 : 1;
                  final width = (box.maxWidth - 12 * (columns - 1)) / columns;
                  return Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final entry in s.items)
                        SizedBox(
                          width: width,
                          child: _MenuItemCard(
                            entry: entry,
                            open: store.open,
                            inCart: _cart.lines
                                .where((l) => l.itemId == entry.item.id)
                                .fold(0, (n, l) => n + l.qty),
                            onAdd: () => _add(store, entry),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
        SliverToBoxAdapter(
          child: capped(
            Padding(
              padding: const EdgeInsets.only(bottom: 120),
              child: SiteFooter(store: store),
            ),
          ),
        ),
      ],
    );
  }
}

/// The store's banner: who, whether it's open, how fast, where, and the
/// button to start.
class _StoreHero extends StatelessWidget {
  const _StoreHero({required this.store, required this.onStart});
  final Storefront store;
  final VoidCallback? onStart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = isCompact(context);
    final name = store.brandName.isEmpty ? store.displayName : store.brandName;
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    const onBrand = Colors.white;
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF76707), Color(0xFFD9480F)],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                compact ? 16 : 24,
                compact ? 24 : 40,
                compact ? 16 : 24,
                compact ? 24 : 36,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      ExcludeSemantics(
                        child: CircleAvatar(
                          radius: compact ? 28 : 34,
                          backgroundColor: Colors.white,
                          child: Text(
                            initial,
                            style: theme.textTheme.headlineSmall?.copyWith(
                              color: SiteColors.brand,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Semantics(
                              header: true,
                              child: Text(
                                name,
                                style:
                                    (compact
                                            ? theme.textTheme.headlineMedium
                                            : theme.textTheme.headlineLarge)
                                        ?.copyWith(color: onBrand),
                              ),
                            ),
                            if (store.brandName.isNotEmpty &&
                                store.locationName.isNotEmpty)
                              Text(
                                store.locationName,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  color: onBrand.withValues(alpha: 0.9),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _Pill(
                        icon: store.open ? Icons.circle : Icons.pause_circle,
                        iconColor: store.open
                            ? const Color(0xFF8CE99A)
                            : const Color(0xFFFFE066),
                        text: store.open
                            ? 'Open for orders'
                            : 'Not taking orders',
                      ),
                      if (store.open)
                        _Pill(
                          icon: Icons.schedule,
                          text: 'Ready in ~${store.pickupLeadMinutes} min',
                        ),
                      _Pill(icon: Icons.shopping_bag_outlined, text: 'Pickup'),
                      if (store.payOnline)
                        const _Pill(
                          icon: Icons.credit_card,
                          text: 'Pay online',
                        ),
                    ],
                  ),
                  if (!store.open)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Card(
                        key: const Key('closed'),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              Icon(
                                Icons.info_outline,
                                color: theme.colorScheme.error,
                                semanticLabel: 'Note',
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  store.closedReason ??
                                      'Not taking orders right now.',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (store.address != null || store.phone != null) ...[
                    const SizedBox(height: 16),
                    DefaultTextStyle.merge(
                      style: const TextStyle(color: onBrand),
                      child: IconTheme.merge(
                        data: const IconThemeData(color: onBrand),
                        child: StoreContact(
                          address: store.address,
                          phone: store.phone,
                        ),
                      ),
                    ),
                  ],
                  if (onStart != null) ...[
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      key: const Key('start-order'),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: SiteColors.brand,
                        minimumSize: const Size(220, 56),
                      ),
                      onPressed: onStart,
                      icon: const Icon(Icons.restaurant_menu),
                      label: const Text('Start your order'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.text, this.iconColor});
  final IconData icon;
  final String text;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(SiteRadius.pill),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: iconColor ?? Colors.white),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
  );
}

/// Search and category tabs, pinned under the banner while the guest scrolls.
class _CategoryBar extends SliverPersistentHeaderDelegate {
  _CategoryBar({
    required this.sections,
    required this.active,
    required this.search,
    required this.onSearch,
    required this.onPick,
  });
  final List<MenuCategory> sections;
  final String? active;
  final TextEditingController search;
  final ValueChanged<String> onSearch;
  final ValueChanged<String> onPick;

  static const height = 124.0;

  @override
  double get minExtent => height;
  @override
  double get maxExtent => height;

  @override
  Widget build(BuildContext context, double shrink, bool overlaps) {
    final side = isCompact(context) ? 16.0 : 24.0;
    return Material(
      color: SiteColors.canvas,
      elevation: overlaps ? 2 : 0,
      shadowColor: Colors.black26,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: Padding(
            padding: EdgeInsets.fromLTRB(side, 12, side, 8),
            child: Column(
              children: [
                SizedBox(
                  height: 48,
                  child: TextField(
                    key: const Key('menu-search'),
                    controller: search,
                    onChanged: onSearch,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: 'Search the menu',
                      prefixIcon: const Icon(Icons.search),
                      contentPadding: EdgeInsets.zero,
                      suffixIcon: ListenableBuilder(
                        listenable: search,
                        builder: (context, _) => search.text.isEmpty
                            ? const SizedBox.shrink()
                            : IconButton(
                                tooltip: 'Clear search',
                                icon: const Icon(Icons.close),
                                onPressed: () {
                                  search.clear();
                                  onSearch('');
                                },
                              ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 44,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: sections.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (context, i) {
                      final c = sections[i];
                      return ChoiceChip(
                        key: Key('category-${c.id}'),
                        label: Text(c.name),
                        selected: c.id == active,
                        showCheckmark: false,
                        onSelected: (_) => onPick(c.id),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_CategoryBar old) =>
      old.active != active || old.sections != sections;
}

/// One menu item: name, description, price and a big + to add it.
class _MenuItemCard extends StatelessWidget {
  const _MenuItemCard({
    required this.entry,
    required this.open,
    required this.inCart,
    required this.onAdd,
  });
  final LocationMenuItem entry;
  final bool open;
  final int inCart;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = entry.item;
    final enabled = open && entry.available;
    final muted = theme.colorScheme.onSurfaceVariant;
    return Opacity(
      opacity: entry.available ? 1 : 0.55,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: Key('menu-${item.id}'),
          onTap: enabled ? onAdd : null,
          child: Semantics(
            button: enabled,
            label:
                '${item.name}, ${entry.available ? formatCad(entry.priceCents) : 'sold out'}'
                '${inCart > 0 ? ', $inCart in your order' : ''}',
            excludeSemantics: true,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.name, style: theme.textTheme.titleMedium),
                        if (item.description != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            item.description!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: muted,
                            ),
                          ),
                        ],
                        const SizedBox(height: 10),
                        Text(
                          entry.available
                              ? formatCad(entry.priceCents)
                              : 'Sold out',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: entry.available ? SiteColors.ink : muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (enabled)
                    Badge(
                      isLabelVisible: inCart > 0,
                      label: Text('$inCart'),
                      backgroundColor: SiteColors.ink,
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: const BoxDecoration(
                          color: SiteColors.brand,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.add, color: Colors.white),
                      ),
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

/// The phone's sticky cart: what's in it and the button to check out.
class _CartBar extends StatelessWidget {
  const _CartBar({required this.cart, required this.onTap});
  final Cart cart;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: FilledButton(
            key: const Key('view-order'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(60),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              elevation: 4,
              shadowColor: SiteColors.brand.withValues(alpha: 0.5),
            ),
            onPressed: onTap,
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(SiteRadius.pill),
                  ),
                  child: Text('${cart.itemCount}'),
                ),
                const Expanded(
                  child: Text('View order', textAlign: TextAlign.center),
                ),
                Text(formatCad(cart.totals.totalCents)),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// On wide screens, the cart stays beside the menu.
class _SideCart extends StatelessWidget {
  const _SideCart({
    required this.store,
    required this.cart,
    required this.onCheckout,
    required this.onRemove,
  });
  final Storefront store;
  final Cart cart;
  final VoidCallback onCheckout;
  final void Function(String lineId, int qty) onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 24, 24, 24),
      child: Card(
        key: const Key('side-cart'),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Your order', style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                'Pickup at ${store.displayName}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              if (cart.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Column(
                    children: [
                      Icon(
                        Icons.shopping_bag_outlined,
                        size: 40,
                        color: theme.colorScheme.outline,
                        semanticLabel: 'Empty bag',
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Your order is empty.\nTap + on anything to add it.',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                )
              else ...[
                for (final l in cart.lines)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${l.qty}×', style: theme.textTheme.titleSmall),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(l.name),
                              if (l.modifiers.isNotEmpty)
                                Text(
                                  l.modifiers.map((m) => m.name).join(', '),
                                  style: theme.textTheme.bodySmall,
                                ),
                            ],
                          ),
                        ),
                        Text(formatCad(l.lineTotalCents)),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: 'Remove one ${l.name}',
                          onPressed: () => onRemove(l.lineId, l.qty - 1),
                          icon: const Icon(
                            Icons.remove_circle_outline,
                            size: 20,
                          ),
                        ),
                      ],
                    ),
                  ),
                const Divider(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: Text('Total', style: theme.textTheme.titleMedium),
                    ),
                    Text(
                      formatCad(cart.totals.totalCents),
                      style: theme.textTheme.titleMedium,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                FilledButton(
                  key: const Key('side-checkout'),
                  onPressed: store.open ? onCheckout : null,
                  child: const Text('Go to checkout'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Choose options, a note and how many, then add to the order.
class ItemSheet extends StatefulWidget {
  const ItemSheet({super.key, required this.entry, required this.lineId});
  final LocationMenuItem entry;
  final String lineId;

  @override
  State<ItemSheet> createState() => _ItemSheetState();
}

class _ItemSheetState extends State<ItemSheet> {
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
    final item = widget.entry.item;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(item.name, style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 4),
                  Text(
                    formatCad(widget.entry.priceCents),
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: SiteColors.brand,
                    ),
                  ),
                  if (item.description != null) ...[
                    const SizedBox(height: 8),
                    Text(item.description!, style: theme.textTheme.bodyLarge),
                  ],
                  for (final g in widget.entry.modifierGroups) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 20, bottom: 8),
                      child: Row(
                        children: [
                          Text(g.name, style: theme.textTheme.titleMedium),
                          const SizedBox(width: 8),
                          Text(
                            g.required
                                ? 'Required'
                                : g.maxSelect > 1
                                ? 'Up to ${g.maxSelect}'
                                : 'Optional',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: g.required
                                  ? SiteColors.brand
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
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
                  const SizedBox(height: 20),
                  TextField(
                    controller: _notes,
                    maxLength: 140,
                    decoration: const InputDecoration(
                      labelText: 'Special requests',
                      hintText: 'Less ice, no straw…',
                    ),
                  ),
                  if (_error != null) ErrorBanner(_error!),
                ],
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Row(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: theme.colorScheme.outlineVariant,
                      ),
                      borderRadius: BorderRadius.circular(SiteRadius.pill),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'One fewer',
                          onPressed: _qty > 1
                              ? () => setState(() => _qty--)
                              : null,
                          icon: const Icon(Icons.remove),
                        ),
                        Semantics(
                          label: 'Quantity $_qty',
                          excludeSemantics: true,
                          child: SizedBox(
                            width: 24,
                            child: Text(
                              '$_qty',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.titleMedium,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'One more',
                          onPressed: _qty < 20
                              ? () => setState(() => _qty++)
                              : null,
                          icon: const Icon(Icons.add),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      key: const Key('add'),
                      onPressed: () {
                        final built = _build(report: true);
                        if (built != null) Navigator.of(context).pop(built);
                      },
                      child: FittedBox(
                        child: Text(
                          line == null
                              ? 'Add to order'
                              : 'Add · ${formatCad(line.lineTotalCents)}',
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
