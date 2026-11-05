import '../orders/order.dart';
import 'print_doc.dart';
import 'printers.dart';

/// Couldn't print. [message] is for staff, for example "The printer is out
/// of paper."
class PrintException implements Exception {
  const PrintException(this.printer, this.message);
  final String printer;
  final String message;

  @override
  String toString() => '$printer: $message';
}

/// Sends a [PrintDoc] to a printer. The POS app has the real ones (ePOS over
/// HTTP, raw TCP); tests use a fake. Throws [PrintException].
abstract interface class PrinterTransport {
  Future<void> send(PrinterConfig printer, PrintDoc doc);
}

/// What the POS prints and where, from the location's [HardwareSettings].
/// Printing never blocks a sale: callers show the errors and move on.
class PrintService {
  PrintService(this.transport, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;
  final PrinterTransport transport;
  final DateTime Function() _clock;

  /// Prints the receipt, and opens the drawer when [openDrawer] (cash
  /// sales). The drawer kick goes to the drawer's printer even if receipts
  /// print elsewhere. Returns the problems, empty when all went well.
  Future<List<PrintException>> receipt(
    HardwareSettings settings, {
    required Order order,
    required String storeName,
    required List<ReceiptPayment> payments,
    bool openDrawer = false,
    bool reprint = false,
  }) async {
    final printer = settings.receiptPrinter;
    final drawer = openDrawer ? settings.drawerPrinter : null;
    final errors = <PrintException>[];
    if (printer != null) {
      final doc = receiptDoc(
        order: order,
        storeName: storeName,
        settings: settings.receipt,
        payments: payments,
        printedAt: _clock(),
        width: printer.charsPerLine,
        openDrawer: drawer?.id == printer.id,
        reprint: reprint,
      );
      await _send(printer, doc, errors);
    }
    if (drawer != null && drawer.id != printer?.id) {
      await _send(drawer, drawerKickDoc(drawer), errors);
    }
    return errors;
  }

  /// Kitchen tickets on every kitchen printer that makes part of [order].
  Future<List<PrintException>> kitchen(
    HardwareSettings settings,
    Order order, {
    bool reprint = false,
  }) async {
    final errors = <PrintException>[];
    await Future.wait([
      for (final job in kitchenJobs(order, settings, _clock(), reprint: reprint))
        _send(job.printer, job.doc, errors),
    ]);
    return errors;
  }

  /// No sale: just open the drawer.
  Future<List<PrintException>> openDrawer(HardwareSettings settings) async {
    final drawer = settings.drawerPrinter;
    if (drawer == null) {
      return [const PrintException('Drawer', 'No printer has a cash drawer set up.')];
    }
    final errors = <PrintException>[];
    await _send(drawer, drawerKickDoc(drawer), errors);
    return errors;
  }

  /// A short page to check a printer's settings.
  Future<List<PrintException>> test(PrinterConfig printer, String storeName) async {
    final b = PrintDocBuilder(printer.charsPerLine)
      ..text(storeName, align: PrintAlign.center, bold: true, big: true)
      ..text('Test print: ${printer.name}', align: PrintAlign.center)
      ..text('${printer.host}:${printer.effectivePort} ${printer.connection.name}', align: PrintAlign.center)
      ..rule()
      ..row('Café au lait', r'$4.50')
      ..row('Total', r'$4.50', bold: true, big: true)
      ..feed(3)
      ..cut();
    final errors = <PrintException>[];
    await _send(printer, b.build(), errors);
    return errors;
  }

  Future<void> _send(PrinterConfig p, PrintDoc doc, List<PrintException> errors) async {
    try {
      await transport.send(p, doc);
    } on PrintException catch (e) {
      errors.add(e);
    } catch (e) {
      errors.add(PrintException(p.name, 'Couldn\'t reach the printer at ${p.host}.'));
    }
  }
}

PrintDoc drawerKickDoc(PrinterConfig p) =>
    PrintDoc(width: p.charsPerLine, ops: const [PrintDrawerKick()]);
