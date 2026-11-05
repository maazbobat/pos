import 'package:flutter/material.dart';
import 'package:pos_shared/pos_shared.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app.dart';

typedef UrlOpener = Future<void> Function(Uri url);

Future<void> openInBrowser(Uri url) async {
  await launchUrl(url, webOnlyWindowName: '_self');
}

String _date(DateTime? d) {
  if (d == null) return '-';
  final l = d.toLocal();
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[l.month - 1]} ${l.day}, ${l.year}';
}

String _dateTime(DateTime d) {
  final l = d.toLocal();
  return '${_date(l)} ${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

/// Owners: the plan, paying through Stripe, who from the platform has
/// support access, and the org's audit log. Payment details never touch
/// this app; Stripe's own pages handle them.
class BillingScreen extends StatelessWidget {
  const BillingScreen({
    super.key,
    required this.org,
    this.openUrl = openInBrowser,
  });
  final Organization org;
  final UrlOpener openUrl;

  @override
  Widget build(BuildContext context) {
    final billing = BackendScope.of(context).billing;
    return Scaffold(
      appBar: AppBar(title: const Text('Billing and access')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          StreamBuilder<Subscription?>(
            stream: billing.subscription(org.id),
            builder: (context, snap) {
              final sub = snap.data;
              if (sub == null) {
                return const Center(child: CircularProgressIndicator());
              }
              return _PlanCard(org: org, sub: sub, openUrl: openUrl);
            },
          ),
          const SizedBox(height: 16),
          _SupportAccessCard(orgId: org.id),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Activity',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  StreamBuilder<List<AuditEntry>>(
                    stream: billing.auditLog(org.id),
                    builder: (context, snap) {
                      final entries = snap.data ?? const [];
                      if (entries.isEmpty) {
                        return const Text('Nothing recorded yet.');
                      }
                      return Column(
                        children: [
                          for (final e in entries)
                            ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(e.action),
                              subtitle: Text(
                                [
                                  _date(e.createdAt),
                                  if (e.actorKind == 'platform_admin')
                                    'by the platform'
                                  else
                                    e.actorUid,
                                  if (e.reason != null) '"${e.reason}"',
                                ].join(' · '),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.org,
    required this.sub,
    required this.openUrl,
  });
  final Organization org;
  final Subscription sub;
  final UrlOpener openUrl;

  String get _status {
    if (sub.readOnly) {
      return 'Your account is read-only. You and your staff can still see and export '
          'everything, but nothing can be changed until the subscription is paid.';
    }
    if (sub.inGrace) {
      return 'Your last payment didn\'t go through. Everything keeps working until '
          '${_date(sub.graceEndsAt)}; after that the account becomes read-only.';
    }
    return switch (sub.source) {
      BillingSource.trial => 'Free trial until ${_date(sub.trialEndsAt)}.',
      BillingSource.manual =>
        'Your plan is set up by our team. Contact support to change it.',
      BillingSource.stripe =>
        sub.cancelAtPeriodEnd
            ? 'Cancelled. Active until ${_date(sub.currentPeriodEnd)}.'
            : 'Renews ${_date(sub.currentPeriodEnd)}.',
    };
  }

  Future<void> _go(BuildContext context, Future<Uri> Function() get) async {
    Uri? url;
    final ok = await runWithFeedback(context, () async => url = await get());
    if (ok && url != null) await openUrl(url!);
  }

  @override
  Widget build(BuildContext context) {
    final billing = BackendScope.of(context).billing;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: sub.readOnly
          ? scheme.errorContainer
          : sub.inGrace
          ? scheme.tertiaryContainer
          : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              sub.plan.label,
              key: const Key('plan-name'),
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 4),
            Text(_status, key: const Key('plan-status')),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (sub.canStartCheckout)
                  for (final plan in Plan.selfServe)
                    FilledButton(
                      key: Key('choose-${plan.name}'),
                      onPressed: () => _go(
                        context,
                        () => billing.startCheckout(org.id, plan),
                      ),
                      child: Text('Choose ${plan.label}'),
                    ),
                if (sub.hasStripeCustomer && sub.source == BillingSource.stripe)
                  OutlinedButton(
                    key: const Key('manage-billing'),
                    onPressed: () =>
                        _go(context, () => billing.openBillingPortal(org.id)),
                    child: const Text(
                      'Payment method, invoices and cancelling',
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SupportAccessCard extends StatelessWidget {
  const _SupportAccessCard({required this.orgId});
  final String orgId;

  @override
  Widget build(BuildContext context) {
    final billing = BackendScope.of(context).billing;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: StreamBuilder<List<SupportGrant>>(
          stream: billing.supportGrants(orgId),
          builder: (context, snap) {
            final active = (snap.data ?? const [])
                .where((g) => g.isActive)
                .toList();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Support access',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                if (active.isEmpty)
                  const Text(
                    'Our support team can\'t see your data. When you ask for help, '
                    'they open read-only access for a few hours, and it shows here.',
                  )
                else
                  for (final g in active)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.support_agent),
                      title: Text(
                        '${g.adminEmail ?? 'Support'} can read your data until ${_dateTime(g.expiresAt)}',
                      ),
                      subtitle: Text('Reason: ${g.reason}'),
                      trailing: TextButton(
                        key: Key('end-${g.adminUid}'),
                        onPressed: () => runWithFeedback(
                          context,
                          () => billing.revokeSupportAccess(orgId, g.adminUid),
                          success: 'Support access ended.',
                        ),
                        child: const Text('End now'),
                      ),
                    ),
              ],
            );
          },
        ),
      ),
    );
  }
}
