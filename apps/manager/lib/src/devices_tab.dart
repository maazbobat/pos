import 'package:flutter/material.dart';
import 'package:pos_shared/pos_shared.dart';

import 'app.dart';

class DevicesTab extends StatelessWidget {
  const DevicesTab({super.key, required this.store});
  final StoreContext store;

  @override
  Widget build(BuildContext context) {
    final backend = BackendScope.of(context);
    return Scaffold(
      floatingActionButton: store.canWrite
          ? FloatingActionButton.extended(
              key: const Key('pair-device'),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => PairDeviceDialog(store: store),
              ),
              icon: const Icon(Icons.add_link),
              label: const Text('Pair a device'),
            )
          : null,
      body: StreamBuilder<List<Device>>(
        stream: backend.data.devices(store.org.id, store.location.id),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final devices = [...snap.data!]
            ..sort((a, b) => a.status.index.compareTo(b.status.index));
          if (devices.isEmpty) {
            return const Center(
              child: Text(
                'No tablets yet. Tap "Pair a device" and type the code on the tablet.',
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 88),
            children: [
              for (final d in devices)
                ListTile(
                  key: Key('device-${d.id}'),
                  leading: Icon(
                    d.type == DeviceType.kds
                        ? Icons.soup_kitchen_outlined
                        : Icons.point_of_sale,
                  ),
                  title: Text(d.name),
                  subtitle: Text(
                    [
                      d.type == DeviceType.kds ? 'Kitchen display' : 'POS',
                      if (d.status == DeviceStatus.revoked) 'Revoked',
                      if (d.appVersion != null) 'v${d.appVersion}',
                    ].join(' · '),
                  ),
                  trailing: d.status == DeviceStatus.active
                      ? TextButton(
                          onPressed: () => _confirmRevoke(context, d),
                          child: const Text('Revoke'),
                        )
                      : null,
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _confirmRevoke(BuildContext context, Device device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Revoke ${device.name}?'),
        content: const Text(
          'It is signed out right away and has to be paired again with a new code.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await runWithFeedback(
      context,
      () =>
          BackendScope.of(context).functions
              .revokeDevice(store.org.id, store.location.id, device.id),
      success: '${device.name} revoked',
    );
  }
}

class PairDeviceDialog extends StatefulWidget {
  const PairDeviceDialog({super.key, required this.store});
  final StoreContext store;

  @override
  State<PairDeviceDialog> createState() => _PairDeviceDialogState();
}

class _PairDeviceDialogState extends State<PairDeviceDialog> {
  final _name = TextEditingController(text: 'Front counter');
  DeviceType _type = DeviceType.pos;
  PairingCode? _code;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final code = await BackendScope.of(context).functions.createPairingCode(
        orgId: widget.store.org.id,
        locationId: widget.store.location.id,
        deviceType: _type,
        deviceName: _name.text.trim(),
      );
      setState(() => _code = code);
    } catch (e) {
      setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final code = _code;
    if (code != null) {
      final time = TimeOfDay.fromDateTime(code.expiresAt).format(context);
      return AlertDialog(
        title: const Text('Type this on the tablet'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              code.code,
              key: const Key('pairing-code-text'),
              style: Theme.of(context).textTheme.displaySmall
                  ?.copyWith(letterSpacing: 6),
            ),
            const SizedBox(height: 12),
            Text('Works once, until $time.'),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ],
      );
    }
    return AlertDialog(
      title: const Text('Pair a device'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SegmentedButton<DeviceType>(
            segments: const [
              ButtonSegment(value: DeviceType.pos, label: Text('POS')),
              ButtonSegment(
                value: DeviceType.kds,
                label: Text('Kitchen display'),
              ),
            ],
            selected: {_type},
            onSelectionChanged: (s) => setState(() => _type = s.single),
          ),
          TextField(
            key: const Key('device-name'),
            controller: _name,
            decoration: InputDecoration(
              labelText: 'Name',
              errorText: _error,
              errorMaxLines: 3,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _create,
          child: const Text('Get code'),
        ),
      ],
    );
  }
}
