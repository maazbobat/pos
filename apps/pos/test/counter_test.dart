import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_shared/pos_shared.dart';
import 'package:pos_shared/testing.dart';
import 'package:pos_terminal/src/app.dart';

const deviceId = 'dev_1';

class FakePrinters implements PrinterTransport {
  final sent = <(String, PrintDoc)>[];
  String? failWith;

  @override
  Future<void> send(PrinterConfig printer, PrintDoc doc) async {
    if (failWith case final f?) throw PrintException(printer.name, f);
    sent.add((printer.id, doc));
  }

  List<String> get texts => [for (final s in sent) s.$2.preview()];
}

const front = PrinterConfig(
  id: 'front',
  name: 'Front',
  host: '192.168.1.50',
  hasDrawer: true,
);
const bar = PrinterConfig(
  id: 'bar',
  name: 'Bar',
  host: '192.168.1.51',
  jobs: {PrinterJob.kitchen},
);

FakeBackend backendWithMenu() {
  final fake = FakeBackend()..auth.signInAs(deviceId);
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
    ..items.add(
      const MenuItem(
        id: 'mango',
        orgId: 'org-a',
        name: 'Mango slush',
        categoryId: 'tea',
        priceCents: 1000,
        kitchenStation: 'bar',
      ),
    );
  fake.functions.onStartSession = (_) async =>
      const StaffSession(uid: 'sam', role: Role.cashier, displayName: 'Sam');
  return fake;
}

Future<void> unlock(
  WidgetTester tester,
  FakeBackend fake,
  FakePrinters printers,
) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    PosApp(backend: fake.backend, printerTransport: printers),
  );
  await tester.pumpAndSettle();
  for (final d in '2580'.split('')) {
    await tester.tap(find.byKey(Key('pin-$d')));
  }
  await tester.pump();
  await tester.tap(find.byKey(const Key('pin-enter')));
  await tester.pumpAndSettle();
}

/// Lets the payment dialog poll without waiting for its spinner to stop.
Future<void> tick(WidgetTester tester, [int seconds = 2]) async {
  for (var i = 0; i < seconds * 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('no card button until a reader is set up', (tester) async {
    final fake = backendWithMenu();
    await unlock(tester, fake, FakePrinters());
    expect(find.byKey(const Key('pay-card')), findsNothing);
    expect(find.textContaining('adds a card reader'), findsOneWidget);
    fake.counter
      ..settings = const PaymentSettings(
        cardProvider: 'stripe_terminal',
        readers: [CardReader(id: 'front', name: 'Front reader')],
      )
      ..notify();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pay-card')), findsOneWidget);
  });

  testWidgets(
    'takes a card with a tip on the reader, then prints the kitchen ticket and receipt',
    (tester) async {
      final fake = backendWithMenu();
      fake.counter
        ..settings = const PaymentSettings(
          cardProvider: 'stripe_terminal',
          readers: [CardReader(id: 'front', name: 'Front reader')],
        )
        ..hardwareSettings = const HardwareSettings(
          printers: [front, bar],
          autoPrintReceipt: true,
        );
      final printers = FakePrinters();
      await unlock(tester, fake, printers);

      await tester.tap(find.byKey(const Key('item-mango')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pay-card')));
      await tester.pumpAndSettle();
      // $10.00 + HST $1.30 = $11.30; 15% tip = $1.70.
      expect(find.text(r'Card: $11.30'), findsOneWidget);
      await tester.tap(find.byKey(const Key('tip-15')));
      await tester.pump();
      expect(find.text(r'Charge $13.00'), findsOneWidget);
      await tester.tap(find.byKey(const Key('card-charge')));
      await tick(tester, 1);

      expect(find.byKey(const Key('card-waiting')), findsOneWidget);
      expect(
        find.textContaining('tap, insert or swipe on Front reader'),
        findsOneWidget,
      );
      // The order is written unpaid before the charge goes to the reader.
      expect(fake.orders.placed.single['paymentStatus'], 'unpaid');
      expect(
        fake.counter.calls.single,
        matches(RegExp(r'^charge:order-1:1130\+170@front$')),
      );
      expect(printers.sent, isEmpty);

      final paymentId = fake.counter.charges.keys.single;
      fake.counter.settle(paymentId, CardPaymentStatus.succeeded);
      await tick(tester, 3);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('card-waiting')), findsNothing);
      expect(find.textContaining('paid by card'), findsOneWidget);
      expect(fake.orders.orders['order-1']!.paymentStatus, PaymentStatus.paid);
      expect(printers.sent.map((s) => s.$1), unorderedEquals(['bar', 'front']));
      final receipt = printers.sent.firstWhere((s) => s.$1 == 'front').$2;
      expect(receipt.preview(), contains(r'$13.00'));
      expect(receipt.opensDrawer, isFalse);
    },
  );

  testWidgets('a declined card can be retried, or left unpaid in Orders', (
    tester,
  ) async {
    final fake = backendWithMenu();
    fake.counter.settings = const PaymentSettings(
      cardProvider: 'stripe_terminal',
      readers: [
        CardReader(id: 'a', name: 'Counter 1'),
        CardReader(id: 'b', name: 'Counter 2'),
      ],
    );
    await unlock(tester, fake, FakePrinters());
    await tester.tap(find.byKey(const Key('item-mango')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pay-card')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('card-reader')), findsOneWidget);
    await tester.tap(find.byKey(const Key('card-charge')));
    await tick(tester, 1);
    fake.counter.settle(
      fake.counter.charges.keys.single,
      CardPaymentStatus.failed,
      reason: 'insufficient_funds',
    );
    await tick(tester, 3);
    expect(find.text('Declined: insufficient funds.'), findsOneWidget);

    // Trying again is a new attempt with a new key, on the same order.
    await tester.tap(find.byKey(const Key('card-retry')));
    await tester.pump();
    fake.counter.failNextWith = 'reader_offline';
    await tester.tap(find.byKey(const Key('card-charge')));
    await tick(tester, 1);
    expect(find.textContaining('reader is offline'), findsOneWidget);
    expect(fake.counter.charges, hasLength(2));
    expect(fake.orders.placed, hasLength(1));

    await tester.tap(find.text('Close (order stays unpaid)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('saved as not paid'), findsOneWidget);
    expect(fake.orders.orders['order-1']!.paymentStatus, PaymentStatus.unpaid);
  });

  testWidgets(
    'cash opens the drawer through the printer and offers the receipt',
    (tester) async {
      final fake = backendWithMenu();
      fake.counter.hardwareSettings = const HardwareSettings(
        printers: [front],
        autoPrintKitchen: false,
      );
      final printers = FakePrinters();
      await unlock(tester, fake, printers);
      await tester.tap(find.byKey(const Key('item-mango')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pay-cash')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cash-2000')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cash-done')));
      await tester.pumpAndSettle();

      // Only the drawer kick so far.
      expect(printers.sent.single.$2.ops.single, isA<PrintDrawerKick>());
      await tester.tap(find.byKey(const Key('print-receipt')));
      await tester.pumpAndSettle();
      expect(printers.sent, hasLength(2));
      expect(printers.texts.last, contains('Change'));
      expect(printers.texts.last, contains(r'$8.70'));
    },
  );

  testWidgets('a printer problem is shown but never blocks the sale', (
    tester,
  ) async {
    final fake = backendWithMenu();
    fake.counter.hardwareSettings = const HardwareSettings(
      printers: [front],
      autoPrintReceipt: true,
    );
    final printers = FakePrinters()..failWith = 'The printer is out of paper.';
    await unlock(tester, fake, printers);
    await tester.tap(find.byKey(const Key('item-mango')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pay-cash')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cash-1130')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cash-done')));
    await tester.pumpAndSettle();
    expect(fake.orders.placed.single['paymentStatus'], 'paid');
    expect(find.textContaining('out of paper'), findsOneWidget);
  });

  testWidgets('a refund needs a manager PIN and a reason', (tester) async {
    final fake = backendWithMenu();
    fake.counter.hardwareSettings = const HardwareSettings(printers: [front]);
    await unlock(tester, fake, FakePrinters());
    await tester.tap(find.byKey(const Key('item-mango')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pay-cash')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cash-1130')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cash-done')));
    await tester.pumpAndSettle();

    // Let the sale's confirmation go away.
    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('orders')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('more-order-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('action-refund')));
    await tester.pumpAndSettle();
    expect(find.textContaining(r'Up to $11.30'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('approval-reason')),
      'Wrong drink',
    );
    await tester.tap(find.byKey(const Key('approval-submit')));
    await tester.pump();
    expect(find.text('A manager types their PIN.'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('approval-amount')), '5');
    await tester.enterText(find.byKey(const Key('approval-pin')), '1111');
    await tester.tap(find.byKey(const Key('approval-submit')));
    await tester.pumpAndSettle();
    expect(find.textContaining('isn\'t a manager\'s'), findsOneWidget);
    expect(fake.counter.calls, isEmpty);
    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('more-order-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('action-refund')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('approval-amount')), '5');
    await tester.enterText(
      find.byKey(const Key('approval-reason')),
      'Wrong drink',
    );
    await tester.enterText(find.byKey(const Key('approval-pin')), '2580');
    await tester.tap(find.byKey(const Key('approval-submit')));
    await tester.pumpAndSettle();
    expect(fake.counter.calls, ['refund:cash_order-1:500:Wrong drink']);
    expect(find.text(r'Refunded $5.00.'), findsOneWidget);
  });

  testWidgets(
    'an unpaid order can be voided with a manager PIN or charged by card',
    (tester) async {
      final fake = backendWithMenu();
      fake.counter.settings = const PaymentSettings(
        cardProvider: 'stripe_terminal',
        readers: [CardReader(id: 'front', name: 'Front reader')],
      );
      fake.orders.orders['web_1'] = Order.fromMap('web_1', {
        'orgId': 'org-a',
        'locationId': 'cambridge',
        'source': 'online',
        'ticket': 'W-417',
        'status': 'new',
        'paymentStatus': 'unpaid',
        'fulfillment': 'pickup',
        'items': [
          {
            'itemId': 'mango',
            'name': 'Mango slush',
            'qty': 1,
            'unitPriceCents': 1000,
          },
        ],
        'totals': {'subtotalCents': 1000, 'taxCents': 130, 'totalCents': 1130},
      });
      await unlock(tester, fake, FakePrinters());
      await tester.tap(find.byKey(const Key('orders')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('take-card-web_1')), findsOneWidget);

      await tester.tap(find.byKey(const Key('more-web_1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('action-void')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('approval-reason')),
        'Guest left',
      );
      await tester.enterText(find.byKey(const Key('approval-pin')), '2580');
      await tester.tap(find.byKey(const Key('approval-submit')));
      await tester.pumpAndSettle();
      expect(fake.counter.calls, ['void:web_1:Guest left']);
      expect(fake.orders.orders['web_1']!.status, OrderStatus.voided);
    },
  );
}
