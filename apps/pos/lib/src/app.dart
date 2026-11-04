import 'package:flutter/material.dart';
import 'package:pos_shared/pos_shared.dart';

import 'device_shell.dart';
import 'pairing_screen.dart';

/// The front-counter tablet. It signs in as a paired device (never as a
/// person), then staff switch on it with their PIN.
class PosApp extends StatelessWidget {
  const PosApp({super.key, required this.backend});
  final Backend backend;

  @override
  Widget build(BuildContext context) {
    return BackendScope(
      backend: backend,
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
  const BackendScope({super.key, required this.backend, required super.child});
  final Backend backend;

  static Backend of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BackendScope>()!.backend;

  @override
  bool updateShouldNotify(BackendScope old) => backend != old.backend;
}

String errorText(Object error) =>
    error is BackendException || error is MenuValidationError
    ? error.toString()
    : 'Something went wrong. Check the connection and try again.';
