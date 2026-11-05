import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_manager/src/app.dart';
import 'package:pos_manager/src/billing_screen.dart';
import 'package:pos_shared/pos_shared.dart';
import 'package:pos_shared/testing.dart';

import 'manager_app_test.dart' show backendFor;

const org = Organization(
  id: 'org-a',
  name: 'Maple Tea Co',
  type: OrgType.franchise,
  status: OrgStatus.active,
  accessLevel: AccessLevel.full,
);

Future<List<Uri>> pumpBilling(WidgetTester tester, FakeBackend fake) async {
  final opened = <Uri>[];
  tester.view.physicalSize = const Size(1000, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    BackendScope(
      backend: fake.backend,
      child: MaterialApp(
        home: BillingScreen(org: org, openUrl: (u) async => opened.add(u)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return opened;
}

void main() {
  testWidgets('a trial owner picks a plan and goes to Stripe Checkout', (
    tester,
  ) async {
    final fake = FakeBackend();
    fake.billing.subscriptions['org-a'] = Subscription(
      plan: Plan.trial,
      source: BillingSource.trial,
      status: BillingStatus.trialing,
      readOnly: false,
      trialEndsAt: DateTime(2026, 12, 5),
    );
    final opened = await pumpBilling(tester, fake);
    expect(find.text('Free trial until Dec 5, 2026.'), findsOneWidget);
    expect(find.byKey(const Key('manage-billing')), findsNothing);

    await tester.tap(find.byKey(const Key('choose-professional')));
    await tester.pumpAndSettle();
    expect(fake.billing.calls, ['startCheckout:org-a:professional']);
    expect(opened, [Uri.parse('https://checkout.stripe.test/professional')]);
  });

  testWidgets(
    'a lapsed owner sees the grace date; a read-only one can still pay',
    (tester) async {
      final fake = FakeBackend();
      fake.billing.subscriptions['org-a'] = Subscription(
        plan: Plan.starter,
        source: BillingSource.stripe,
        status: BillingStatus.canceled,
        readOnly: false,
        graceEndsAt: DateTime(2026, 11, 19),
        hasStripeCustomer: true,
      );
      await pumpBilling(tester, fake);
      expect(
        find.textContaining('keeps working until Nov 19, 2026'),
        findsOneWidget,
      );

      fake.billing.subscriptions['org-a'] = const Subscription(
        plan: Plan.starter,
        source: BillingSource.stripe,
        status: BillingStatus.canceled,
        readOnly: true,
        hasStripeCustomer: true,
      );
      fake.billing.notify();
      await tester.pumpAndSettle();
      expect(
        find.textContaining('still see and export everything'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('choose-starter')), findsOneWidget);

      await tester.tap(find.byKey(const Key('manage-billing')));
      await tester.pumpAndSettle();
      expect(fake.billing.calls, ['openBillingPortal:org-a']);
    },
  );

  testWidgets('a paying owner manages billing in the portal, not Checkout', (
    tester,
  ) async {
    final fake = FakeBackend();
    fake.billing.subscriptions['org-a'] = Subscription(
      plan: Plan.professional,
      source: BillingSource.stripe,
      status: BillingStatus.active,
      readOnly: false,
      currentPeriodEnd: DateTime(2026, 12, 1),
      hasStripeCustomer: true,
    );
    await pumpBilling(tester, fake);
    expect(find.text('Renews Dec 1, 2026.'), findsOneWidget);
    expect(find.byKey(const Key('choose-starter')), findsNothing);
    expect(find.byKey(const Key('manage-billing')), findsOneWidget);
  });

  testWidgets('the owner sees support access and can end it', (tester) async {
    final fake = FakeBackend();
    fake.billing
      ..subscriptions['org-a'] = const Subscription(
        plan: Plan.franchise,
        source: BillingSource.manual,
        status: BillingStatus.active,
        readOnly: false,
      )
      ..grants['org-a'] = [
        SupportGrant(
          adminUid: 'platform-admin',
          adminEmail: 'support@platform.example',
          reason: 'Ticket 42',
          expiresAt: DateTime.now().add(const Duration(hours: 2)),
        ),
      ]
      ..audit['org-a'] = [
        const AuditEntry(
          id: 'e1',
          action: 'support.access_granted',
          actorUid: 'platform-admin',
          actorKind: 'platform_admin',
          reason: 'Ticket 42',
        ),
      ];
    await pumpBilling(tester, fake);
    expect(find.textContaining('set up by our team'), findsOneWidget);
    expect(
      find.textContaining('support@platform.example can read your data'),
      findsOneWidget,
    );
    expect(find.text('support.access_granted'), findsOneWidget);

    await tester.tap(find.byKey(const Key('end-platform-admin')));
    await tester.pumpAndSettle();
    expect(fake.billing.calls, ['revokeSupportAccess:org-a:platform-admin']);
    expect(find.textContaining('can\'t see your data'), findsOneWidget);
  });

  testWidgets('only owners get the billing button; read-only shows a banner', (
    tester,
  ) async {
    final manager = backendFor('me', role: Role.storeManager);
    await tester.pumpWidget(ManagerApp(backend: manager.backend));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Maple Tea Co'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('billing')), findsNothing);

    final owner = backendFor('boss', owner: true);
    owner.data.orgs['org-a'] = const Organization(
      id: 'org-a',
      name: 'Maple Tea Co',
      type: OrgType.franchise,
      status: OrgStatus.active,
      accessLevel: AccessLevel.readOnly,
    );
    await tester.pumpWidget(
      ManagerApp(key: UniqueKey(), backend: owner.backend),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Maple Tea Co'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('billing')), findsOneWidget);
    expect(find.byKey(const Key('read-only-banner')), findsOneWidget);
    expect(find.byKey(const Key('add-location')), findsNothing);
  });
}
