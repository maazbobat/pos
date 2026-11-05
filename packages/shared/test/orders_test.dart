import 'dart:convert';
import 'dart:io';

import 'package:pos_shared/pos_shared.dart';
import 'package:test/test.dart';

void main() {
  group('pricing matches the server', () {
    final cases =
        (jsonDecode(File('test/fixtures/pricing_cases.json').readAsStringSync())
                as Map)['cases']
            as List;
    for (final c in cases.cast<Map<String, Object?>>()) {
      test(c['name'], () {
        final totals = priceOrder(
          lines: [
            for (final l in (c['lines'] as List).cast<List>())
              PricedLine(lineTotalCents: l[0] as int, taxable: l[1] as bool),
          ],
          discounts: [
            for (final d in (c['discounts'] as List).cast<Map>())
              Discount.fromMap(Map<String, Object?>.from(d)),
          ],
          taxRates: [
            for (final r in (c['rates'] as List).cast<Map>())
              TaxRate.fromMap(Map<String, Object?>.from(r)),
          ],
        );
        final expected = c['expect'] as Map;
        expect(totals.subtotalCents, expected['subtotalCents']);
        expect(totals.discountCents, expected['discountCents']);
        expect(totals.taxCents, expected['taxCents']);
        expect(totals.totalCents, expected['totalCents']);
        expect([
          for (final t in totals.taxes) t.cents,
        ], expected['taxCents_each']);
      });
    }
  });

  group('cash', () {
    test('change and quick amounts', () {
      expect(changeDue(1243, 2000), 757);
      expect(changeDue(1243, 1000), isNull);
      expect(quickCashAmounts(1243), [1243, 1500, 2000, 5000]);
      expect(quickCashAmounts(2000), [2000, 5000, 10000]);
    });
  });

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
  const toppings = ModifierGroup(
    id: 'top',
    orgId: 'org-a',
    name: 'Toppings',
    maxSelect: 2,
    options: [
      ModifierOption(id: 'pearl', name: 'Pearls', priceDeltaCents: 75),
      ModifierOption(id: 'jelly', name: 'Jelly', priceDeltaCents: 50),
    ],
  );
  const entry = LocationMenuItem(
    item: MenuItem(
      id: 'taro',
      orgId: 'org-a',
      name: 'Taro milk tea',
      categoryId: 'tea',
      priceCents: 600,
      kitchenStation: 'bar',
    ),
    priceCents: 625,
    available: true,
    modifierGroups: [size, toppings],
  );

  group('order lines', () {
    test('copy the store price and chosen options', () {
      final line = OrderLine.fromMenu(
        lineId: 'l1',
        entry: entry,
        selections: {
          'size': ['l'],
          'top': ['pearl', 'jelly'],
        },
        qty: 2,
        notes: '  less ice ',
      );
      expect(line.eachCents, 625 + 100 + 75 + 50);
      expect(line.lineTotalCents, 2 * 850);
      expect(line.notes, 'less ice');
      expect(line.kitchenStation, 'bar');
      expect(line.toMap()['lineTotalCents'], 1700);
      final back = OrderLine.fromMap(line.toMap());
      expect(back.modifiers.map((m) => m.name), ['Large', 'Pearls', 'Jelly']);
      expect(back.lineTotalCents, 1700);
    });

    test('enforce required groups, limits and sold out', () {
      expect(
        () => OrderLine.fromMenu(lineId: 'l', entry: entry, selections: {}),
        throwsA(isA<MenuValidationError>()),
      );
      expect(
        () => OrderLine.fromMenu(
          lineId: 'l',
          entry: entry,
          selections: {
            'size': ['m'],
            'top': ['pearl', 'pearl'],
          },
        ),
        throwsA(isA<MenuValidationError>()),
      );
      expect(
        () => OrderLine.fromMenu(
          lineId: 'l',
          entry: LocationMenuItem(
            item: entry.item,
            priceCents: 625,
            available: false,
            modifierGroups: const [],
          ),
          selections: {},
        ),
        throwsA(isA<MenuValidationError>()),
      );
    });
  });

  OrderLine medium(String id) => OrderLine.fromMenu(
    lineId: id,
    entry: entry,
    selections: {
      'size': ['m'],
    },
  );

  group('cart', () {
    test('merges identical lines and prices with tax and discount', () {
      var cart = const Cart(
        taxRates: [TaxRate(id: 'hst', name: 'HST', rate: 0.13)],
      );
      cart = cart.add(medium('a')).add(medium('b'));
      expect(cart.lines, hasLength(1));
      expect(cart.itemCount, 2);
      expect(cart.totals.subtotalCents, 1250);
      expect(cart.totals.taxCents, 163);
      cart = cart.withDiscount(
        const Discount(type: DiscountType.percent, value: 10),
      );
      expect(cart.totals.discountCents, 125);
      expect(cart.totals.totalCents, 1250 - 125 + 146);
      cart = cart.setQty('a', 0);
      expect(cart.isEmpty, isTrue);
      expect(cart.totals.totalCents, 0);
    });
  });

  group('orders', () {
    test('read back from Firestore data', () {
      final order = Order.fromMap('o1', {
        'orgId': 'org-a',
        'locationId': 'cambridge',
        'source': 'online',
        'ticket': 'W-417',
        'status': 'awaiting_payment',
        'paymentStatus': 'paid',
        'fulfillment': 'pickup',
        'items': [medium('l1').toMap()],
        'totals': {
          'subtotalCents': 625,
          'discountCents': 0,
          'taxCents': 81,
          'totalCents': 706,
        },
        'customer': {'name': 'Sam', 'phone': '5195550100'},
      });
      expect(order.source, OrderSource.online);
      expect(order.status, OrderStatus.awaitingPayment);
      expect(order.status.isActive, isFalse);
      expect(order.fulfillment, Fulfillment.pickup);
      expect(order.customer!.name, 'Sam');
      expect(order.totals.totalCents, 706);
      expect(order.itemCount, 1);
    });

    test('status steps and ticket numbers', () {
      expect(OrderStatus.newOrder.next, OrderStatus.inProgress);
      expect(OrderStatus.ready.next, OrderStatus.completed);
      expect(OrderStatus.completed.next, isNull);
      expect(OrderStatus.fromWire('in_progress'), OrderStatus.inProgress);
      final ticket = ticketFor('Xk29fa0QmZ');
      expect(ticket, hasLength(3));
      expect(ticketFor('Xk29fa0QmZ'), ticket);
    });
  });
}
