import 'menu_models.dart';

/// An item as it should appear at one store: org data plus that store's
/// override.
class LocationMenuItem {
  const LocationMenuItem({
    required this.item,
    required this.priceCents,
    required this.available,
    required this.modifierGroups,
  });

  final MenuItem item;

  /// The store's price if it sets one, otherwise the org price.
  final int priceCents;

  /// False when the store marked it sold out. Inactive items are left out.
  final bool available;
  final List<ModifierGroup> modifierGroups;

  bool get hasLocalPrice => priceCents != item.priceCents;
}

class LocationMenuSection {
  const LocationMenuSection({required this.category, required this.items});
  final MenuCategory category;
  final List<LocationMenuItem> items;
}

/// Builds what the POS shows at one location: active categories and items in
/// sort order, local prices and sold-out flags applied. Items whose category
/// is missing or inactive are left out, and modifier groups that no longer
/// exist are skipped, so a half-finished menu edit can't break the till.
List<LocationMenuSection> buildLocationMenu({
  required List<MenuCategory> categories,
  required List<MenuItem> items,
  required List<ModifierGroup> modifierGroups,
  required List<MenuOverride> overrides,
}) {
  final groupsById = {for (final g in modifierGroups) g.id: g};
  final overridesById = {for (final o in overrides) o.itemId: o};
  int byOrder(int a, int b) => a.compareTo(b);

  final sections = <LocationMenuSection>[];
  final activeCategories = categories.where((c) => c.active).toList()
    ..sort((a, b) {
      final order = byOrder(a.sortOrder, b.sortOrder);
      return order != 0 ? order : a.name.compareTo(b.name);
    });

  for (final category in activeCategories) {
    final inCategory =
        items.where((i) => i.active && i.categoryId == category.id).toList()
          ..sort((a, b) {
            final order = byOrder(a.sortOrder, b.sortOrder);
            return order != 0 ? order : a.name.compareTo(b.name);
          });
    if (inCategory.isEmpty) continue;
    sections.add(
      LocationMenuSection(
        category: category,
        items: [
          for (final item in inCategory)
            LocationMenuItem(
              item: item,
              priceCents: overridesById[item.id]?.priceCents ?? item.priceCents,
              available: overridesById[item.id]?.available ?? true,
              modifierGroups: [
                for (final id in item.modifierGroupIds) ?groupsById[id],
              ],
            ),
        ],
      ),
    );
  }
  return sections;
}
