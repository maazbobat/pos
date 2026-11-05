import 'dart:io';
import 'dart:typed_data';

import 'package:pos_shared/pos_shared.dart';

/// ESC/POS bytes straight to the printer's port 9100.
Future<void> sendRaw(PrinterConfig printer, Uint8List bytes, Duration timeout) async {
  Socket? socket;
  try {
    socket = await Socket.connect(printer.host, printer.effectivePort, timeout: timeout);
    socket.add(bytes);
    await socket.flush().timeout(timeout);
  } on SocketException {
    throw PrintException(
      printer.name,
      'Couldn\'t reach the printer at ${printer.host}:${printer.effectivePort}.',
    );
  } finally {
    await socket?.close();
  }
}
