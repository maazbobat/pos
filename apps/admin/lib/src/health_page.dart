import 'package:flutter/material.dart';
import 'package:pos_shared/pos_shared.dart';

import 'widgets.dart';

/// The latest health sweep and the open incidents. Paging happens in Cloud
/// Monitoring (docs/monitoring.md); this is where a person looks closer.
class HealthPage extends StatelessWidget {
  const HealthPage({super.key, required this.backend});
  final Backend backend;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Health')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          StreamBuilder<HealthSummary?>(
            stream: backend.platform.health(),
            builder: (context, snap) {
              final h = snap.data;
              if (h == null) {
                return const Text(
                  'No health check has run yet. It runs every 15 minutes.',
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Checked ${fmtDate(h.checkedAt)}'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _Tile('Devices offline', h.staleDevices),
                      _Tile('Printer problems', h.printerProblems),
                      _Tile('Card payments stuck', h.stuckPayments),
                      _Tile('Open incidents', h.openIncidents),
                    ],
                  ),
                  if (h.staleDevicesByOrg.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text(
                      'Offline devices by tenant',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    for (final e in h.staleDevicesByOrg.entries)
                      ListTile(
                        dense: true,
                        title: Text(e.key),
                        trailing: Text('${e.value}'),
                      ),
                  ],
                ],
              );
            },
          ),
          const SizedBox(height: 24),
          Text(
            'Open incidents',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          StreamBuilder<List<Incident>>(
            stream: backend.platform.openIncidents(),
            builder: (context, snap) {
              final list = snap.data ?? const [];
              if (list.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('None.'),
                );
              }
              return Column(
                children: [
                  for (final i in list)
                    ListTile(
                      key: Key('incident-${i.id}'),
                      leading: const Icon(Icons.warning_amber_outlined),
                      title: Text(i.message),
                      subtitle: Text(
                        [
                          i.kind,
                          if (i.orgId != null) i.orgId!,
                          fmtDate(i.createdAt),
                        ].join(' · '),
                      ),
                      trailing: TextButton(
                        onPressed: () => _resolve(context, i),
                        child: const Text('Resolve'),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _resolve(BuildContext context, Incident incident) async {
    final note = await showDialog<String>(
      context: context,
      builder: (_) => const ReasonDialog(
        title: 'Resolve incident',
        confirmLabel: 'Resolve',
        minLength: 3,
      ),
    );
    if (note == null || !context.mounted) return;
    await runWithFeedback(
      context,
      () => backend.platform.resolveIncident(incident.id, note: note),
      success: 'Resolved.',
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile(this.label, this.value);
  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: value > 0 ? scheme.errorContainer : null,
      child: SizedBox(
        width: 180,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$value', style: Theme.of(context).textTheme.headlineMedium),
              Text(label),
            ],
          ),
        ),
      ),
    );
  }
}
