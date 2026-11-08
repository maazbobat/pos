import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_online/src/analytics.dart';
import 'package:pos_online/src/app.dart';
import 'package:pos_shared/pos_shared.dart';
import 'package:pos_shared/testing.dart';

Storefront store({
  bool open = true,
  bool payOnline = false,
  String? address = '12 Main St, Cambridge, ON N1R 1A1',
  String? phone = '519-555-0199',
}) => Storefront.fromMap({
  'slug': 'maple-cambridge',
  'brandName': 'Maple Tea',
  'locationName': 'Cambridge',
  'address': address,
  'province': 'ON',
  'phone': phone,
  'email': null,
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
  Size size = const Size(800, 1400),
  AnalyticsSink? sink,
  ConsentController? consent,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    OnlineApp(
      key: UniqueKey(),
      backend: backend,
      initialRoute: route,
      openUrl: (u) async => opened?.add(u),
      analyticsSink: sink,
      consent:
          consent ?? ConsentController(read: (_) => null, write: (_, _) {}),
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
    expect(find.text('Maple Tea · Cambridge'), findsWidgets);
    expect(find.text('Sold out'), findsOneWidget);
    // The address and the way to start are on the first screen.
    expect(find.byKey(const Key('store-address')), findsOneWidget);
    expect(find.byKey(const Key('store-phone')), findsWidgets);
    expect(find.byKey(const Key('start-order')), findsOneWidget);

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
    expect(find.byKey(const Key('thank-you')), findsOneWidget);
    expect(find.text('Your number is W-417.'), findsOneWidget);
    expect(find.text('2 × Taro milk tea (Large)'), findsOneWidget);
    expect(find.text('12 Main St, Cambridge, ON N1R 1A1'), findsOneWidget);

    await tester.tap(find.byKey(const Key('order-again')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('start-order')), findsOneWidget);
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

  testWidgets('checkout checks the phone and email and says what is wrong', (
    tester,
  ) async {
    final backend = FakeStorefrontBackend(store());
    await pumpSite(tester, backend);
    await addLargeTaro(tester);
    await tester.tap(find.byKey(const Key('view-order')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('name')), 'Sam');
    await tester.enterText(find.byKey(const Key('phone')), '555');
    await tester.enterText(find.byKey(const Key('email')), 'sam@');
    await tester.tap(find.byKey(const Key('place-order')));
    await tester.pumpAndSettle();
    expect(find.textContaining('phone number with area code'), findsOneWidget);
    expect(find.textContaining('Enter an email address'), findsOneWidget);
    expect(find.text('Check the highlighted fields.'), findsOneWidget);
    expect(backend.placed, isEmpty);

    // Fixing a field clears its error as the guest types.
    await tester.enterText(find.byKey(const Key('phone')), '(519) 555-0100');
    await tester.pumpAndSettle();
    expect(find.textContaining('phone number with area code'), findsNothing);
  });

  testWidgets(
    'placing an order shows progress, and server errors in a banner',
    (tester) async {
      final backend = FakeStorefrontBackend(store())
        ..holdPlaceOrder = Completer<void>();
      await pumpSite(tester, backend);
      await addLargeTaro(tester);
      await tester.tap(find.byKey(const Key('view-order')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('name')), 'Sam');
      await tester.tap(find.byKey(const Key('place-order')));
      await tester.pump();
      expect(find.text('Placing your order…'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.byKey(const Key('place-order')),
      );
      expect(button.onPressed, isNull);
      backend.holdPlaceOrder!.completeError(
        const BackendException('failed-precondition', 'Taro is sold out.'),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('checkout-error')), findsOneWidget);
      expect(find.text('Taro is sold out.'), findsOneWidget);
    },
  );

  testWidgets('a store that fails to load offers to try again', (tester) async {
    final backend = FakeStorefrontBackend(store())
      ..failNext = Exception('offline');
    await pumpSite(tester, backend);
    expect(find.textContaining('Check your connection'), findsOneWidget);
    await tester.tap(find.byKey(const Key('retry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('menu-taro')), findsOneWidget);
  });

  testWidgets('shows a loading state while the menu loads', (tester) async {
    final backend = FakeStorefrontBackend(store());
    tester.view.physicalSize = const Size(800, 1400);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      OnlineApp(
        backend: backend,
        initialRoute: '/maple-cambridge',
        consent: ConsentController(read: (_) => null, write: (_, _) {}),
      ),
    );
    expect(find.text('Loading the menu…'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('Loading the menu…'), findsNothing);
  });

  testWidgets('unknown stores and paths get the not-found page', (
    tester,
  ) async {
    for (final route in ['/nobody-here', '/maple-cambridge/menu', '/a/b/c/d']) {
      await pumpSite(tester, FakeStorefrontBackend(store()), route: route);
      expect(find.byKey(const Key('not-found')), findsOneWidget, reason: route);
    }
  });

  testWidgets('no address on file means none is shown', (tester) async {
    await pumpSite(
      tester,
      FakeStorefrontBackend(store(address: null, phone: null)),
    );
    expect(find.byKey(const Key('store-address')), findsNothing);
    expect(find.byKey(const Key('store-phone')), findsNothing);
  });

  testWidgets("the store's privacy policy names it and is marked a draft", (
    tester,
  ) async {
    await pumpSite(
      tester,
      FakeStorefrontBackend(store()),
      route: '/maple-cambridge/privacy',
    );
    expect(find.byKey(const Key('legal-draft')), findsOneWidget);
    expect(
      find.textContaining('belongs to Maple Tea · Cambridge'),
      findsOneWidget,
    );
    expect(find.textContaining('12 Main St, Cambridge'), findsWidgets);

    await pumpSite(
      tester,
      FakeStorefrontBackend(store()),
      route: '/maple-cambridge/terms',
    );
    expect(find.textContaining('laws of Ontario'), findsOneWidget);

    await pumpSite(tester, FakeStorefrontBackend(store()), route: '/privacy');
    expect(find.text('Privacy policy'), findsWidgets);
    expect(find.textContaining('the restaurant you order from'), findsWidgets);
  });

  testWidgets('the footer links to the legal pages', (tester) async {
    await pumpSite(tester, FakeStorefrontBackend(store()));
    await tester.scrollUntilVisible(find.byKey(const Key('footer-terms')), 200);
    await tester.tap(find.byKey(const Key('footer-terms')));
    await tester.pumpAndSettle();
    expect(find.text('Terms of use for Maple Tea · Cambridge'), findsOneWidget);
  });

  group('cookies and analytics', () {
    testWidgets('no analytics built in means no banner', (tester) async {
      await pumpSite(tester, FakeStorefrontBackend(store()));
      expect(find.byKey(const Key('cookie-banner')), findsNothing);
      expect(find.byKey(const Key('footer-cookies')), findsNothing);
    });

    testWidgets('nothing is sent until the guest accepts', (tester) async {
      final sink = RecordingSink();
      final saved = <String, String>{};
      final consent = ConsentController(
        read: (k) => saved[k],
        write: (k, v) => saved[k] = v,
      );
      await pumpSite(
        tester,
        FakeStorefrontBackend(store()),
        sink: sink,
        consent: consent,
      );
      expect(find.byKey(const Key('cookie-banner')), findsOneWidget);
      await addLargeTaro(tester);
      expect(sink.started, 0);
      expect(sink.events, isEmpty);

      await tester.tap(find.byKey(const Key('cookies-accept')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('cookie-banner')), findsNothing);
      expect(saved[ConsentController.storageKey], 'granted');
      expect(sink.started, 1);
      expect(sink.granted, isTrue);
      expect(sink.events, ['page_view']);
      await addLargeTaro(tester);
      expect(sink.events, contains('add_to_cart'));

      // Cookie settings brings the choice back, and declining stops events.
      await tester.scrollUntilVisible(
        find.byKey(const Key('footer-cookies')),
        200,
      );
      await tester.tap(find.byKey(const Key('footer-cookies')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cookies-decline')));
      await tester.pumpAndSettle();
      expect(sink.granted, isFalse);
      sink.events.clear();
      await tester.scrollUntilVisible(find.byKey(const Key('menu-taro')), -200);
      await addLargeTaro(tester);
      expect(sink.events, isEmpty);
    });

    testWidgets('a guest who declined before is not asked again', (
      tester,
    ) async {
      final sink = RecordingSink();
      await pumpSite(
        tester,
        FakeStorefrontBackend(store()),
        sink: sink,
        consent: ConsentController(read: (_) => 'denied', write: (_, _) {}),
      );
      expect(find.byKey(const Key('cookie-banner')), findsNothing);
      expect(sink.started, 0);
    });
  });

  group('on a small phone', () {
    const phone = Size(320, 640);
    testWidgets('store, checkout and thank-you pages fit', (tester) async {
      final backend = FakeStorefrontBackend(store(payOnline: true));
      await pumpSite(tester, backend, size: phone);
      expect(find.byKey(const Key('start-order')), findsOneWidget);
      await addLargeTaro(tester);
      expect(find.byKey(const Key('view-order')), findsOneWidget);
      await tester.tap(find.byKey(const Key('view-order')));
      await tester.pumpAndSettle();
      // The order button stays on screen without scrolling.
      expect(
        tester.getRect(find.byKey(const Key('place-order'))).bottom,
        lessThanOrEqualTo(phone.height),
      );
      await pumpSite(
        tester,
        backend,
        size: phone,
        route: '/maple-cambridge/order/web_1?t=tok',
      );
      expect(find.byKey(const Key('thank-you')), findsOneWidget);
      await pumpSite(
        tester,
        backend,
        size: phone,
        route: '/maple-cambridge/privacy',
      );
      await pumpSite(tester, backend, size: phone, route: '/nobody');
      await tester.pumpWidget(const SizedBox());
    });
  });

  test('guests see plain words for connection and server faults', () {
    const generic =
        'Something went wrong. Check your connection and try again.';
    expect(
      errorMessage(const BackendException('internal', 'internal [0]')),
      generic,
    );
    expect(errorMessage(const BackendException('unavailable', 'x')), generic);
    expect(errorMessage(Exception('boom')), generic);
    expect(
      errorMessage(const BackendException('failed-precondition', 'Sold out.')),
      'Sold out.',
    );
  });

  test('phone and email checks', () {
    expect(validatePhone(''), isNull);
    expect(validatePhone('519-555-0100'), isNull);
    expect(validatePhone('+1 (519) 555-0100'), isNull);
    expect(validatePhone('555-0100'), isNotNull);
    expect(validatePhone('call me'), isNotNull);
    expect(validateEmail(''), isNull);
    expect(validateEmail('sam@example.com'), isNull);
    expect(validateEmail('sam@example'), isNotNull);
  });

  test('pickup slots start after the lead time on the quarter hour', () {
    final slots = pickupSlots(DateTime(2026, 11, 5, 12, 2), 15);
    expect(slots.first, isNull);
    expect(slots[1], DateTime(2026, 11, 5, 12, 30));
    expect(slots[2], DateTime(2026, 11, 5, 12, 45));
  });
}
