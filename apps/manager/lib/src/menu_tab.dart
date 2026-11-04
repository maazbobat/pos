import 'package:flutter/material.dart';
import 'package:pos_shared/pos_shared.dart';

import 'app.dart';

/// The org menu as this store sells it. Owners edit items and categories;
/// managers set this store's prices; front-of-house roles mark items sold
/// out. Inactive items and categories still show here (greyed) so they can
/// be turned back on.
class MenuTab extends StatelessWidget {
  const MenuTab({super.key, required this.store});
  final StoreContext store;

  bool get _canEditMenu => store.isOwner && store.canWrite;
  bool get _canSetPrices => store.isManager && store.canWrite;
  bool get _canToggle =>
      store.canWrite &&
      (store.isManager ||
          store.role == Role.cashier ||
          store.role == Role.kitchen);

  @override
  Widget build(BuildContext context) {
    final data = BackendScope.of(context).data;
    final orgId = store.org.id;
    return StreamBuilder<List<MenuCategory>>(
      stream: data.menuCategories(orgId),
      builder: (context, cats) => StreamBuilder<List<MenuItem>>(
        stream: data.menuItems(orgId),
        builder: (context, items) => StreamBuilder<List<MenuOverride>>(
          stream: data.menuOverrides(orgId, store.location.id),
          builder: (context, overrides) {
            if (!cats.hasData || !items.hasData || !overrides.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final categories = [...cats.data!]
              ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
            final byId = {for (final o in overrides.data!) o.itemId: o};
            return Scaffold(
              floatingActionButton: _canEditMenu
                  ? FloatingActionButton.extended(
                      key: const Key('add-item'),
                      onPressed: () => categories.isEmpty
                          ? _editCategory(context, null)
                          : _editItem(context, null, categories),
                      icon: const Icon(Icons.add),
                      label: Text(
                        categories.isEmpty ? 'Add a category' : 'Add item',
                      ),
                    )
                  : null,
              body: categories.isEmpty
                  ? Center(
                      child: Text(
                        store.isOwner
                            ? 'Start with a category, like "Drinks".'
                            : 'No menu yet. The owner sets it up.',
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 88),
                      children: [
                        for (final cat in categories) ...[
                          ListTile(
                            title: Text(
                              cat.name,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            subtitle: cat.active ? null : const Text('Hidden'),
                            trailing: _canEditMenu
                                ? IconButton(
                                    tooltip: 'Edit category',
                                    icon: const Icon(Icons.edit_outlined),
                                    onPressed: () =>
                                        _editCategory(context, cat),
                                  )
                                : null,
                          ),
                          for (final item in [
                            ...items.data!.where((i) => i.categoryId == cat.id),
                          ]..sort((a, b) => a.sortOrder.compareTo(b.sortOrder)))
                            _itemTile(context, item, byId[item.id], categories),
                        ],
                        if (_canEditMenu)
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: OutlinedButton.icon(
                              key: const Key('add-category'),
                              onPressed: () => _editCategory(context, null),
                              icon: const Icon(
                                Icons.create_new_folder_outlined,
                              ),
                              label: const Text('Add category'),
                            ),
                          ),
                      ],
                    ),
            );
          },
        ),
      ),
    );
  }

  Widget _itemTile(
    BuildContext context,
    MenuItem item,
    MenuOverride? override,
    List<MenuCategory> categories,
  ) {
    final available = override?.available ?? true;
    final local = override?.priceCents;
    return ListTile(
      key: Key('menu-item-${item.id}'),
      enabled: item.active,
      title: Text(item.name),
      subtitle: Text(
        [
          local == null
              ? formatCad(item.priceCents)
              : '${formatCad(local)} here (org ${formatCad(item.priceCents)})',
          if (!item.active) 'Hidden',
          if (!available) 'Sold out',
        ].join(' · '),
      ),
      onTap: _canEditMenu ? () => _editItem(context, item, categories) : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_canSetPrices)
            IconButton(
              key: Key('local-price-${item.id}'),
              tooltip: 'Price at this store',
              icon: const Icon(Icons.sell_outlined),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => LocalPriceDialog(
                  store: store,
                  item: item,
                  current: override,
                ),
              ),
            ),
          if (_canToggle)
            Switch(
              key: Key('available-${item.id}'),
              value: available,
              onChanged: (v) => runWithFeedback(
                context,
                () => BackendScope.of(context).data.saveMenuOverride(
                  MenuOverride(
                    itemId: item.id,
                    orgId: store.org.id,
                    locationId: store.location.id,
                    available: v,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _editItem(
    BuildContext context,
    MenuItem? item,
    List<MenuCategory> categories,
  ) => showDialog<void>(
    context: context,
    builder: (_) =>
        MenuItemDialog(orgId: store.org.id, item: item, categories: categories),
  );

  void _editCategory(BuildContext context, MenuCategory? category) =>
      showDialog<void>(
        context: context,
        builder: (_) => CategoryDialog(orgId: store.org.id, category: category),
      );
}

class CategoryDialog extends StatefulWidget {
  const CategoryDialog({super.key, required this.orgId, this.category});
  final String orgId;
  final MenuCategory? category;

  @override
  State<CategoryDialog> createState() => _CategoryDialogState();
}

class _CategoryDialogState extends State<CategoryDialog> {
  late final _name = TextEditingController(text: widget.category?.name);
  late bool _active = widget.category?.active ?? true;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final c = widget.category;
    final ok = await runWithFeedback(
      context,
      () => BackendScope.of(context).data.saveMenuCategory(
        MenuCategory(
          id: c?.id ?? '',
          orgId: widget.orgId,
          name: _name.text.trim(),
          sortOrder:
              c?.sortOrder ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
          active: _active,
        ),
      ),
    );
    if (ok && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.category == null ? 'New category' : 'Edit category'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('category-name'),
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Show on the POS'),
            value: _active,
            onChanged: (v) => setState(() => _active = v),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

class MenuItemDialog extends StatefulWidget {
  const MenuItemDialog({
    super.key,
    required this.orgId,
    required this.categories,
    this.item,
  });
  final String orgId;
  final List<MenuCategory> categories;
  final MenuItem? item;

  @override
  State<MenuItemDialog> createState() => _MenuItemDialogState();
}

class _MenuItemDialogState extends State<MenuItemDialog> {
  late final _name = TextEditingController(text: widget.item?.name);
  late final _price = TextEditingController(
    text: widget.item == null
        ? ''
        : (widget.item!.priceCents / 100).toStringAsFixed(2),
  );
  late final _station = TextEditingController(
    text: widget.item?.kitchenStation,
  );
  late String _categoryId =
      widget.item?.categoryId ?? widget.categories.first.id;
  late bool _active = widget.item?.active ?? true;
  String? _priceError;

  @override
  void dispose() {
    _name.dispose();
    _price.dispose();
    _station.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final cents = parseCad(_price.text);
    if (cents == null) {
      setState(() => _priceError = 'Enter a price like 5.50');
      return;
    }
    setState(() => _priceError = null);
    final old = widget.item;
    final station = _station.text.trim();
    final ok = await runWithFeedback(
      context,
      () => BackendScope.of(context).data.saveMenuItem(
        MenuItem(
          id: old?.id ?? '',
          orgId: widget.orgId,
          name: _name.text.trim(),
          categoryId: _categoryId,
          priceCents: cents,
          description: old?.description,
          modifierGroupIds: old?.modifierGroupIds ?? const [],
          taxable: old?.taxable ?? true,
          kitchenStation: station.isEmpty ? null : station,
          active: _active,
          sortOrder:
              old?.sortOrder ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
          imagePath: old?.imagePath,
        ),
      ),
    );
    if (ok && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.item == null ? 'New item' : 'Edit item'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('item-name'),
              controller: _name,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            DropdownButtonFormField<String>(
              initialValue: _categoryId,
              decoration: const InputDecoration(labelText: 'Category'),
              items: [
                for (final c in widget.categories)
                  DropdownMenuItem(value: c.id, child: Text(c.name)),
              ],
              onChanged: (v) => setState(() => _categoryId = v!),
            ),
            TextField(
              key: const Key('item-price'),
              controller: _price,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: 'Price',
                prefixText: r'$ ',
                errorText: _priceError,
              ),
            ),
            TextField(
              key: const Key('item-station'),
              controller: _station,
              decoration: const InputDecoration(
                labelText: 'Kitchen station (optional)',
                hintText: 'bar, grill…',
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Show on the POS'),
              value: _active,
              onChanged: (v) => setState(() => _active = v),
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
          key: const Key('save-item'),
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class LocalPriceDialog extends StatefulWidget {
  const LocalPriceDialog({
    super.key,
    required this.store,
    required this.item,
    this.current,
  });
  final StoreContext store;
  final MenuItem item;
  final MenuOverride? current;

  @override
  State<LocalPriceDialog> createState() => _LocalPriceDialogState();
}

class _LocalPriceDialogState extends State<LocalPriceDialog> {
  late final _price = TextEditingController(
    text: widget.current?.priceCents == null
        ? ''
        : (widget.current!.priceCents! / 100).toStringAsFixed(2),
  );
  String? _error;

  @override
  void dispose() {
    _price.dispose();
    super.dispose();
  }

  Future<void> _save({required bool reset}) async {
    final cents = reset ? null : parseCad(_price.text);
    if (!reset && cents == null) {
      setState(() => _error = 'Enter a price like 5.50');
      return;
    }
    final store = widget.store;
    final ok = await runWithFeedback(
      context,
      () => BackendScope.of(context).data.saveMenuOverride(
        MenuOverride(
          itemId: widget.item.id,
          orgId: store.org.id,
          locationId: store.location.id,
          available: widget.current?.available ?? true,
          priceCents: cents,
        ),
        resetPrice: reset,
      ),
    );
    if (ok && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${widget.item.name} at ${widget.store.location.name}'),
      content: TextField(
        key: const Key('local-price'),
        controller: _price,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: 'Price here',
          prefixText: r'$ ',
          helperText: 'Org price is ${formatCad(widget.item.priceCents)}',
          errorText: _error,
        ),
      ),
      actions: [
        if (widget.current?.priceCents != null)
          TextButton(
            onPressed: () => _save(reset: true),
            child: const Text('Use org price'),
          ),
        FilledButton(
          key: const Key('save-local-price'),
          onPressed: () => _save(reset: false),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
