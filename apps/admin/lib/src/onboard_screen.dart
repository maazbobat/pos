import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pos_shared/pos_shared.dart';

class CreateOrgScreen extends StatefulWidget {
  const CreateOrgScreen({super.key, required this.backend});
  final Backend backend;

  @override
  State<CreateOrgScreen> createState() => _CreateOrgScreenState();
}

class _CreateOrgScreenState extends State<CreateOrgScreen> {
  final _name = TextEditingController();
  final _ownerEmail = TextEditingController();
  final _ownerName = TextEditingController();
  OrgType _type = OrgType.independent;
  bool _busy = false;
  String? _error;
  String? _result;

  @override
  void dispose() {
    _name.dispose();
    _ownerEmail.dispose();
    _ownerName.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });
    try {
      final created = await widget.backend.functions.createOrganization(
        name: _name.text.trim(),
        type: _type,
        ownerEmail: _ownerEmail.text.trim(),
        ownerName: _ownerName.text.trim().isEmpty
            ? null
            : _ownerName.text.trim(),
      );
      setState(
        () => _result = InviteLink(
          orgId: created.orgId,
          inviteId: created.ownerInvite.inviteId,
          token: created.ownerInvite.token,
        ).toPath(),
      );
    } catch (e) {
      setState(
        () => _error = e is BackendException
            ? e.message
            : 'Something went wrong.',
      );
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Scaffold(
      appBar: AppBar(title: const Text('Onboard a restaurant')),
      body: Center(
        child: SizedBox(
          width: 480,
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              TextField(
                key: const Key('org-name'),
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Restaurant or company name',
                ),
              ),
              DropdownButtonFormField<OrgType>(
                initialValue: _type,
                decoration: const InputDecoration(labelText: 'Type'),
                items: const [
                  DropdownMenuItem(
                    value: OrgType.independent,
                    child: Text('Independent'),
                  ),
                  DropdownMenuItem(value: OrgType.chain, child: Text('Chain')),
                  DropdownMenuItem(
                    value: OrgType.franchise,
                    child: Text('Franchise'),
                  ),
                ],
                onChanged: (v) => setState(() => _type = v!),
              ),
              TextField(
                key: const Key('owner-email'),
                controller: _ownerEmail,
                decoration: const InputDecoration(labelText: 'Owner email'),
              ),
              TextField(
                key: const Key('owner-name'),
                controller: _ownerName,
                decoration: InputDecoration(
                  labelText: 'Owner name (optional)',
                  errorText: _error,
                  errorMaxLines: 3,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy ? null : _create,
                child: const Text('Create and invite owner'),
              ),
              if (result != null) ...[
                const SizedBox(height: 24),
                const Text(
                  'Send this link to the owner. It works once, for that email, for 7 days:',
                ),
                SelectableText(result, key: const Key('owner-link')),
                TextButton(
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: result)),
                  child: const Text('Copy link'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
