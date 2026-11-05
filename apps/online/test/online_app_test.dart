import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_online/src/app.dart';
import 'package:pos_shared/pos_shared.dart';
import 'package:pos_shared/testing.dart';

Storefront store({bool open = true, bool payOnline = false}) =>
    Storefront.fromMap({
      'slug': 'maple-cambridge',
      'brandName': 'Maple Tea',
      'locationName': 'Cambridge',
      'open': open,
      'closedReason': open ? null : 'This restaurant has paused online orders.',
      'payAtPickup': true,
      'payOnline': payOnline,
      'pickupLeadMinutes': 15,
      'taxRates': [
        {'id': 'hst', 'name': 'HST', 'rate': 0.13},
      ],
      'sections': [
        {
          'id': 'tea',
          'name': 'Tea',
          'items': [
            {
              'id': 'taro',
              'name': 'Taro milk tea',
              'description': 'With pearls',
              'priceCents': 625,
              'available': true,
              'taxable': true,
              'modifierGroups': [
                {
                  'id': 'size',
                  'name': 'Size',
                  'minSelect': 1,
                  'maxSelect': 1,
                  'options': [
                    {'id': 'm', 'name': 'Medium', 'priceDeltaCents': 0},
                    {'id': 'l', 'name': 'Large', 'priceDeltaCents': 100},
                  ],
                },
              ],
            },
            {
              'id': 'mango',
              'name': 'Mango slush',
              'priceCents': 550,
              'available': false,
              'taxable': true,
              'modifierGroups': [],
            },
          ],
        },
      ],
    });

Future<void> pumpSite(
  WidgetTester tester,
  FakeStorefrontBackend backend, {
  String route = '/maple-cambridge',
  List<Uri>? opened,
}) async {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    OnlineApp(
      backend: backend,
      initialRoute: route,
      openUrl: (u) async => opened?.add(u),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> addLargeTaro(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('menu-taro')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('pick-size-l')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('add')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a guest orders for pickup and pays at the counter', (
    tester,
  ) async {
    final backend = FakeStorefrontBackend(store());
    await pumpSite(tester, backend);
    expect(find.text('Maple Tea · Cambridge'), findsOneWidget);
    expect(find.text('Sold out'), findsOneWidget);

    await addLargeTaro(tester);
    await addLargeTaro(tester);
    // 2 × 7.25 = 14.50 + 1.89 HST
    expect(find.textContaining(r'$16.39'), findsOneWidget);
    await tester.tap(find.byKey(const Key('view-order')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('place-order')));
    await tester.pumpAndSettle();
    expect(find.text('We need a name to call out.'), findsOneWidget);
    expect(backend.placed, isEmpty);

    await tester.enterText(find.byKey(const Key('name')), 'Sam');
    await tester.enterText(find.byKey(const Key('phone')), '519-555-0100');
    await tester.tap(find.byKey(const Key('place-order')));
    await tester.pumpAndSettle();

    final placed = backend.placed.single;
    expect(placed['payment'], 'at_pickup');
    expect(placed['items'], [
      {
        'itemId': 'taro',
        'qty': 2,
        'modifiers': {
          'size': ['l'],
        },
        'notes': null,
      },
    ]);
    expect((placed['orderToken'] as String).length, 32);
    expect(placed.toString(), isNot(contains('priceCents')));

    expect(find.text('Order received'), findsOneWidget);
    expect(find.text('Your number is W-417.'), findsOneWidget);
    expect(find.text('2 × Taro milk tea (Large)'), findsOneWidget);
  });

  testWidgets('paying online sends the guest to Stripe Checkout', (
    tester,
  ) async {
    final backend = FakeStorefrontBackend(store(payOnline: true));
    final opened = <Uri>[];
    await pumpSite(tester, backend, opened: opened);
    await addLargeTaro(tester);
    await tester.tap(find.byKey(const Key('view-order')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pay now by card'));
    await tester.enterText(find.byKey(const Key('name')), 'Sam');
    await tester.tap(find.byKey(const Key('place-order')));
    await tester.pumpAndSettle();
    expect(backend.placed.single['payment'], 'online');
    expect(opened, [Uri.parse('https://checkout.stripe.test/web_1')]);
  });

  testWidgets('a paused store shows why and takes no orders', (tester) async {
    await pumpSite(tester, FakeStorefrontBackend(store(open: false)));
    expect(find.byKey(const Key('closed')), findsOneWidget);
    await tester.tap(find.byKey(const Key('menu-taro')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('add')), findsNothing);
  });

  testWidgets('the progress page follows the order', (tester) async {
    final backend = FakeStorefrontBackend(store())
      ..progress = OrderStatus.ready;
    await pumpSite(
      tester,
      backend,
      route: '/maple-cambridge/order/web_1?t=tok',
    );
    expect(find.text('Ready for pickup'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  test('pickup slots start after the lead time on the quarter hour', () {
    final slots = pickupSlots(DateTime(2026, 11, 5, 12, 2), 15);
    expect(slots.first, isNull);
    expect(slots[1], DateTime(2026, 11, 5, 12, 30));
    expect(slots[2], DateTime(2026, 11, 5, 12, 45));
  });
}
