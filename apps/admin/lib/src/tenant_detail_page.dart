import 'package:flutter/material.dart';
import 'package:pos_shared/pos_shared.dart';

import 'widgets.dart';

/// One tenant: its billing state, support access, status and the platform
/// actions taken on it. Each action needs a reason and is audited in the
/// tenant's own log and the platform log.
class TenantDetailPage extends StatelessWidget {
  const TenantDetailPage({
    super.key,
    required this.backend,
    required this.uid,
    required this.orgId,
  });
  final Backend backend;
  final String uid;
  final String orgId;

  PlatformBackend get _platform => backend.platform;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<TenantSummary?>(
      stream: _platform.tenant(orgId),
      builder: (context, snap) {
        final t = snap.data;
        return Scaffold(
          appBar: AppBar(title: Text(t?.name ?? orgId)),
          body: t == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _section(context, 'Overview', [
                      _row('Status', tenantState(t)),
                      _row('Org ID', t.orgId),
                      _row('Type', t.type ?? '-'),
                      _row('Owner', t.ownerEmail ?? '-'),
                      _row('Locations', '${t.locationCount}'),
                      _row('Created', fmtDate(t.createdAt)),
                    ]),
                    _section(context, 'Billing', [
                      _row('Plan', t.plan.label),
                      _row('Billed through', switch (t.billingSource) {
                        BillingSource.trial => 'Free trial',
                        BillingSource.stripe => 'Stripe',
                        BillingSource.manual => 'Set by the platform',
                      }),
                      _row('Billing status', t.billingStatus.wireName),
                      if (t.trialEndsAt != null)
                        _row('Trial ends', fmtDate(t.trialEndsAt)),
                      if (t.graceEndsAt != null)
                        _row('Grace ends', fmtDate(t.graceEndsAt)),
                      Wrap(
                        spacing: 8,
                        children: [
                          OutlinedButton(
                            key: const Key('set-plan'),
                            onPressed: () => _setPlan(context, t),
                            child: const Text('Set plan by hand'),
                          ),
                          if (t.billingSource == BillingSource.trial)
                            OutlinedButton(
                              key: const Key('extend-trial'),
                              onPressed: () => _extendTrial(context),
                              child: const Text('Extend trial'),
                            ),
                        ],
                      ),
                    ]),
                    _section(context, 'Support access', [
                      _SupportAccess(backend: backend, uid: uid, orgId: orgId),
                    ]),
                    _section(context, 'Tenant status', [
                      Text(
                        t.suspended
                            ? 'Suspended. Only the owner can read their data, and nobody can write.'
                            : 'Active.',
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: t.suspended
                            ? OutlinedButton(
                                key: const Key('reactivate'),
                                onPressed: () => _setSuspended(context, false),
                                child: const Text('Reactivate'),
                              )
                            : OutlinedButton(
                                key: const Key('suspend'),
                                onPressed: () => _setSuspended(context, true),
                                child: const Text('Suspend'),
                              ),
                      ),
                    ]),
                    _section(context, 'Platform actions on this tenant', [
                      StreamBuilder<List<AuditEntry>>(
                        stream: _platform.platformAudit(
                          orgId: orgId,
                          limit: 20,
                        ),
                        builder: (context, s) => AuditList(
                          entries: s.data ?? const [],
                          showOrg: false,
                        ),
                      ),
                    ]),
                  ],
                ),
        );
      },
    );
  }

  Widget _section(BuildContext context, String title, List<Widget> children) =>
      Card(
        margin: const EdgeInsets.only(bottom: 16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              ...children,
            ],
          ),
        ),
      );

  Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        SizedBox(width: 140, child: Text(label)),
        Expanded(child: SelectableText(value)),
      ],
    ),
  );

  Future<void> _setSuspended(BuildContext context, bool suspended) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => ReasonDialog(
        title: suspended ? 'Suspend this tenant?' : 'Reactivate this tenant?',
        confirmLabel: suspended ? 'Suspend' : 'Reactivate',
        destructive: suspended,
      ),
    );
    if (reason == null || !context.mounted) return;
    await runWithFeedback(
      context,
      () => _platform.setOrgSuspended(
        orgId,
        suspended: suspended,
        reason: reason,
      ),
      success: suspended ? 'Suspended.' : 'Reactivated.',
    );
  }

  Future<void> _setPlan(BuildContext context, TenantSummary t) async {
    var plan = t.plan == Plan.trial ? Plan.franchise : t.plan;
    var active = true;
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => ReasonDialog(
        title: 'Set plan by hand',
        confirmLabel: 'Save',
        minLength: 3,
        extra: StatefulBuilder(
          builder: (context, setState) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<Plan>(
                key: const Key('plan'),
                initialValue: plan,
                decoration: const InputDecoration(labelText: 'Plan'),
                items: [
                  for (final p in Plan.values.where((p) => p != Plan.trial))
                    DropdownMenuItem(value: p, child: Text(p.label)),
                ],
                onChanged: (v) => setState(() => plan = v!),
              ),
              SwitchListTile(
                key: const Key('plan-active'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Active'),
                subtitle: const Text(
                  'Off ends the plan and starts the grace period.',
                ),
                value: active,
                onChanged: (v) => setState(() => active = v),
              ),
            ],
          ),
        ),
      ),
    );
    if (reason == null || !context.mounted) return;
    await runWithFeedback(
      context,
      () => _platform.setManualPlan(
        orgId,
        plan: plan,
        active: active,
        reason: reason,
      ),
      success: 'Plan saved.',
    );
  }

  Future<void> _extendTrial(BuildContext context) async {
    final days = TextEditingController(text: '14');
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => ReasonDialog(
        title: 'Extend the free trial',
        confirmLabel: 'Extend',
        minLength: 3,
        extra: TextField(
          key: const Key('trial-days'),
          controller: days,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Days to add (1-90)'),
        ),
      ),
    );
    final n = int.tryParse(days.text.trim());
    if (reason == null || !context.mounted) return;
    if (n == null || n < 1 || n > 90) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Days must be a whole number from 1 to 90.'),
        ),
      );
      return;
    }
    await runWithFeedback(
      context,
      () => _platform.extendTrial(orgId, days: n, reason: reason),
      success: 'Trial extended by $n days.',
    );
  }
}

class _SupportAccess extends StatelessWidget {
  const _SupportAccess({
    required this.backend,
    required this.uid,
    required this.orgId,
  });
  final Backend backend;
  final String uid;
  final String orgId;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<SupportGrant?>(
      stream: backend.platform.mySupportGrant(orgId, uid),
      builder: (context, snap) {
        final grant = snap.data;
        if (grant != null && grant.isActive) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'You can read this tenant\'s data until ${fmtDate(grant.expiresAt)}. '
                'Reason: "${grant.reason}". The owner sees this and can end it.',
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                key: const Key('end-support'),
                onPressed: () => runWithFeedback(
                  context,
                  () => backend.platform.revokeMySupportAccess(orgId),
                  success: 'Support access ended.',
                ),
                child: const Text('End access now'),
              ),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'You have no access to this tenant\'s data. Open read-only access '
              'for up to 24 hours to help with a support request.',
            ),
            const SizedBox(height: 8),
            FilledButton.tonal(
              key: const Key('open-support'),
              onPressed: () => _open(context),
              child: const Text('Open support access'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _open(BuildContext context) async {
    var hours = 2;
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => ReasonDialog(
        title: 'Open read-only support access',
        confirmLabel: 'Open access',
        extra: StatefulBuilder(
          builder: (context, setState) => DropdownButtonFormField<int>(
            key: const Key('support-hours'),
            initialValue: hours,
            decoration: const InputDecoration(labelText: 'For'),
            items: [
              for (final h in const [1, 2, 4, 8, 24])
                DropdownMenuItem(
                  value: h,
                  child: Text('$h ${h == 1 ? 'hour' : 'hours'}'),
                ),
            ],
            onChanged: (v) => setState(() => hours = v!),
          ),
        ),
      ),
    );
    if (reason == null || !context.mounted) return;
    await runWithFeedback(
      context,
      () => backend.platform.grantSupportAccess(
        orgId,
        reason: reason,
        hours: hours,
      ),
      success:
          'Support access open for $hours ${hours == 1 ? 'hour' : 'hours'}.',
    );
  }
}
