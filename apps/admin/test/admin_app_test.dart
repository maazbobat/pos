import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_admin/src/app.dart';
import 'package:pos_shared/pos_shared.dart';
import 'package:pos_shared/testing.dart';

void main() {
  testWidgets('creates a restaurant and shows the owner invite link', (
    tester,
  ) async {
    final fake = FakeBackend()..auth.signInAs('platform-admin');
    await tester.pumpWidget(AdminApp(backend: fake.backend));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('org-name')), 'Harbour Grill');
    await tester.enterText(
      find.byKey(const Key('owner-email')),
      'pat@harbour.example',
    );
    await tester.tap(find.text('Create and invite owner'));
    await tester.pumpAndSettle();

    expect(fake.functions.calls, [
      'createOrganization:Harbour Grill:pat@harbour.example',
    ]);
    final link = tester
        .widget<SelectableText>(find.byKey(const Key('owner-link')))
        .data!;
    expect(InviteLink.parse(link)?.orgId, 'org-new');
  });
}
