import 'package:flutter/material.dart';
import 'package:pos_shared/pos_shared.dart';

import 'device_shell.dart';
import 'pairing_screen.dart';
import 'printing/network_transport.dart';

/// The front-counter tablet. It signs in as a paired device (never as a
/// person), then staff switch on it with their PIN.
class PosApp extends StatefulWidget {
  const PosApp({super.key, required this.backend, this.printerTransport});
  final Backend backend;

  /// How receipts and kitchen tickets reach the printers. Defaults to the
  /// network (Epson ePOS or raw TCP); tests pass a fake.
  final PrinterTransport? printerTransport;

  @override
  State<PosApp> createState() => _PosAppState();
}

class _PosAppState extends State<PosApp> {
  late final printing = PrintService(
    widget.printerTransport ?? NetworkPrinterTransport(),
  );

  @override
  Widget build(BuildContext context) {
    final backend = widget.backend;
    return BackendScope(
      backend: backend,
      printing: printing,
      child: MaterialApp(
        title: 'POS',
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        home: StreamBuilder<String?>(
          stream: backend.auth.uidChanges(),
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }
            final uid = snap.data;
            return uid == null
                ? const PairingScreen()
                : DeviceShell(key: ValueKey(uid), deviceId: uid);
          },
        ),
      ),
    );
  }
}

class BackendScope extends InheritedWidget {
  const BackendScope({
    super.key,
    required this.backend,
    required this.printing,
    required super.child,
  });
  final Backend backend;
  final PrintService printing;

  static Backend of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BackendScope>()!.backend;

  static PrintService printingOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BackendScope>()!.printing;

  @override
  bool updateShouldNotify(BackendScope old) => backend != old.backend;
}

String errorText(Object error) =>
    error is BackendException || error is MenuValidationError
    ? error.toString()
    : 'Something went wrong. Check the connection and try again.';
