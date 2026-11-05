import 'dart:convert';

import 'package:pos_shared/pos_shared.dart';
import 'package:test/test.dart';

Order _order({
  OrderSource source = OrderSource.pos,
  String ticket = '417',
  PaymentStatus paid = PaymentStatus.paid,
}) => Order.fromMap('o1', {
  'orgId': 'org',
  'locationId': 'cam',
  'source': source.name,
  'ticket': ticket,
  'status': 'new',
  'paymentStatus': paid.wire,
  'fulfillment': 'takeout',
  'createdAt': DateTime(2026, 11, 5, 12, 3),
  'notes': 'Allergy: peanuts',
  'items': [
    {
      'lineId': 'l1',
      'itemId': 'taro',
      'name': 'Taro milk tea',
      'qty': 2,
      'unitPriceCents': 550,
      'kitchenStation': 'bar',
      'notes': 'less ice',
      'modifiers': [
        {
          'groupId': 'size',
          'optionId': 'l',
          'name': 'Large',
          'priceDeltaCents': 75,
        },
        {
          'groupId': 'top',
          'optionId': 'b',
          'name': 'Boba',
          'priceDeltaCents': 0,
        },
      ],
    },
    {
      'lineId': 'l2',
      'itemId': 'bun',
      'name': 'Crème brûlée bun',
      'qty': 1,
      'unitPriceCents': 400,
      'kitchenStation': 'kitchen',
    },
  ],
  'totals': {
    'subtotalCents': 1650,
    'discountCents': 100,
    'taxCents': 202,
    'totalCents': 1752,
    'taxes': [
      {'id': 'hst', 'name': 'HST', 'rate': 0.13, 'cents': 202},
    ],
  },
});

const _receiptPrinter = PrinterConfig(
  id: 'front',
  name: 'Front',
  host: '192.168.1.50',
  hasDrawer: true,
);
const _bar = PrinterConfig(
  id: 'bar',
  name: 'Bar',
  host: '192.168.1.51',
  connection: PrinterConnection.raw,
  paperMm: 58,
  jobs: {PrinterJob.kitchen},
  stations: ['bar'],
);
const _kitchen = PrinterConfig(
  id: 'kitchen',
  name: 'Kitchen',
  host: '192.168.1.52',
  jobs: {PrinterJob.kitchen},
);

class _FakeTransport implements PrinterTransport {
  final sent = <(String, PrintDoc)>[];
  final failing = <String>{};
  @override
  Future<void> send(PrinterConfig printer, PrintDoc doc) async {
    if (failing.contains(printer.id)) {
      throw PrintException(printer.name, 'The printer is out of paper.');
    }
    sent.add((printer.id, doc));
  }
}

void main() {
  group('wrap and rows', () {
    test('wraps at spaces and splits words longer than a line', () {
      expect(wrap('one two three', 7), ['one two', 'three']);
      expect(wrap('abcdefghij', 4), ['abcd', 'efgh', 'ij']);
      expect(wrap('', 10), ['']);
    });

    test('a row puts the price at the right edge, wrapping a long name', () {
      final b = PrintDocBuilder(20)
        ..row('Tea', r'$5.50')
        ..row('A very long drink name here', r'$12.00');
      final lines = b.build().preview().split('\n');
      expect(lines[0], r'Tea            $5.50');
      expect(lines[0].length, 20);
      expect(
        lines.last.isEmpty ? lines[lines.length - 2] : lines.last,
        endsWith(r'$12.00'),
      );
    });
  });

  group('receipt', () {
    test(
      'has the store, items with options, taxes, tip, cash change and footer',
      () {
        final doc = receiptDoc(
          order: _order(),
          storeName: 'Maple Tea',
          settings: const ReceiptSettings(
            header: ['10 Main St, Cambridge ON'],
            taxNumber: '123456789 RT0001',
            footer: 'Merci!',
          ),
          payments: const [
            ReceiptPayment(
              label: 'Cash',
              amountCents: 1752,
              tenderedCents: 2000,
            ),
          ],
          printedAt: DateTime(2026, 11, 5, 12, 4),
          openDrawer: true,
        );
        final text = doc.preview();
        for (final want in [
          'MAPLE TEA',
          '10 Main St, Cambridge ON',
          'Order #417',
          'Takeout',
          '2026-11-05 12:03',
          '2 x Taro milk tea',
          r'Large +$0.75',
          '"less ice"',
          'Crème brûlée bun',
          r'-$1.00',
          'HST 13%',
          r'$17.52',
          r'Change',
          r'$2.48',
          'GST/HST: 123456789 RT0001',
          'Merci!',
        ]) {
          expect(text, contains(want));
        }
        expect(doc.opensDrawer, isTrue);
        expect(doc.ops.whereType<PrintCut>(), hasLength(1));
        // Every line fits on 80 mm paper.
        for (final op in doc.ops.whereType<PrintLine>()) {
          expect(
            op.text.length,
            lessThanOrEqualTo(op.big ? 24 : 48),
            reason: op.text,
          );
        }
      },
    );

    test('shows the tip and the total paid on a card sale', () {
      final text = receiptDoc(
        order: _order(),
        storeName: 'Maple Tea',
        settings: const ReceiptSettings(),
        payments: const [
          ReceiptPayment(label: 'Card', amountCents: 1752, tipCents: 250),
        ],
        printedAt: DateTime(2026, 11, 5),
      ).preview();
      expect(text, contains(r'$2.50'));
      expect(text, contains(r'$20.02'));
      expect(text, isNot(contains('Change')));
    });

    test('says NOT PAID and keeps online ticket numbers as they are', () {
      final text = receiptDoc(
        order: _order(
          source: OrderSource.online,
          ticket: 'W-417',
          paid: PaymentStatus.unpaid,
        ),
        storeName: 'Maple Tea',
        settings: const ReceiptSettings(),
        payments: const [],
        printedAt: DateTime(2026, 11, 5),
      ).preview();
      expect(text, contains('Order W-417'));
      expect(text, contains('NOT PAID'));
    });
  });

  group('kitchen tickets', () {
    test('go to each kitchen printer with only its stations', () {
      final settings = const HardwareSettings(
        printers: [_receiptPrinter, _bar, _kitchen],
      );
      final jobs = kitchenJobs(_order(), settings, DateTime(2026, 11, 5));
      expect(jobs.map((j) => j.printer.id), ['bar', 'kitchen']);
      final bar = jobs.first.doc.preview();
      expect(bar, contains('2 X TARO MILK\nTEA'));
      expect(bar, isNot(contains('BUN')));
      expect(bar, contains('- Large'));
      expect(bar, contains('! less ice'));
      expect(bar, contains('Note: Allergy: peanuts'));
      expect(bar, contains('1 more item(s) at other\nstations'));
      expect(jobs.first.doc.width, 32);
      final all = jobs.last.doc.preview();
      expect(all, contains('CRÈME BRÛLÉE BUN'));
    });

    test('skip a printer with nothing for it', () {
      final settings = const HardwareSettings(printers: [_bar]);
      final o = Order.fromMap('o2', {
        'ticket': '1',
        'items': [
          {'name': 'Bun', 'qty': 1, 'kitchenStation': 'kitchen'},
        ],
      });
      expect(kitchenJobs(o, settings, DateTime(2026)), isEmpty);
    });
  });

  group('ESC/POS', () {
    test('initializes, picks code page 858, styles lines, cuts and kicks the drawer', () {
      final b = PrintDocBuilder(48)
        ..text('Café', bold: true, big: true, align: PrintAlign.center)
        ..cut()
        ..openDrawer();
      final bytes = encodeEscPos(b.build());
      expect(bytes.sublist(0, 5), [0x1b, 0x40, 0x1b, 0x74, 19]);
      final line = [
        0x1b,
        0x61,
        1,
        0x1b,
        0x45,
        1,
        0x1d,
        0x21,
        0x11,
        0x43,
        0x61,
        0x66,
        0x82,
        0x0a,
      ];
      expect(bytes.sublist(5, 5 + line.length), line);
      expect(bytes.sublist(bytes.length - 9), [
        0x1d,
        0x56,
        0x42,
        0x00,
        0x1b,
        0x70,
        0x00,
        0x19,
        0xfa,
      ]);
    });

    test('turns smart quotes into ASCII and unknown characters into ?', () {
      final bytes = encodeEscPos(
        PrintDoc(width: 48, ops: const [PrintLine('“Hi” — 茶')]),
      );
      final text = bytes.sublist(14, bytes.length - 1);
      expect(latin1.decode(text), '"Hi" - ?');
    });
  });

  group('ePOS-Print XML', () {
    test('is a SOAP envelope with escaped text, cut and drawer pulse', () {
      final b = PrintDocBuilder(48)
        ..text('Tom & Jerry <3', bold: true)
        ..feed(2)
        ..cut()
        ..openDrawer();
      final xml = encodeEposXml(b.build());
      expect(
        xml,
        startsWith('<?xml version="1.0" encoding="utf-8"?><s:Envelope'),
      );
      expect(xml, contains('<epos-print xmlns="$eposNamespace">'));
      expect(
        xml,
        contains(
          '<text em="true" width="1" height="1">Tom &amp; Jerry &lt;3&#10;</text>',
        ),
      );
      expect(
        xml,
        contains(
          '<feed line="2"/><cut type="feed"/><pulse drawer="drawer_1" time="pulse_100"/>',
        ),
      );
    });

    test('builds the printer URL and reads its answer', () {
      expect(
        eposUri('192.168.1.50').toString(),
        'http://192.168.1.50/cgi-bin/epos/service.cgi?devid=local_printer&timeout=10000',
      );
      expect(eposUri('printer.local', https: true).scheme, 'https');
      const ok =
          '<s:Envelope><s:Body><response success="true" code="" status="251658262" xmlns="x"/></s:Body></s:Envelope>';
      expect(EposResponse.parse(ok).success, isTrue);
      final paper = EposResponse.parse(
        '<response success="false" code="EPTR_REC_EMPTY" status="0"/>',
      );
      expect(paper.success, isFalse);
      expect(paper.message, 'The printer is out of paper.');
      expect(EposResponse.parse('<html>').code, 'NO_RESPONSE');
    });
  });

  group('settings', () {
    test('round-trip through the Firestore map', () {
      const s = HardwareSettings(
        printers: [_bar, _receiptPrinter],
        receipt: ReceiptSettings(header: ['Line'], taxNumber: '1 RT0001'),
        autoPrintReceipt: true,
      );
      final back = HardwareSettings.fromMap(
        jsonDecode(jsonEncode(s.toMap())) as Map<String, Object?>,
      );
      expect(back.printers.map((p) => p.id), ['bar', 'front']);
      expect(back.printers.first.connection, PrinterConnection.raw);
      expect(back.printers.first.effectivePort, 9100);
      expect(back.printers.last.effectivePort, 80);
      expect(back.receiptPrinter?.id, 'front');
      expect(back.drawerPrinter?.id, 'front');
      expect(back.kitchenPrinters.map((p) => p.id), ['bar']);
      expect(back.receipt.taxNumber, '1 RT0001');
      expect(back.autoPrintReceipt, isTrue);
      expect(HardwareSettings.fromMap(const {}).printers, isEmpty);
    });
  });

  group('PrintService', () {
    test(
      'prints the receipt with the drawer kick on the same printer',
      () async {
        final t = _FakeTransport();
        final errors = await PrintService(t).receipt(
          const HardwareSettings(printers: [_receiptPrinter]),
          order: _order(),
          storeName: 'Maple',
          payments: const [ReceiptPayment(label: 'Cash', amountCents: 1752)],
          openDrawer: true,
        );
        expect(errors, isEmpty);
        expect(t.sent, hasLength(1));
        expect(t.sent.single.$2.opensDrawer, isTrue);
      },
    );

    test('kicks a drawer on another printer separately, and reports failures without throwing', () async {
      final t = _FakeTransport()..failing.add('front');
      final drawer = _kitchen.copyWith(hasDrawer: true);
      final receipt = _receiptPrinter.copyWith(hasDrawer: false);
      final errors = await PrintService(t).receipt(
        HardwareSettings(printers: [receipt, drawer]),
        order: _order(),
        storeName: 'Maple',
        payments: const [],
        openDrawer: true,
      );
      expect(errors.single.message, 'The printer is out of paper.');
      expect(t.sent.single.$1, 'kitchen');
      expect(t.sent.single.$2.ops.single, isA<PrintDrawerKick>());
    });

    test('says so when there is no drawer', () async {
      final errors = await PrintService(_FakeTransport())
          .openDrawer(const HardwareSettings());
      expect(errors.single.message, contains('No printer has a cash drawer'));
    });
  });
}
