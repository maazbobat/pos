import 'dart:typed_data';

import 'package:pos_shared/pos_shared.dart';

/// Browsers can't open raw sockets.
Future<void> sendRaw(PrinterConfig printer, Uint8List bytes, Duration timeout) async {
  throw PrintException(
    printer.name,
    'Raw (port 9100) printing works only in the Android app. Switch this printer to ePOS.',
  );
}
