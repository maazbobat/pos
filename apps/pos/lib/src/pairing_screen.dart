import 'package:flutter/material.dart';
import 'package:pos_shared/pos_shared.dart';

import 'app.dart';

/// First launch: a manager creates a code in the manager app, someone types
/// it here, and the tablet becomes a device at that location.
class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key});

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _pair() async {
    final code = normalizePairingCode(_code.text);
    if (code == null) {
      setState(
        () =>
            _error = 'A pairing code is 8 letters and numbers, like 7KQM-3XWP.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final backend = BackendScope.of(context);
    try {
      final paired = await backend.functions.redeemPairingCode(
        code,
        appVersion: '0.1.0',
      );
      await backend.auth.signInWithCustomToken(paired.customToken);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Pair this tablet', style: theme.textTheme.headlineMedium),
                const SizedBox(height: 8),
                const Text(
                  'In the manager app, open the store, go to Devices and tap '
                  '"Pair a device". Enter the code it shows.',
                ),
                const SizedBox(height: 24),
                TextField(
                  key: const Key('pairing-code'),
                  controller: _code,
                  autofocus: true,
                  textCapitalization: TextCapitalization.characters,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    letterSpacing: 4,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Pairing code',
                    hintText: 'XXXX-XXXX',
                    errorText: _error,
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _busy ? null : _pair(),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _busy ? null : _pair,
                  child: _busy
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Pair'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
