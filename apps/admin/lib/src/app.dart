import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pos_shared/pos_shared.dart';

/// Platform admin portal. For now: onboard a restaurant and hand its owner
/// an invite. Only accounts in `platformAdmins` get past the server check;
/// tenant management, billing and support grants come in roadmap step 3.
class AdminApp extends StatelessWidget {
  const AdminApp({super.key, required this.backend});
  final Backend backend;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Platform admin',
      theme: ThemeData(colorSchemeSeed: Colors.blueGrey, useMaterial3: true),
      home: StreamBuilder<String?>(
        stream: backend.auth.uidChanges(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          return snap.data == null
              ? _SignIn(backend: backend)
              : CreateOrgScreen(backend: backend);
        },
      ),
    );
  }
}

class _SignIn extends StatefulWidget {
  const _SignIn({required this.backend});
  final Backend backend;

  @override
  State<_SignIn> createState() => _SignInState();
}

class _SignInState extends State<_SignIn> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    try {
      await widget.backend.auth.signInWithEmail(
        _email.text.trim(),
        _password.text,
      );
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Platform admin',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              TextField(
                key: const Key('email'),
                controller: _email,
                decoration: const InputDecoration(labelText: 'Email'),
              ),
              TextField(
                key: const Key('password'),
                controller: _password,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'Password',
                  errorText: _error,
                ),
                onSubmitted: (_) => _signIn(),
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _signIn, child: const Text('Sign in')),
            ],
          ),
        ),
      ),
    );
  }
}

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
      appBar: AppBar(
        title: const Text('Onboard a restaurant'),
        actions: [
          IconButton(
            onPressed: widget.backend.auth.signOut,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
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
