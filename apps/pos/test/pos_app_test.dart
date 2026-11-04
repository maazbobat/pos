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
}
