import 'package:flutter/material.dart';
import 'package:pos_shared/pos_shared.dart';

import 'audit_page.dart';
import 'health_page.dart';
import 'onboard_screen.dart';
import 'tenants_page.dart';

/// Platform admin portal: tenants, their plans and status, support access,
/// the platform audit log and health. Only accounts in `platformAdmins` get
/// in, and every action is re-checked and audited server-side. Tenant data
/// itself stays out of reach without a support grant.
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
          final uid = snap.data;
          return uid == null
              ? _SignIn(backend: backend)
              : _AdminGate(key: ValueKey(uid), backend: backend, uid: uid);
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

/// Signed-in accounts that aren't platform admins see nothing else.
class _AdminGate extends StatelessWidget {
  const _AdminGate({super.key, required this.backend, required this.uid});
  final Backend backend;
  final String uid;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: backend.platform.isPlatformAdmin(uid),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snap.data != true) {
          return Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('This account isn\'t a platform admin.'),
                  TextButton(
                    onPressed: backend.auth.signOut,
                    child: const Text('Sign out'),
                  ),
                ],
              ),
            ),
          );
        }
        return AdminHome(backend: backend, uid: uid);
      },
    );
  }
}

class AdminHome extends StatefulWidget {
  const AdminHome({super.key, required this.backend, required this.uid});
  final Backend backend;
  final String uid;

  @override
  State<AdminHome> createState() => _AdminHomeState();
}

class _AdminHomeState extends State<AdminHome> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      TenantsPage(backend: widget.backend, uid: widget.uid),
      HealthPage(backend: widget.backend),
      AuditPage(backend: widget.backend),
      CreateOrgScreen(backend: widget.backend),
    ];
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _index,
            labelType: NavigationRailLabelType.all,
            onDestinationSelected: (i) => setState(() => _index = i),
            trailing: IconButton(
              tooltip: 'Sign out',
              onPressed: widget.backend.auth.signOut,
              icon: const Icon(Icons.logout),
            ),
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.storefront_outlined),
                label: Text('Tenants'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.monitor_heart_outlined),
                label: Text('Health'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.history),
                label: Text('Audit log'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.add_business_outlined),
                label: Text('Onboard'),
              ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: pages[_index]),
        ],
      ),
    );
  }
}
