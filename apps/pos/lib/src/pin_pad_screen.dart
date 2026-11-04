import 'package:flutter/material.dart';
import 'package:pos_shared/pos_shared.dart';

import 'app.dart';
import 'device_shell.dart';

/// Staff type their PIN to take over the till. The server checks it and
/// locks the pad after repeated wrong PINs.
class PinPadScreen extends StatefulWidget {
  const PinPadScreen({
    super.key,
    required this.device,
    required this.onSignedIn,
  });
  final DeviceContext device;
  final ValueChanged<StaffSession> onSignedIn;

  @override
  State<PinPadScreen> createState() => _PinPadScreenState();
}

class _PinPadScreenState extends State<PinPadScreen> {
  String _pin = '';
  bool _busy = false;
  String? _error;

  void _press(String digit) {
    if (_busy || _pin.length >= 8) return;
    setState(() {
      _pin += digit;
      _error = null;
    });
  }

  void _back() {
    if (_busy || _pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _submit() async {
    if (_busy || _pin.length < 4) return;
    setState(() => _busy = true);
    final pin = _pin;
    try {
      final staff = await BackendScope.of(context).functions
          .startStaffSession(widget.device.orgId, pin);
      widget.onSignedIn(staff);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = errorText(e);
          _pin = '';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final keys = [
      '1',
      '2',
      '3',
      '4',
      '5',
      '6',
      '7',
      '8',
      '9',
      'back',
      '0',
      'enter',
    ];
    return Scaffold(
      body: Center(
        child: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Enter your PIN', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 16),
              Text(
                _pin.isEmpty ? ' ' : '•' * _pin.length,
                key: const Key('pin-dots'),
                style: theme.textTheme.headlineMedium?.copyWith(
                  letterSpacing: 8,
                ),
              ),
              SizedBox(
                height: 48,
                child: _error == null
                    ? null
                    : Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
              ),
              GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                children: [
                  for (final k in keys)
                    switch (k) {
                      'back' => IconButton.filledTonal(
                        key: const Key('pin-back'),
                        onPressed: _back,
                        icon: const Icon(Icons.backspace_outlined),
                      ),
                      'enter' => IconButton.filled(
                        key: const Key('pin-enter'),
                        onPressed: _pin.length >= 4 && !_busy ? _submit : null,
                        icon: _busy
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.arrow_forward),
                      ),
                      _ => FilledButton.tonal(
                        key: Key('pin-$k'),
                        onPressed: () => _press(k),
                        child: Text(k, style: theme.textTheme.headlineSmall),
                      ),
                    },
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
