import 'package:flutter/material.dart';
import 'package:pos_shared/pos_shared.dart';

import 'app.dart';
import 'location_picker_screen.dart';

/// The organizations this person belongs to, and a way in with an invite.
class OrgPickerScreen extends StatelessWidget {
  const OrgPickerScreen({super.key, required this.uid});
  final String uid;

  @override
  Widget build(BuildContext context) {
    final backend = BackendScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Your restaurants'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            onPressed: backend.auth.signOut,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('join'),
        onPressed: () => showDialog<void>(
          context: context,
          builder: (_) => const AcceptInviteDialog(),
        ),
        icon: const Icon(Icons.mail_outline),
        label: const Text('Join with invite link'),
      ),
      body: StreamBuilder<List<String>>(
        stream: backend.data.orgIdsOf(uid),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final ids = snap.data!;
          if (ids.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'You\'re not part of a restaurant yet. Ask your manager for an invite link, then tap "Join with invite link".',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView(
            children: [
              for (final id in ids)
                StreamBuilder<Organization?>(
                  stream: backend.data.org(id),
                  builder: (context, org) {
                    final o = org.data;
                    if (o == null) return const SizedBox.shrink();
                    return ListTile(
                      leading: const Icon(Icons.storefront),
                      title: Text(o.name),
                      subtitle: o.canWrite ? null : const Text('Read-only'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              LocationPickerScreen(org: o, uid: uid),
                        ),
                      ),
                    );
                  },
                ),
            ],
          );
        },
      ),
    );
  }
}

class AcceptInviteDialog extends StatefulWidget {
  const AcceptInviteDialog({super.key});

  @override
  State<AcceptInviteDialog> createState() => _AcceptInviteDialogState();
}

class _AcceptInviteDialogState extends State<AcceptInviteDialog> {
  final _link = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  Future<void> _accept() async {
    final link = InviteLink.parse(_link.text);
    if (link == null) {
      setState(() => _error = 'Paste the whole invite link.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await BackendScope.of(context).functions
          .acceptInvite(link.orgId, link.inviteId, link.token);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Join a restaurant'),
      content: TextField(
        key: const Key('invite-link'),
        controller: _link,
        decoration: InputDecoration(
          labelText: 'Invite link',
          errorText: _error,
          errorMaxLines: 3,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _accept,
          child: const Text('Join'),
        ),
      ],
    );
  }
}
