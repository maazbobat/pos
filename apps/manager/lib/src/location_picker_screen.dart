import 'package:flutter/material.dart';
import 'package:pos_shared/pos_shared.dart';

import 'app.dart';
import 'location_screen.dart';
import 'pin_dialog.dart';

/// Owners see every location and can add one; everyone else sees the
/// locations where they hold a role.
class LocationPickerScreen extends StatelessWidget {
  const LocationPickerScreen({super.key, required this.org, required this.uid});
  final Organization org;
  final String uid;

  @override
  Widget build(BuildContext context) {
    final data = BackendScope.of(context).data;
    return StreamBuilder<Membership?>(
      stream: data.member(org.id, uid),
      builder: (context, snap) {
        final member = snap.data;
        return Scaffold(
          appBar: AppBar(
            title: Text(org.name),
            actions: [
              if (member != null)
                IconButton(
                  key: const Key('set-pin'),
                  tooltip: 'Set my PIN',
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => SetPinDialog(orgId: org.id),
                  ),
                  icon: const Icon(Icons.pin_outlined),
                ),
            ],
          ),
          floatingActionButton: member != null && member.isOwner && org.canWrite
              ? FloatingActionButton.extended(
                  key: const Key('add-location'),
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => AddLocationDialog(orgId: org.id),
                  ),
                  icon: const Icon(Icons.add),
                  label: const Text('Add location'),
                )
              : null,
          body: member == null
              ? const Center(child: CircularProgressIndicator())
              : member.isOwner
              ? StreamBuilder<List<Location>>(
                  stream: data.allLocations(org.id),
                  builder: (context, locs) =>
                      _list(context, member, locs.data ?? const []),
                )
              : _list(context, member, null),
        );
      },
    );
  }

  Widget _list(BuildContext context, Membership member, List<Location>? all) {
    final data = BackendScope.of(context).data;
    final ids =
        all?.map((l) => l.id).toList() ?? member.locationRoles.keys.toList();
    if (ids.isEmpty) {
      return Center(
        child: Text(
          member.isOwner ? 'Add your first location.' : 'No locations yet.',
        ),
      );
    }
    return ListView(
      children: [
        for (final id in ids)
          StreamBuilder<Location?>(
            stream: data.location(org.id, id),
            builder: (context, snap) {
              final loc = snap.data;
              if (loc == null) return const SizedBox.shrink();
              final role = member.roleAt(loc.id);
              return ListTile(
                leading: const Icon(Icons.store),
                title: Text(loc.name),
                subtitle: Text(
                  [
                    if (role != null) role.label,
                    if (loc.status == LocationStatus.closed) 'Closed',
                  ].join(' · '),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => LocationScreen(
                      store: StoreContext(
                        org: org,
                        location: loc,
                        member: member,
                        uid: uid,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

class AddLocationDialog extends StatefulWidget {
  const AddLocationDialog({super.key, required this.orgId});
  final String orgId;

  @override
  State<AddLocationDialog> createState() => _AddLocationDialogState();
}

class _AddLocationDialogState extends State<AddLocationDialog> {
  static const provinces = [
    'AB',
    'BC',
    'MB',
    'NB',
    'NL',
    'NS',
    'NT',
    'NU',
    'ON',
    'PE',
    'QC',
    'SK',
    'YT',
  ];
  static const timezones = {
    'America/St_Johns': 'Newfoundland',
    'America/Halifax': 'Atlantic',
    'America/Toronto': 'Eastern',
    'America/Winnipeg': 'Central',
    'America/Regina': 'Saskatchewan',
    'America/Edmonton': 'Mountain',
    'America/Vancouver': 'Pacific',
    'America/Whitehorse': 'Yukon',
  };

  final _name = TextEditingController();
  String _province = 'ON';
  String _timezone = 'America/Toronto';
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() => _busy = true);
    final ok = await runWithFeedback(
      context,
      () => BackendScope.of(context).functions.createLocation(
        orgId: widget.orgId,
        name: _name.text.trim(),
        province: _province,
        timezone: _timezone,
      ),
      success: 'Location added. Check its tax settings before the first sale.',
    );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add a location'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('location-name'),
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Name, for example "Cambridge"',
            ),
          ),
          DropdownButtonFormField<String>(
            initialValue: _province,
            decoration: const InputDecoration(
              labelText: 'Province or territory',
            ),
            items: [
              for (final p in provinces)
                DropdownMenuItem(value: p, child: Text(p)),
            ],
            onChanged: (v) => setState(() => _province = v!),
          ),
          DropdownButtonFormField<String>(
            initialValue: _timezone,
            decoration: const InputDecoration(labelText: 'Time zone'),
            items: [
              for (final e in timezones.entries)
                DropdownMenuItem(value: e.key, child: Text(e.value)),
            ],
            onChanged: (v) => setState(() => _timezone = v!),
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
          child: const Text('Add'),
        ),
      ],
    );
  }
}
