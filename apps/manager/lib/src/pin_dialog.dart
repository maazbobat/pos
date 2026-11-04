import 'package:flutter/material.dart';

import 'app.dart';

/// Sets the PIN this person types on the store's tablets.
class SetPinDialog extends StatefulWidget {
  const SetPinDialog({super.key, required this.orgId});
  final String orgId;

  @override
  State<SetPinDialog> createState() => _SetPinDialogState();
}

class _SetPinDialogState extends State<SetPinDialog> {
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!RegExp(r'^\d{4,8}$').hasMatch(_pin.text)) {
      setState(() => _error = 'A PIN is 4 to 8 digits.');
      return;
    }
    if (_pin.text != _confirm.text) {
      setState(() => _error = 'The PINs don\'t match.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await BackendScope.of(context).functions
          .setStaffPin(widget.orgId, _pin.text);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('PIN saved')));
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    InputDecoration deco(String label, {String? error}) => InputDecoration(
      labelText: label,
      errorText: error,
      errorMaxLines: 3,
      counterText: '',
    );
    return AlertDialog(
      title: const Text('Your PIN'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'You\'ll type this on the store tablet to start a shift. It must be different from everyone else\'s.',
          ),
          TextField(
            key: const Key('pin'),
            controller: _pin,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 8,
            decoration: deco('PIN'),
          ),
          TextField(
            key: const Key('pin-confirm'),
            controller: _confirm,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 8,
            decoration: deco('Type it again', error: _error),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
