import 'package:flutter/material.dart';
import 'package:pos_shared/pos_shared.dart';

import 'org_picker_screen.dart';
import 'sign_in_screen.dart';

/// Owners and managers run their stores from here: staff, devices, menu.
/// What each person can do is enforced by the rules and Functions; the app
/// only hides what their role can't use.
class ManagerApp extends StatelessWidget {
  const ManagerApp({super.key, required this.backend});
  final Backend backend;

  @override
  Widget build(BuildContext context) {
    return BackendScope(
      backend: backend,
      child: MaterialApp(
        title: 'Manager',
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
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
                ? const SignInScreen()
                : OrgPickerScreen(key: ValueKey(uid), uid: uid);
          },
        ),
      ),
    );
  }
}

class BackendScope extends InheritedWidget {
  const BackendScope({super.key, required this.backend, required super.child});
  final Backend backend;

  static Backend of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BackendScope>()!.backend;

  @override
  bool updateShouldNotify(BackendScope old) => backend != old.backend;
}

String errorText(Object error) =>
    error is BackendException || error is MenuValidationError
    ? error.toString()
    : 'Something went wrong. Check the connection and try again.';

/// Runs [action], showing its error in a snack bar. Returns whether it worked.
Future<bool> runWithFeedback(
  BuildContext context,
  Future<void> Function() action, {
  String? success,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await action();
    if (success != null) {
      messenger.showSnackBar(SnackBar(content: Text(success)));
    }
    return true;
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(errorText(e))));
    return false;
  }
}

/// Everything a screen inside one store needs to know.
class StoreContext {
  const StoreContext({
    required this.org,
    required this.location,
    required this.member,
    required this.uid,
  });
  final Organization org;
  final Location location;
  final Membership member;
  final String uid;

  Role? get role => member.roleAt(location.id);
  bool get isOwner => member.isOwner;
  bool get isManager => role != null && Role.management.contains(role);
  bool get canWrite => org.canWrite && location.status == LocationStatus.active;
}
