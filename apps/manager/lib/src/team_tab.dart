import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pos_shared/pos_shared.dart';

import 'app.dart';

class TeamTab extends StatelessWidget {
  const TeamTab({super.key, required this.store});
  final StoreContext store;

  Set<Role> get _assignable => store.role?.assignableRoles ?? const {};

  @override
  Widget build(BuildContext context) {
    final backend = BackendScope.of(context);
    final orgId = store.org.id, locId = store.location.id;
    return Scaffold(
      floatingActionButton: store.canWrite && _assignable.isNotEmpty
          ? FloatingActionButton.extended(
              key: const Key('invite'),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => InviteDialog(store: store),
              ),
              icon: const Icon(Icons.person_add_alt),
              label: const Text('Invite'),
            )
          : null,
      body: ListView(
        padding: const EdgeInsets.only(bottom: 88),
        children: [
          StreamBuilder<List<StaffEntry>>(
            stream: backend.data.staff(orgId, locId),
            builder: (context, snap) {
              final staff = [...?snap.data]
                ..sort((a, b) => a.label.compareTo(b.label));
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const ListTile(title: Text('Team')),
                  if (snap.hasData && staff.isEmpty)
                    const ListTile(
                      subtitle: Text('Nobody yet. Invite your team.'),
                    ),
                  for (final s in staff)
                    ListTile(
                      key: Key('staff-${s.uid}'),
                      leading: const Icon(Icons.person_outline),
                      title: Text(s.label),
                      subtitle: Text(s.role.label),
                      // You can manage someone only if you could give them their role.
                      trailing:
                          s.uid != store.uid && _assignable.contains(s.role)
                          ? IconButton(
                              tooltip: 'Change role',
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () => showDialog<void>(
                                context: context,
                                builder: (_) =>
                                    ChangeRoleDialog(store: store, staff: s),
                              ),
                            )
                          : null,
                    ),
                ],
              );
            },
          ),
          StreamBuilder<List<Invite>>(
            stream: backend.data.invites(orgId, locId),
            builder: (context, snap) {
              final pending = [
                for (final i in snap.data ?? const <Invite>[])
                  if (i.isPending) i,
              ];
              if (pending.isEmpty) return const SizedBox.shrink();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const ListTile(title: Text('Waiting to join')),
                  for (final i in pending)
                    ListTile(
                      leading: const Icon(Icons.schedule),
                      title: Text(i.displayName ?? i.email),
                      subtitle: Text('${i.role.label} · ${i.email}'),
                      trailing: _assignable.contains(i.role)
                          ? IconButton(
                              tooltip: 'Cancel invite',
                              icon: const Icon(Icons.close),
                              onPressed: () => runWithFeedback(
                                context,
                                () =>
                                    backend.functions.revokeInvite(orgId, i.id),
                                success: 'Invite cancelled',
                              ),
                            )
                          : null,
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class InviteDialog extends StatefulWidget {
  const InviteDialog({super.key, required this.store});
  final StoreContext store;

  @override
  State<InviteDialog> createState() => _InviteDialogState();
}

class _InviteDialogState extends State<InviteDialog> {
  final _email = TextEditingController();
  final _name = TextEditingController();
  late final List<Role> _roles = Role.values
      .where((r) => widget.store.role!.assignableRoles.contains(r))
      .toList();
  late Role _role = _roles.contains(Role.cashier) ? Role.cashier : _roles.first;
  bool _busy = false;
  String? _error;
  String? _link;

  @override
  void dispose() {
    _email.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final store = widget.store;
      final invite = await BackendScope.of(context).functions.inviteStaff(
        orgId: store.org.id,
        locationId: store.location.id,
        role: _role,
        email: _email.text.trim(),
        displayName: _name.text.trim().isEmpty ? null : _name.text.trim(),
      );
      setState(
        () => _link = InviteLink(
          orgId: store.org.id,
          inviteId: invite.inviteId,
          token: invite.token,
        ).toPath(),
      );
    } catch (e) {
      setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final link = _link;
    if (link != null) {
      return AlertDialog(
        title: const Text('Invite ready'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Send this link to ${_email.text.trim()}. It works once, for that email, for 7 days.',
            ),
            const SizedBox(height: 12),
            SelectableText(link, key: const Key('invite-link-text')),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: link)),
            child: const Text('Copy link'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ],
      );
    }
    return AlertDialog(
      title: Text('Invite to ${widget.store.location.name}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('invite-email'),
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Email'),
          ),
          TextField(
            key: const Key('invite-name'),
            controller: _name,
            decoration: const InputDecoration(labelText: 'Name (optional)'),
          ),
          DropdownButtonFormField<Role>(
            key: const Key('invite-role'),
            initialValue: _role,
            decoration: InputDecoration(
              labelText: 'Role',
              errorText: _error,
              errorMaxLines: 3,
            ),
            items: [
              for (final r in _roles)
                DropdownMenuItem(value: r, child: Text(r.label)),
            ],
            onChanged: (r) => setState(() => _role = r!),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _send,
          child: const Text('Create invite'),
        ),
      ],
    );
  }
}

class ChangeRoleDialog extends StatefulWidget {
  const ChangeRoleDialog({super.key, required this.store, required this.staff});
  final StoreContext store;
  final StaffEntry staff;

  @override
  State<ChangeRoleDialog> createState() => _ChangeRoleDialogState();
}

class _ChangeRoleDialogState extends State<ChangeRoleDialog> {
  late Role _role = widget.staff.role;

  Future<void> _apply(Role? role) async {
    final store = widget.store;
    final ok = await runWithFeedback(
      context,
      () => BackendScope.of(context).functions.setMemberRole(
        store.org.id,
        store.location.id,
        widget.staff.uid,
        role,
      ),
      success: role == null
          ? '${widget.staff.label} removed from ${store.location.name}'
          : 'Role updated',
    );
    if (ok && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final roles = Role.values
        .where((r) => widget.store.role!.assignableRoles.contains(r))
        .toList();
    return AlertDialog(
      title: Text(widget.staff.label),
      content: DropdownButtonFormField<Role>(
        initialValue: _role,
        decoration: const InputDecoration(labelText: 'Role at this store'),
        items: [
          for (final r in roles)
            DropdownMenuItem(value: r, child: Text(r.label)),
        ],
        onChanged: (r) => setState(() => _role = r!),
      ),
      actions: [
        TextButton(
          key: const Key('remove-staff'),
          onPressed: () => _apply(null),
          child: const Text('Remove from store'),
        ),
        FilledButton(
          onPressed: _role == widget.staff.role ? null : () => _apply(_role),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
