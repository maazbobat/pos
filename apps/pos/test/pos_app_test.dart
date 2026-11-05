import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_shared/pos_shared.dart';
import 'package:pos_shared/testing.dart';
import 'package:pos_terminal/src/app.dart';

const deviceId = 'dev_1';

FakeBackend pairedBackend() {
  final fake = FakeBackend();
  fake.data
    ..orgIds[deviceId] = ['org-a']
    ..members['org-a/$deviceId'] = const Membership(
      uid: deviceId,
      orgId: 'org-a',
      kind: MemberKind.device,
      status: MemberStatus.active,
      locationRoles: {'cambridge': Role.device},
    )
    ..categories.add(const MenuCategory(id: 'tea', orgId: 'org-a', name: 'Tea'))
    ..items.addAll(const [
      MenuItem(
        id: 'taro',
        orgId: 'org-a',
        name: 'Taro milk tea',
        categoryId: 'tea',
        priceCents: 625,
      ),
      MenuItem(
        id: 'mango',
        orgId: 'org-a',
        name: 'Mango slush',
        categoryId: 'tea',
        priceCents: 575,
      ),
    ])
    ..overridesByLocation['cambridge'] = [
      const MenuOverride(
        itemId: 'taro',
        orgId: 'org-a',
        locationId: 'cambridge',
        priceCents: 650,
      ),
    ];
  return fake;
}

Future<void> typePin(WidgetTester tester, String pin) async {
  for (final d in pin.split('')) {
    await tester.tap(find.byKey(Key('pin-$d')));
  }
  await tester.pump();
}

void main() {
  testWidgets('a new tablet pairs with a code and lands on the PIN pad', (
    tester,
  ) async {
    final fake = pairedBackend();
    fake.functions.onRedeem = (code) async => PairedDevice(
      customToken: 'token:$deviceId',
      orgId: 'org-a',
      locationId: 'cambridge',
      deviceId: deviceId,
      deviceType: DeviceType.pos,
    );
    await tester.pumpWidget(PosApp(backend: fake.backend));
    await tester.pumpAndSettle();
    expect(find.text('Pair this tablet'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('pairing-code')), 'ab');
    await tester.tap(find.text('Pair'));
    await tester.pump();
    expect(find.textContaining('8 letters and numbers'), findsOneWidget);
    expect(fake.functions.calls, isEmpty);

    await tester.enterText(find.byKey(const Key('pairing-code')), '7kqm-3xwp');
    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();
    expect(fake.functions.calls, ['redeemPairingCode:7KQM3XWP']);
    expect(fake.auth.customTokens, ['token:$deviceId']);
    expect(find.text('Enter your PIN'), findsOneWidget);
  });

  testWidgets('a rejected code shows the server message', (tester) async {
    final fake = FakeBackend();
    await tester.pumpWidget(PosApp(backend: fake.backend));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('pairing-code')), '7KQM3XWP');
    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();
    expect(find.text('That pairing code isn\'t valid.'), findsOneWidget);
  });

  testWidgets('staff unlock with a PIN, see local prices, and lock again', (
    tester,
  ) async {
    final fake = pairedBackend()..auth.signInAs(deviceId);
    fake.functions.onStartSession = (pin) async {
      if (pin != '2580') {
        throw const BackendException(
          'permission-denied',
          'That PIN didn\'t match anyone at this location.',
        );
      }
      return const StaffSession(
        uid: 'sam',
        role: Role.cashier,
        displayName: 'Sam',
      );
    };
    await tester.pumpWidget(PosApp(backend: fake.backend));
    await tester.pumpAndSettle();

    await typePin(tester, '9999');
    await tester.tap(find.byKey(const Key('pin-enter')));
    await tester.pumpAndSettle();
    expect(
      find.text('That PIN didn\'t match anyone at this location.'),
      findsOneWidget,
    );

    await typePin(tester, '2580');
    await tester.tap(find.byKey(const Key('pin-enter')));
    await tester.pumpAndSettle();
    expect(find.text('Sam'), findsOneWidget);
    expect(
      find.text(r'$6.50'),
      findsOneWidget,
      reason: 'Cambridge price override',
    );
    expect(find.text(r'$5.75'), findsOneWidget);

    await tester.tap(find.byKey(const Key('lock')));
    await tester.pumpAndSettle();
    expect(find.text('Enter your PIN'), findsOneWidget);
  });

  testWidgets('long-pressing an item marks it sold out at this store', (
    tester,
  ) async {
    final fake = pairedBackend()..auth.signInAs(deviceId);
    fake.functions.onStartSession = (_) async =>
        const StaffSession(uid: 'sam', role: Role.cashier);
    await tester.pumpWidget(PosApp(backend: fake.backend));
    await tester.pumpAndSettle();
    await typePin(tester, '2580');
    await tester.tap(find.byKey(const Key('pin-enter')));
    await tester.pumpAndSettle();

    await tester.longPress(find.byKey(const Key('item-mango')));
    await tester.pumpAndSettle();
    expect(fake.data.writes, ['override:mango:false:null:$deviceId']);
    expect(find.text('Sold out'), findsOneWidget);
  });

  testWidgets('a revoked tablet asks to be paired again', (tester) async {
    final fake = pairedBackend()..auth.signInAs(deviceId);
    fake.data.members['org-a/$deviceId'] = const Membership(
      uid: deviceId,
      orgId: 'org-a',
      kind: MemberKind.device,
      status: MemberStatus.suspended,
      locationRoles: {'cambridge': Role.device},
    );
    await tester.pumpWidget(PosApp(backend: fake.backend));
    await tester.pumpAndSettle();
    expect(
      find.text('This tablet is no longer paired with a store.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Pair again'));
    await tester.pumpAndSettle();
    expect(find.text('Pair this tablet'), findsOneWidget);
  });

  Future<FakeBackend> unlocked(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fake = pairedBackend()..auth.signInAs(deviceId);
    fake.data
      ..groups.add(
        const ModifierGroup(
          id: 'size',
          orgId: 'org-a',
          name: 'Size',
          minSelect: 1,
          maxSelect: 1,
          options: [
            ModifierOption(id: 'm', name: 'Medium'),
            ModifierOption(id: 'l', name: 'Large', priceDeltaCents: 100),
          ],
        ),
      )
      ..items[0] = const MenuItem(
        id: 'taro',
        orgId: 'org-a',
        name: 'Taro milk tea',
        categoryId: 'tea',
        priceCents: 625,
        modifierGroupIds: ['size'],
        kitchenStation: 'bar',
      );
    fake.functions.onStartSession = (_) async =>
        const StaffSession(uid: 'sam', role: Role.cashier, displayName: 'Sam');
    await tester.pumpWidget(PosApp(backend: fake.backend));
    await tester.pumpAndSettle();
    await typePin(tester, '2580');
    await tester.tap(find.byKey(const Key('pin-enter')));
    await tester.pumpAndSettle();
    return fake;
  }

  String total(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('order-total'))).data!;

  testWidgets('rings up an order with options and a discount, paid in cash', (
    tester,
  ) async {
    final fake = await unlocked(tester);

    // Taro has a required size: pick Large.
    await tester.tap(find.byKey(const Key('item-taro')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('option-size-l')));
    await tester.enterText(find.byKey(const Key('line-notes')), 'less ice');
    await tester.pumpAndSettle();
    expect(find.text(r'Add $7.50'), findsOneWidget);
    await tester.tap(find.byKey(const Key('add-to-order')));
    await tester.pumpAndSettle();

    // Mango has no options, so a tap adds it straight away.
    await tester.tap(find.byKey(const Key('item-mango')));
    await tester.pumpAndSettle();
    // 7.50 + 5.75 = 13.25, HST 1.72
    expect(total(tester), r'$14.97');

    // A cashier gives 10% off with no manager PIN.
    await tester.tap(find.byKey(const Key('discount')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('discount-value')), '10');
    await tester.enterText(find.byKey(const Key('discount-reason')), 'regular');
    await tester.tap(find.byKey(const Key('apply-discount')));
    await tester.pumpAndSettle();
    // 13.25 - 1.33 = 11.92, HST 1.55
    expect(total(tester), r'$13.47');

    await tester.tap(find.byKey(const Key('pay-cash')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cash-2000')));
    await tester.pumpAndSettle();
    expect(find.text(r'Change: $6.53'), findsOneWidget);
    await tester.tap(find.byKey(const Key('cash-done')));
    await tester.pumpAndSettle();

    expect(fake.orders.placed, hasLength(1));
    final placed = fake.orders.placed.single;
    expect(placed['source'], 'pos');
    expect(placed['paymentStatus'], 'paid');
    expect(placed['staffUid'], 'sam');
    expect(placed['deviceId'], deviceId);
    expect(placed['totals'], containsPair('totalCents', 1347));
    expect(placed['payment'], containsPair('amountCents', 1347));
    final lines = placed['items'] as List;
    expect(lines.first, containsPair('notes', 'less ice'));
    expect((lines.first as Map)['modifiers'], [
      {
        'groupId': 'size',
        'optionId': 'l',
        'name': 'Large',
        'priceDeltaCents': 100,
      },
    ]);
    expect(find.textContaining(r'Change: $6.53'), findsOneWidget);
    expect(total(tester), r'$0.00');
  });

  testWidgets('the order list takes cash for an online order paid at pickup', (
    tester,
  ) async {
    final fake = await unlocked(tester);
    fake.orders.orders['web_1'] = Order.fromMap('web_1', {
      'orgId': 'org-a',
      'locationId': 'cambridge',
      'source': 'online',
      'ticket': 'W-417',
      'status': 'ready',
      'paymentStatus': 'unpaid',
      'fulfillment': 'pickup',
      'items': [
        {
          'itemId': 'taro',
          'name': 'Taro milk tea',
          'qty': 1,
          'unitPriceCents': 650,
        },
      ],
      'totals': {'subtotalCents': 650, 'taxCents': 85, 'totalCents': 735},
      'customer': {'name': 'Sam G'},
    });
    await tester.tap(find.byKey(const Key('orders')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Online · Sam G'), findsOneWidget);
    expect(find.textContaining('not paid'), findsOneWidget);

    await tester.tap(find.byKey(const Key('take-cash-web_1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cash-735')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cash-done')));
    await tester.pumpAndSettle();
    expect(fake.orders.calls, ['cash:web_1:735']);

    await tester.tap(find.byKey(const Key('hand-over-web_1')));
    await tester.pumpAndSettle();
    expect(fake.orders.calls.last, 'status:web_1:completed');
  });

  testWidgets('staff can pause online orders from the counter', (tester) async {
    final fake = await unlocked(tester);
    fake.orders
      ..online = const OnlineOrderingSettings(enabled: true, slug: 'maple')
      ..notify();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('online-pause')));
    await tester.pumpAndSettle();
    expect(fake.orders.calls, ['online:paused=true']);
    expect(find.text('Resume online'), findsOneWidget);
  });

  testWidgets('a kitchen display shows open tickets and moves them along', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fake = pairedBackend()..auth.signInAs(deviceId);
    fake.data.devicesByLocation['cambridge'] = [
      const Device(
        id: deviceId,
        orgId: 'org-a',
        locationId: 'cambridge',
        type: DeviceType.kds,
        name: 'Kitchen',
        status: DeviceStatus.active,
      ),
    ];
    Map<String, Object?> line(String name, String station) => {
      'itemId': name,
      'name': name,
      'qty': 1,
      'unitPriceCents': 500,
      'kitchenStation': station,
    };
    fake.orders.orders
      ..['o1'] = Order.fromMap('o1', {
        'orgId': 'org-a',
        'locationId': 'cambridge',
        'ticket': '101',
        'status': 'new',
        'items': [line('Taro milk tea', 'bar')],
      })
      ..['o2'] = Order.fromMap('o2', {
        'orgId': 'org-a',
        'locationId': 'cambridge',
        'source': 'delivery',
        'channel': 'uber_eats',
        'ticket': '8F2A1',
        'status': 'in_progress',
        'items': [line('Fries', 'grill')],
      });
    await tester.pumpWidget(PosApp(backend: fake.backend));
    await tester.pumpAndSettle();

    expect(find.text('Enter your PIN'), findsNothing);
    expect(find.text('Kitchen · 2 open'), findsOneWidget);
    expect(find.textContaining('Uber Eats'), findsOneWidget);

    await tester.tap(find.byKey(const Key('advance-o1')));
    await tester.pumpAndSettle();
    expect(fake.orders.calls, ['status:o1:in_progress']);

    await tester.tap(find.byKey(const Key('advance-o2')));
    await tester.pumpAndSettle();
    expect(fake.orders.calls.last, 'status:o2:ready');

    await tester.tap(find.byKey(const Key('station')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('grill').last);
    await tester.pumpAndSettle();
    expect(find.text('Kitchen · 1 open'), findsOneWidget);
  });
}
