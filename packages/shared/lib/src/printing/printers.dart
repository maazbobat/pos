import '../menu/money.dart';
import '../orders/order.dart';
import 'print_doc.dart';

/// How the POS reaches a printer.
enum PrinterConnection {
  /// Epson ePOS-Print: XML over HTTP to the printer's own web service.
  /// Works on the Android tablets and in a browser served over plain HTTP.
  /// Turn it on in the printer's web page (EpsonNet Config > ePOS-Print).
  epos,

  /// ESC/POS bytes over TCP port 9100. Android only (browsers can't open
  /// raw sockets). Works on any network ESC/POS printer.
  raw;

  static PrinterConnection fromWire(String? v) =>
      values.where((c) => c.name == v).firstOrNull ?? epos;
}

/// What a printer is for. One printer can do both.
enum PrinterJob {
  receipt,
  kitchen;

  static PrinterJob? fromWire(String? v) =>
      values.where((j) => j.name == v).firstOrNull;
}

/// A printer at a location, from `settings/hardware.printers.{id}`.
class PrinterConfig {
  const PrinterConfig({
    required this.id,
    required this.name,
    required this.host,
    this.connection = PrinterConnection.epos,
    this.port,
    this.https = false,
    this.paperMm = 80,
    this.jobs = const {PrinterJob.receipt},
    this.stations = const [],
    this.hasDrawer = false,
  });

  final String id;

  /// What staff call it, for example "Front counter" or "Bar".
  final String name;

  /// The printer's IP address or host name on the store's network. Give
  /// it a fixed address (a DHCP reservation in the router).
  final String host;
  final PrinterConnection connection;

  /// Leave null for the default: 80 (443 with [https]) for ePOS, 9100 raw.
  final int? port;

  /// ePOS over HTTPS. Needed when the POS runs in a browser on an https://
  /// page, which may not call plain http:// addresses. The printer's
  /// certificate has to be trusted by the tablet.
  final bool https;

  /// 80 mm paper fits 48 characters a line, 58 mm fits 32.
  final int paperMm;
  final Set<PrinterJob> jobs;

  /// For kitchen printers: the kitchen stations whose items print here, for
  /// example `["bar"]`. Empty means every item.
  final List<String> stations;

  /// A cash drawer is plugged into this printer's drawer port.
  final bool hasDrawer;

  int get charsPerLine => paperMm <= 58 ? 32 : 48;
  int get effectivePort =>
      port ?? (connection == PrinterConnection.raw ? 9100 : (https ? 443 : 80));

  bool printsStation(String? station) =>
      stations.isEmpty || (station != null && stations.contains(station));

  factory PrinterConfig.fromMap(String id, Map<String, Object?> d) =>
      PrinterConfig(
        id: id,
        name: d['name'] as String? ?? id,
        host: d['host'] as String? ?? '',
        connection: PrinterConnection.fromWire(d['connection'] as String?),
        port: (d['port'] as num?)?.toInt(),
        https: d['https'] as bool? ?? false,
        paperMm: (d['paperMm'] as num?)?.toInt() ?? 80,
        jobs: {
          for (final j in (d['jobs'] as List?) ?? const ['receipt'])
            ?PrinterJob.fromWire(j as String?),
        },
        stations: [
          for (final s in (d['stations'] as List?) ?? const []) s as String,
        ],
        hasDrawer: d['hasDrawer'] as bool? ?? false,
      );

  Map<String, Object?> toMap() => {
    'name': name,
    'host': host,
    'connection': connection.name,
    'port': port,
    'https': https,
    'paperMm': paperMm,
    'jobs': [for (final j in jobs) j.name],
    'stations': stations,
    'hasDrawer': hasDrawer,
  };

  PrinterConfig copyWith({
    String? name,
    String? host,
    PrinterConnection? connection,
    int? port,
    bool clearPort = false,
    bool? https,
    int? paperMm,
    Set<PrinterJob>? jobs,
    List<String>? stations,
    bool? hasDrawer,
  }) => PrinterConfig(
    id: id,
    name: name ?? this.name,
    host: host ?? this.host,
    connection: connection ?? this.connection,
    port: clearPort ? null : (port ?? this.port),
    https: https ?? this.https,
    paperMm: paperMm ?? this.paperMm,
    jobs: jobs ?? this.jobs,
    stations: stations ?? this.stations,
    hasDrawer: hasDrawer ?? this.hasDrawer,
  );
}

/// What goes at the top and bottom of a guest receipt.
class ReceiptSettings {
  const ReceiptSettings({
    this.header = const [],
    this.footer = 'Thank you!',
    this.taxNumber,
  });

  /// Lines under the store name: street address, phone, website.
  final List<String> header;
  final String? footer;

  /// The GST/HST registration number, for example `123456789 RT0001`.
  /// Business guests need it on receipts of $30 or more to claim the tax back.
  final String? taxNumber;

  factory ReceiptSettings.fromMap(Map<String, Object?> d) => ReceiptSettings(
    header: [for (final h in (d['header'] as List?) ?? const []) h as String],
    footer: d['footer'] as String? ?? 'Thank you!',
    taxNumber: d['taxNumber'] as String?,
  );

  Map<String, Object?> toMap() => {
    'header': header,
    'footer': footer,
    'taxNumber': taxNumber,
  };
}

/// `settings/hardware`: printers, the receipt layout and when to print.
/// Managers edit it.
class HardwareSettings {
  const HardwareSettings({
    this.printers = const [],
    this.receipt = const ReceiptSettings(),
    this.autoPrintReceipt = false,
    this.autoPrintKitchen = true,
  });

  final List<PrinterConfig> printers;
  final ReceiptSettings receipt;

  /// Print the guest receipt after every sale, rather than when asked.
  final bool autoPrintReceipt;

  /// Print kitchen tickets as soon as an order is placed.
  final bool autoPrintKitchen;

  PrinterConfig? get receiptPrinter =>
      printers.where((p) => p.jobs.contains(PrinterJob.receipt)).firstOrNull;
  PrinterConfig? get drawerPrinter =>
      printers.where((p) => p.hasDrawer).firstOrNull;
  List<PrinterConfig> get kitchenPrinters => [
    for (final p in printers)
      if (p.jobs.contains(PrinterJob.kitchen)) p,
  ];

  factory HardwareSettings.fromMap(Map<String, Object?> d) {
    final printers = Map<String, Object?>.from((d['printers'] as Map?) ?? {});
    return HardwareSettings(
      printers: [
        for (final e in printers.entries)
          PrinterConfig.fromMap(e.key, Map<String, Object?>.from(e.value as Map)),
      ]..sort((a, b) => a.name.compareTo(b.name)),
      receipt: ReceiptSettings.fromMap(
        Map<String, Object?>.from((d['receipt'] as Map?) ?? {}),
      ),
      autoPrintReceipt: d['autoPrintReceipt'] as bool? ?? false,
      autoPrintKitchen: d['autoPrintKitchen'] as bool? ?? true,
    );
  }

  Map<String, Object?> toMap() => {
    'printers': {for (final p in printers) p.id: p.toMap()},
    'receipt': receipt.toMap(),
    'autoPrintReceipt': autoPrintReceipt,
    'autoPrintKitchen': autoPrintKitchen,
  };
}

/// A payment as printed on a receipt.
class ReceiptPayment {
  const ReceiptPayment({
    required this.label,
    required this.amountCents,
    this.tipCents = 0,
    this.tenderedCents,
  });

  /// "Cash", "Card" or "Online".
  final String label;
  final int amountCents;
  final int tipCents;

  /// Cash handed over, to print the change.
  final int? tenderedCents;
}

String _two(int n) => n.toString().padLeft(2, '0');
String _when(DateTime t) =>
    '${t.year}-${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}';

String _fulfillment(Fulfillment f) => switch (f) {
  Fulfillment.here => 'For here',
  Fulfillment.takeout => 'Takeout',
  Fulfillment.pickup => 'Pickup',
  Fulfillment.delivery => 'Delivery',
};

/// POS tickets are digits ("417"); online ones already read "W-417".
String _ticketLabel(Order o) =>
    RegExp(r'^\d+$').hasMatch(o.ticket) ? 'Order #${o.ticket}' : 'Order ${o.ticket}';

String _percent(double rate) {
  final p = rate * 100;
  return p == p.roundToDouble() ? '${p.round()}%' : '${p.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '')}%';
}

/// The guest receipt. [printedAt] is local time at the store.
PrintDoc receiptDoc({
  required Order order,
  required String storeName,
  required ReceiptSettings settings,
  required List<ReceiptPayment> payments,
  required DateTime printedAt,
  int width = 48,
  bool openDrawer = false,
  bool reprint = false,
}) {
  final b = PrintDocBuilder(width)
    ..text(storeName, align: PrintAlign.center, bold: true, big: true);
  for (final h in settings.header) {
    b.text(h, align: PrintAlign.center);
  }
  b
    ..feed()
    ..row(_ticketLabel(order), _fulfillment(order.fulfillment), bold: true)
    ..text(_when(order.createdAt ?? printedAt));
  if (order.customer case final c?) b.text(c.name);
  if (reprint) b.text('COPY', align: PrintAlign.center, bold: true);
  b.rule();
  for (final l in order.items) {
    b.row('${l.qty} x ${l.name}', formatCad(l.lineTotalCents));
    for (final m in l.modifiers) {
      b.text(
        m.priceDeltaCents == 0 ? m.name : '${m.name} ${m.priceDeltaCents > 0 ? '+' : ''}${formatCad(m.priceDeltaCents)}',
        indent: 4,
      );
    }
    if (l.notes case final n?) b.text('"$n"', indent: 4);
  }
  final t = order.totals;
  b
    ..rule()
    ..row('Subtotal', formatCad(t.subtotalCents));
  if (t.discountCents > 0) b.row('Discount', formatCad(-t.discountCents));
  for (final tax in t.taxes) {
    b.row('${tax.name} ${_percent(tax.rate)}', formatCad(tax.cents));
  }
  b.row('Total', formatCad(t.totalCents), bold: true, big: true);
  final tips = payments.fold(0, (s, p) => s + p.tipCents);
  if (tips > 0) {
    b
      ..row('Tip', formatCad(tips))
      ..row('Total paid', formatCad(t.totalCents + tips), bold: true);
  }
  if (payments.isNotEmpty) b.feed();
  for (final p in payments) {
    b.row(p.label, formatCad(p.amountCents + p.tipCents));
    if (p.tenderedCents case final tendered? when tendered > p.amountCents) {
      b
        ..row('  Tendered', formatCad(tendered))
        ..row('  Change', formatCad(tendered - p.amountCents));
    }
  }
  if (order.paymentStatus == PaymentStatus.unpaid && payments.isEmpty) {
    b.text('NOT PAID', align: PrintAlign.center, bold: true);
  }
  if (settings.taxNumber case final n? when n.isNotEmpty) {
    b
      ..feed()
      ..text('GST/HST: $n', align: PrintAlign.center);
  }
  if (settings.footer case final f? when f.isNotEmpty) {
    b
      ..feed()
      ..text(f, align: PrintAlign.center);
  }
  b
    ..feed(3)
    ..cut();
  if (openDrawer) b.openDrawer();
  return b.build();
}

/// A kitchen ticket for one printer: only the lines whose station that
/// printer makes. Null when none of the order is for it.
PrintDoc? kitchenTicketDoc({
  required Order order,
  required PrinterConfig printer,
  required DateTime printedAt,
  bool reprint = false,
}) {
  final lines = [
    for (final l in order.items)
      if (printer.printsStation(l.kitchenStation)) l,
  ];
  if (lines.isEmpty) return null;
  final source = switch (order.source) {
    OrderSource.pos => 'POS',
    OrderSource.online => 'Online',
    OrderSource.delivery => order.channel ?? 'Delivery',
  };
  final b = PrintDocBuilder(printer.charsPerLine)
    ..row(RegExp(r'^\d+$').hasMatch(order.ticket) ? '#${order.ticket}' : order.ticket, _fulfillment(order.fulfillment), bold: true, big: true)
    ..text('${_when(order.createdAt ?? printedAt)}  $source');
  if (order.customer case final c?) b.text(c.name, bold: true);
  if (order.pickupAt case final p?) b.text('Pickup ${_when(p)}', bold: true);
  if (reprint) b.text('REPRINT', bold: true);
  b.rule();
  for (final l in lines) {
    b.text('${l.qty} x ${l.name}', bold: true, big: true);
    for (final m in l.modifiers) {
      b.text('- ${m.name}', indent: 2);
    }
    if (l.notes case final n?) b.text('! $n', indent: 2, bold: true);
  }
  if (order.notes case final n? when n.isNotEmpty) {
    b
      ..rule()
      ..text('Note: $n', bold: true);
  }
  if (lines.length < order.items.length) {
    b.text('(${order.items.length - lines.length} more item(s) at other stations)');
  }
  b
    ..feed(3)
    ..cut();
  return b.build();
}

/// One printout to send.
class PrintJobFor {
  const PrintJobFor(this.printer, this.doc);
  final PrinterConfig printer;
  final PrintDoc doc;
}

/// The kitchen tickets for [order], one per kitchen printer that makes part
/// of it.
List<PrintJobFor> kitchenJobs(
  Order order,
  HardwareSettings settings,
  DateTime printedAt, {
  bool reprint = false,
}) => [
  for (final p in settings.kitchenPrinters)
    if (kitchenTicketDoc(order: order, printer: p, printedAt: printedAt, reprint: reprint)
        case final doc?)
      PrintJobFor(p, doc),
];
