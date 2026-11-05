import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:pos_shared/pos_shared.dart';

import 'raw_socket_stub.dart'
    if (dart.library.io) 'raw_socket_io.dart' as raw;

/// Prints to network Epson printers: ePOS-Print XML over HTTP(S), or raw
/// ESC/POS over TCP 9100 on Android.
class NetworkPrinterTransport implements PrinterTransport {
  NetworkPrinterTransport({http.Client? client})
    : _client = client ?? http.Client();
  final http.Client _client;

  static const timeout = Duration(seconds: 15);

  @override
  Future<void> send(PrinterConfig printer, PrintDoc doc) async {
    if (printer.host.isEmpty) {
      throw PrintException(printer.name, 'No address is set for this printer.');
    }
    switch (printer.connection) {
      case PrinterConnection.epos:
        await _epos(printer, doc);
      case PrinterConnection.raw:
        await raw.sendRaw(printer, encodeEscPos(doc), timeout);
    }
  }

  Future<void> _epos(PrinterConfig printer, PrintDoc doc) async {
    final uri = eposUri(
      printer.host,
      https: printer.https,
      port: printer.port,
    );
    final http.Response res;
    try {
      res = await _client
          .post(
            uri,
            headers: {
              'Content-Type': 'text/xml; charset=utf-8',
              'SOAPAction': '""',
            },
            body: encodeEposXml(doc),
          )
          .timeout(timeout);
    } on TimeoutException {
      throw PrintException(printer.name, 'The printer didn\'t answer. Is it on and connected?');
    } catch (_) {
      throw PrintException(
        printer.name,
        'Couldn\'t reach the printer at ${printer.host}. Check it\'s on the same network.',
      );
    }
    if (res.statusCode == 404) {
      throw PrintException(printer.name, 'ePOS-Print isn\'t turned on in the printer\'s settings.');
    }
    final answer = EposResponse.parse(res.body);
    if (!answer.success) throw PrintException(printer.name, answer.message);
  }
}
