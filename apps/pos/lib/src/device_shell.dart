import 'package:flutter/material.dart';
import 'package:pos_shared/pos_shared.dart';

import 'app.dart';
import 'menu_screen.dart';
import 'pin_pad_screen.dart';

/// Where this device belongs, read from its own membership (never from
/// anything stored on the tablet), and who is currently using it.
class DeviceContext {
  const DeviceContext({
    required this.orgId,
    required this.locationId,
    required this.deviceId,
  });
  final String orgId;
  final String locationId;
  final String deviceId;
}

class DeviceShell extends StatefulWidget {
  const DeviceShell({super.key, required this.deviceId});
  final String deviceId;

  @override
  State<DeviceShell> createState() => _DeviceShellState();
}

class _DeviceShellState extends State<DeviceShell> {
  StaffSession? _staff;

  @override
  Widget build(BuildContext context) {
    final backend = BackendScope.of(context);
    return StreamBuilder<List<String>>(
      stream: backend.data.orgIdsOf(widget.deviceId),
      builder: (context, orgsSnap) {
        if (!orgsSnap.hasData) return const _Loading();
        final orgIds = orgsSnap.data!;
        if (orgIds.isEmpty) return const _Revoked();
        final orgId = orgIds.first;
        return StreamBuilder<Membership?>(
          stream: backend.data.member(orgId, widget.deviceId),
          builder: (context, memberSnap) {
            if (memberSnap.hasError) return const _Revoked();
            if (!memberSnap.hasData) return const _Loading();
            final member = memberSnap.data!;
            if (member.status != MemberStatus.active ||
                member.locationRoles.length != 1) {
              return const _Revoked();
            }
            final device = DeviceContext(
              orgId: orgId,
              locationId: member.locationRoles.keys.single,
              deviceId: widget.deviceId,
            );
            final staff = _staff;
            if (staff == null) {
              return PinPadScreen(
                device: device,
                onSignedIn: (s) => setState(() => _staff = s),
              );
            }
            return MenuScreen(
              device: device,
              staff: staff,
              onLock: () => setState(() => _staff = null),
            );
          },
        );
      },
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();
  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

/// The membership is gone or suspended: a manager revoked this tablet.
class _Revoked extends StatelessWidget {
  const _Revoked();
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.block, size: 48),
            const SizedBox(height: 16),
            const Text('This tablet is no longer paired with a store.'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => BackendScope.of(context).auth.signOut(),
              child: const Text('Pair again'),
            ),
          ],
        ),
      ),
    );
  }
}
