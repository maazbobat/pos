import 'package:pos_shared/pos_shared.dart';
import 'package:test/test.dart';

void main() {
  group('money', () {
    test('formats cents as CAD', () {
      expect(formatCad(550), r'$5.50');
      expect(formatCad(5), r'$0.05');
      expect(formatCad(-125), r'-$1.25');
      expect(formatCad(123456789), r'$1,234,567.89');
    });

    test('parses typed prices without floating point', () {
      expect(parseCad('5'), 500);
      expect(parseCad('5.5'), 550);
      expect(parseCad(r' $1,250.05 '), 125005);
      expect(parseCad('0.10'), 10);
      for (final bad in ['', 'abc', '5.555', '-1', '1e3', '100001']) {
        expect(parseCad(bad), isNull, reason: bad);
      }
    });
  });

  const item = MenuItem(
    id: 'taro',
    orgId: 'org-a',
    name: 'Taro milk tea',
    categoryId: 'tea',
    priceCents: 625,
    modifierGroupIds: ['size', 'gone'],
  );
  const size = ModifierGroup(
    id: 'size',
    orgId: 'org-a',
    name: 'Size',
    minSelect: 1,
    maxSelect: 1,
    options: [
      ModifierOption(id: 'm', name: 'Medium'),
      ModifierOption(id: 'l', name: 'Large', priceDeltaCents: 100),
    ],
  );

  group('validation', () {
    test('accepts a well-formed item and group', () {
      item.validate();
      size.validate();
    });

    test('rejects bad items', () {
      for (final bad in [
        MenuItem.fromMap('x', {...item.toMap(), 'name': ' '}),
        MenuItem.fromMap('x', {...item.toMap(), 'priceCents': -1}),
        MenuItem.fromMap('x', {...item.toMap(), 'categoryId': ''}),
        MenuItem.fromMap('x', {
          ...item.toMap(),
          'modifierGroupIds': ['a', 'a'],
        }),
      ]) {
        expect(bad.validate, throwsA(isA<MenuValidationError>()));
      }
    });

    test('rejects bad modifier groups', () {
      for (final bad in [
        {'minSelect': 2, 'maxSelect': 1},
        {'maxSelect': 3},
        {'options': <Object>[]},
        {
          'options': [
            {'id': 'a', 'name': 'A'},
            {'id': 'a', 'name': 'B'},
          ],
        },
        {
          'options': [
            {'id': 'a', 'name': 'A', 'priceDeltaCents': -50},
          ],
        },
      ]) {
        final group = ModifierGroup.fromMap('g', {...size.toMap(), ...bad});
        expect(
          group.validate,
          throwsA(isA<MenuValidationError>()),
          reason: '$bad',
        );
      }
    });

    test('prices a customer selection and enforces min/max', () {
      expect(size.priceForSelection(['l']), 100);
      expect(size.priceForSelection(['m']), 0);
      expect(
        () => size.priceForSelection([]),
        throwsA(isA<MenuValidationError>()),
      );
      expect(
        () => size.priceForSelection(['m', 'l']),
        throwsA(isA<MenuValidationError>()),
      );
      expect(
        () => size.priceForSelection(['xl']),
        throwsA(isA<MenuValidationError>()),
      );
    });

    test('round-trips through maps', () {
      expect(MenuItem.fromMap('taro', item.toMap()).toMap(), item.toMap());
      expect(ModifierGroup.fromMap('size', size.toMap()).toMap(), size.toMap());
    });
  });

  group('buildLocationMenu', () {
    final menu = buildLocationMenu(
      categories: const [
        MenuCategory(
          id: 'snacks',
          orgId: 'org-a',
          name: 'Snacks',
          sortOrder: 2,
        ),
        MenuCategory(id: 'tea', orgId: 'org-a', name: 'Tea', sortOrder: 1),
        MenuCategory(id: 'old', orgId: 'org-a', name: 'Old', active: false),
      ],
      items: [
        item,
        const MenuItem(
          id: 'jasmine',
          orgId: 'org-a',
          name: 'Jasmine',
          categoryId: 'tea',
          priceCents: 500,
        ),
        const MenuItem(
          id: 'fries',
          orgId: 'org-a',
          name: 'Fries',
          categoryId: 'snacks',
          priceCents: 400,
        ),
        const MenuItem(
          id: 'retired',
          orgId: 'org-a',
          name: 'Retired',
          categoryId: 'tea',
          priceCents: 1,
          active: false,
        ),
        const MenuItem(
          id: 'orphan',
          orgId: 'org-a',
          name: 'Orphan',
          categoryId: 'old',
          priceCents: 1,
        ),
      ],
      modifierGroups: const [size],
      overrides: const [
        MenuOverride(
          itemId: 'taro',
          orgId: 'org-a',
          locationId: 'cambridge',
          priceCents: 675,
        ),
        MenuOverride(
          itemId: 'fries',
          orgId: 'org-a',
          locationId: 'cambridge',
          available: false,
        ),
      ],
    );

    test('orders active categories and items and drops the rest', () {
      expect(menu.map((s) => s.category.id), ['tea', 'snacks']);
      expect(menu.first.items.map((i) => i.item.id), ['jasmine', 'taro']);
    });

    test('applies local prices and sold-out flags', () {
      final taro = menu.first.items.last;
      expect(taro.priceCents, 675);
      expect(taro.hasLocalPrice, isTrue);
      expect(menu.first.items.first.priceCents, 500);
      expect(menu.last.items.single.available, isFalse);
    });

    test('skips modifier groups that no longer exist', () {
      expect(menu.first.items.last.modifierGroups.map((g) => g.id), ['size']);
    });
  });
}
