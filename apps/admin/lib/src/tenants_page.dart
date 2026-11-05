import 'package:flutter/material.dart';
import 'package:pos_shared/pos_shared.dart';

import 'tenant_detail_page.dart';
import 'widgets.dart';

/// Every tenant, from the platformOrgs summaries. No tenant data is read
/// here, so no support grant is needed.
class TenantsPage extends StatefulWidget {
  const TenantsPage({super.key, required this.backend, required this.uid});
  final Backend backend;
  final String uid;

  @override
  State<TenantsPage> createState() => _TenantsPageState();
}

enum _Filter { all, attention, trial, suspended }

class _TenantsPageState extends State<TenantsPage> {
  String _query = '';
  _Filter _filter = _Filter.all;

  bool _matches(TenantSummary t) {
    final q = _query.toLowerCase();
    final text =
        q.isEmpty ||
        t.name.toLowerCase().contains(q) ||
        (t.ownerEmail ?? '').toLowerCase().contains(q) ||
        t.orgId.toLowerCase().contains(q);
    final state = switch (_filter) {
      _Filter.all => true,
      _Filter.attention => t.readOnly || t.graceEndsAt != null || t.suspended,
      _Filter.trial => t.billingSource == BillingSource.trial,
      _Filter.suspended => t.suspended,
    };
    return text && state;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tenants')),
      body: StreamBuilder<List<TenantSummary>>(
        stream: widget.backend.platform.tenants(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final all = snap.data!;
          final shown = all.where(_matches).toList();
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: 320,
                      child: TextField(
                        key: const Key('tenant-search'),
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          hintText: 'Name, owner email or ID',
                        ),
                        onChanged: (v) => setState(() => _query = v.trim()),
                      ),
                    ),
                    for (final f in _Filter.values)
                      ChoiceChip(
                        label: Text(switch (f) {
                          _Filter.all => 'All (${all.length})',
                          _Filter.attention => 'Needs attention',
                          _Filter.trial => 'On trial',
                          _Filter.suspended => 'Suspended',
                        }),
                        selected: _filter == f,
                        onSelected: (_) => setState(() => _filter = f),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: shown.isEmpty
                    ? const Center(child: Text('No tenants match.'))
                    : ListView.separated(
                        itemCount: shown.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final t = shown[i];
                          return ListTile(
                            key: Key('tenant-${t.orgId}'),
                            title: Text(t.name),
                            subtitle: Text(
                              '${t.plan.label} · ${t.locationCount} '
                              '${t.locationCount == 1 ? 'location' : 'locations'}'
                              ' · ${t.ownerEmail ?? 'no owner email'}',
                            ),
                            trailing: _StateChip(tenant: t),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => TenantDetailPage(
                                  backend: widget.backend,
                                  uid: widget.uid,
                                  orgId: t.orgId,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _StateChip extends StatelessWidget {
  const _StateChip({required this.tenant});
  final TenantSummary tenant;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bad = tenant.suspended || tenant.readOnly;
    final warn = tenant.graceEndsAt != null;
    return Chip(
      label: Text(tenantState(tenant)),
      backgroundColor: bad
          ? scheme.errorContainer
          : warn
          ? scheme.tertiaryContainer
          : null,
    );
  }
}
