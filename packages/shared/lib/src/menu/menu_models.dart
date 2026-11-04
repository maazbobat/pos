import 'money.dart';

/// A problem with a menu document, caught before it is written. The rules
/// reject the same shapes server-side; this gives the manager a readable
/// message instead of a permission error.
class MenuValidationError implements Exception {
  const MenuValidationError(this.message);
  final String message;
  @override
  String toString() => message;
}

void _check(bool ok, String message) {
  if (!ok) throw MenuValidationError(message);
}

/// `orgs/{orgId}/menuCategories/{id}`
class MenuCategory {
  const MenuCategory({
    required this.id,
    required this.orgId,
    required this.name,
    this.sortOrder = 0,
    this.active = true,
  });

  final String id;
  final String orgId;
  final String name;
  final int sortOrder;
  final bool active;

  void validate() {
    _check(
      name.trim().isNotEmpty && name.length <= 60,
      'A category name is 1 to 60 characters.',
    );
  }

  factory MenuCategory.fromMap(String id, Map<String, Object?> data) =>
      MenuCategory(
        id: id,
        orgId: data['orgId'] as String,
        name: data['name'] as String? ?? '',
        sortOrder: (data['sortOrder'] as num?)?.toInt() ?? 0,
        active: data['active'] as bool? ?? true,
      );

  Map<String, Object?> toMap() => {
    'orgId': orgId,
    'name': name.trim(),
    'sortOrder': sortOrder,
    'active': active,
  };
}

/// `orgs/{orgId}/menuItems/{id}`: the org-wide (franchise) price and recipe.
/// Locations override availability and price with [MenuOverride].
class MenuItem {
  const MenuItem({
    required this.id,
    required this.orgId,
    required this.name,
    required this.categoryId,
    required this.priceCents,
    this.description,
    this.modifierGroupIds = const [],
    this.taxable = true,
    this.kitchenStation,
    this.active = true,
    this.sortOrder = 0,
    this.imagePath,
  });

  final String id;
  final String orgId;
  final String name;
  final String? description;
  final String categoryId;
  final int priceCents;
  final List<String> modifierGroupIds;

  /// Restaurant food and drink is taxable in every province; false is for
  /// rare exempt items and needs accountant sign-off.
  final bool taxable;

  /// Which kitchen display gets this item, for example `bar` or `grill`.
  final String? kitchenStation;
  final bool active;
  final int sortOrder;

  /// A Cloud Storage path, not a URL.
  final String? imagePath;

  void validate() {
    _check(
      name.trim().isNotEmpty && name.length <= 100,
      'An item name is 1 to 100 characters.',
    );
    _check(
      description == null || description!.length <= 500,
      'Descriptions are at most 500 characters.',
    );
    _check(categoryId.isNotEmpty, 'Pick a category.');
    _check(
      priceCents >= 0 && priceCents <= maxPriceCents,
      'Prices are between \$0.00 and ${formatCad(maxPriceCents)}.',
    );
    _check(
      modifierGroupIds.length <= 20,
      'An item can have at most 20 modifier groups.',
    );
    _check(
      modifierGroupIds.toSet().length == modifierGroupIds.length,
      'A modifier group is listed twice.',
    );
    _check(
      kitchenStation == null || kitchenStation!.length <= 40,
      'Kitchen station names are at most 40 characters.',
    );
  }

  factory MenuItem.fromMap(String id, Map<String, Object?> data) => MenuItem(
    id: id,
    orgId: data['orgId'] as String,
    name: data['name'] as String? ?? '',
    description: data['description'] as String?,
    categoryId: data['categoryId'] as String? ?? '',
    priceCents: (data['priceCents'] as num?)?.toInt() ?? 0,
    modifierGroupIds: [
      for (final id in (data['modifierGroupIds'] as List?) ?? const [])
        id as String,
    ],
    taxable: data['taxable'] as bool? ?? true,
    kitchenStation: data['kitchenStation'] as String?,
    active: data['active'] as bool? ?? true,
    sortOrder: (data['sortOrder'] as num?)?.toInt() ?? 0,
    imagePath: data['imagePath'] as String?,
  );

  Map<String, Object?> toMap() => {
    'orgId': orgId,
    'name': name.trim(),
    'description': description,
    'categoryId': categoryId,
    'priceCents': priceCents,
    'modifierGroupIds': modifierGroupIds,
    'taxable': taxable,
    'kitchenStation': kitchenStation,
    'active': active,
    'sortOrder': sortOrder,
    'imagePath': imagePath,
  };
}

class ModifierOption {
  const ModifierOption({
    required this.id,
    required this.name,
    this.priceDeltaCents = 0,
  });

  final String id;
  final String name;

  /// Added to the item price when chosen. Never negative: a cheaper option
  /// is a discount, which is recorded as one.
  final int priceDeltaCents;

  factory ModifierOption.fromMap(Map<String, Object?> data) => ModifierOption(
    id: data['id'] as String,
    name: data['name'] as String? ?? '',
    priceDeltaCents: (data['priceDeltaCents'] as num?)?.toInt() ?? 0,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'name': name.trim(),
    'priceDeltaCents': priceDeltaCents,
  };
}

/// `orgs/{orgId}/modifierGroups/{id}`: toppings, sizes, sweetness and so on.
/// The customer picks between [minSelect] and [maxSelect] options.
class ModifierGroup {
  const ModifierGroup({
    required this.id,
    required this.orgId,
    required this.name,
    required this.options,
    this.minSelect = 0,
    this.maxSelect = 1,
  });

  final String id;
  final String orgId;
  final String name;
  final int minSelect;
  final int maxSelect;
  final List<ModifierOption> options;

  bool get required => minSelect > 0;

  void validate() {
    _check(
      name.trim().isNotEmpty && name.length <= 60,
      'A modifier group name is 1 to 60 characters.',
    );
    _check(
      options.isNotEmpty && options.length <= 50,
      'A modifier group has 1 to 50 options.',
    );
    _check(
      minSelect >= 0 && maxSelect >= 1 && minSelect <= maxSelect,
      'The minimum can\'t be more than the maximum.',
    );
    _check(
      maxSelect <= options.length,
      'The maximum can\'t be more than the number of options.',
    );
    final ids = <String>{};
    for (final option in options) {
      _check(
        option.id.isNotEmpty && ids.add(option.id),
        'Each option needs its own ID.',
      );
      _check(
        option.name.trim().isNotEmpty && option.name.length <= 60,
        'An option name is 1 to 60 characters.',
      );
      _check(
        option.priceDeltaCents >= 0 && option.priceDeltaCents <= maxPriceCents,
        'Option prices can\'t be negative.',
      );
    }
  }

  /// Checks a customer's picks against this group. Returns the added price.
  int priceForSelection(List<String> optionIds) {
    _check(
      optionIds.length >= minSelect && optionIds.length <= maxSelect,
      minSelect == maxSelect
          ? 'Pick $minSelect for $name.'
          : 'Pick $minSelect to $maxSelect for $name.',
    );
    _check(
      optionIds.toSet().length == optionIds.length,
      'An option was picked twice.',
    );
    var total = 0;
    for (final id in optionIds) {
      final option = options.where((o) => o.id == id).firstOrNull;
      _check(option != null, 'Unknown option for $name.');
      total += option!.priceDeltaCents;
    }
    return total;
  }

  factory ModifierGroup.fromMap(String id, Map<String, Object?> data) =>
      ModifierGroup(
        id: id,
        orgId: data['orgId'] as String,
        name: data['name'] as String? ?? '',
        minSelect: (data['minSelect'] as num?)?.toInt() ?? 0,
        maxSelect: (data['maxSelect'] as num?)?.toInt() ?? 1,
        options: [
          for (final o in (data['options'] as List?) ?? const [])
            ModifierOption.fromMap(Map<String, Object?>.from(o as Map)),
        ],
      );

  Map<String, Object?> toMap() => {
    'orgId': orgId,
    'name': name.trim(),
    'minSelect': minSelect,
    'maxSelect': maxSelect,
    'options': [for (final o in options) o.toMap()],
  };
}

/// `orgs/{orgId}/locations/{locationId}/menuOverrides/{itemId}`: whether an
/// item is sold out at this store, and its local price if it differs.
class MenuOverride {
  const MenuOverride({
    required this.itemId,
    required this.orgId,
    required this.locationId,
    this.available = true,
    this.priceCents,
  });

  final String itemId;
  final String orgId;
  final String locationId;
  final bool available;

  /// Null means the org price applies here.
  final int? priceCents;

  factory MenuOverride.fromMap(String itemId, Map<String, Object?> data) =>
      MenuOverride(
        itemId: itemId,
        orgId: data['orgId'] as String,
        locationId: data['locationId'] as String,
        available: data['available'] as bool? ?? true,
        priceCents: (data['priceCents'] as num?)?.toInt(),
      );

  Map<String, Object?> toMap() => {
    'orgId': orgId,
    'locationId': locationId,
    'itemId': itemId,
    'available': available,
    'priceCents': priceCents,
  };
}
