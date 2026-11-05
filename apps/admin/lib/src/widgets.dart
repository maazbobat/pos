import 'package:flutter/material.dart';
import 'package:pos_shared/pos_shared.dart';

String fmtDate(DateTime? d) {
  if (d == null) return '-';
  final l = d.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
}

String errorText(Object e) =>
    e is BackendException ? e.message : 'Something went wrong. Try again.';

/// Runs [action] and reports the outcome in a snack bar.
Future<bool> runWithFeedback(
  BuildContext context,
  Future<void> Function() action, {
  required String success,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await action();
    messenger.showSnackBar(SnackBar(content: Text(success)));
    return true;
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(errorText(e))));
    return false;
  }
}

/// A short status label for a tenant: what support needs to know first.
String tenantState(TenantSummary t) {
  if (t.suspended) return 'Suspended';
  if (t.readOnly) return 'Read-only';
  if (t.graceEndsAt != null) return 'Grace until ${fmtDate(t.graceEndsAt)}';
  if (t.billingSource == BillingSource.trial) {
    return 'Trial until ${fmtDate(t.trialEndsAt)}';
  }
  return 'Active';
}

/// A dialog that asks for a reason (every platform action needs one) and
/// any [extra] fields. Returns the reason, or null when cancelled.
class ReasonDialog extends StatefulWidget {
  const ReasonDialog({
    super.key,
    required this.title,
    required this.confirmLabel,
    this.extra,
    this.minLength = 5,
    this.destructive = false,
  });

  final String title;
  final String confirmLabel;
  final Widget? extra;
  final int minLength;
  final bool destructive;

  @override
  State<ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<ReasonDialog> {
  final _reason = TextEditingController();

  @override
  void initState() {
    super.initState();
    _reason.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ok = _reason.text.trim().length >= widget.minLength;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ?widget.extra,
            TextField(
              key: const Key('reason'),
              controller: _reason,
              maxLength: 300,
              decoration: const InputDecoration(
                labelText: 'Reason',
                helperText: 'Recorded in the audit log the owner can read.',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('confirm'),
          style: widget.destructive
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                )
              : null,
          onPressed: ok
              ? () => Navigator.pop(context, _reason.text.trim())
              : null,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

class AuditList extends StatelessWidget {
  const AuditList({super.key, required this.entries, this.showOrg = true});
  final List<AuditEntry> entries;
  final bool showOrg;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('Nothing recorded yet.'),
      );
    }
    return Column(
      children: [
        for (final e in entries)
          ListTile(
            dense: true,
            title: Text(e.action),
            subtitle: Text(
              [
                fmtDate(e.createdAt),
                '${e.actorKind}: ${e.actorUid}',
                if (showOrg && e.orgId != null) e.orgId!,
                if (e.reason != null) '"${e.reason}"',
              ].join(' · '),
            ),
          ),
      ],
    );
  }
}
