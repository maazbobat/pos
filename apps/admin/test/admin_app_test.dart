import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_admin/src/app.dart';
import 'package:pos_shared/pos_shared.dart';
import 'package:pos_shared/testing.dart';

FakeBackend adminBackend() {
  final fake = FakeBackend()..auth.signInAs('platform-admin');
  fake.platform
    ..admins.add('platform-admin')
    ..tenantsById['org-a'] = TenantSummary(
      orgId: 'org-a',
      name: 'Maple Tea Co',
      suspended: false,
      readOnly: false,
      plan: Plan.trial,
      billingStatus: BillingStatus.trialing,
      billingSource: BillingSource.trial,
      ownerEmail: 'owner@maple.example',
      locationCount: 2,
      trialEndsAt: DateTime(2026, 12, 5),
    )
    ..tenantsById['org-b'] = const TenantSummary(
      orgId: 'org-b',
      name: 'Harbour Grill',
      suspended: false,
      readOnly: true,
      plan: Plan.starter,
      billingStatus: BillingStatus.canceled,
      billingSource: BillingSource.stripe,
    );
  return fake;
}

Future<void> pumpAdmin(WidgetTester tester, FakeBackend fake) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(AdminApp(backend: fake.backend));
  await tester.pumpAndSettle();
}

Future<void> giveReason(WidgetTester tester, String reason) async {
  await tester.enterText(find.byKey(const Key('reason')), reason);
  await tester.pump();
  await tester.tap(find.byKey(const Key('confirm')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('keeps out accounts that are not platform admins', (
    tester,
  ) async {
    final fake = FakeBackend()..auth.signInAs('someone');
    await pumpAdmin(tester, fake);
    expect(find.text('This account isn\'t a platform admin.'), findsOneWidget);
    expect(find.text('Tenants'), findsNothing);
  });

  testWidgets('lists tenants and filters the ones that need attention', (
    tester,
  ) async {
    await pumpAdmin(tester, adminBackend());
    expect(find.text('Maple Tea Co'), findsOneWidget);
    expect(find.text('Harbour Grill'), findsOneWidget);
    expect(find.text('Read-only'), findsOneWidget);

    await tester.tap(find.text('Needs attention'));
    await tester.pumpAndSettle();
    expect(find.text('Maple Tea Co'), findsNothing);
    expect(find.text('Harbour Grill'), findsOneWidget);

    await tester.tap(find.textContaining('All ('));
    await tester.enterText(find.byKey(const Key('tenant-search')), 'maple');
    await tester.pumpAndSettle();
    expect(find.text('Harbour Grill'), findsNothing);
  });

  testWidgets('opens support access with a reason and can end it', (
    tester,
  ) async {
    final fake = adminBackend();
    await pumpAdmin(tester, fake);
    await tester.tap(find.byKey(const Key('tenant-org-a')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('open-support')));
    await tester.pumpAndSettle();
    // Too short a reason can't be submitted.
    await tester.enterText(find.byKey(const Key('reason')), 'hi');
    await tester.pump();
    expect(
      tester.widget<FilledButton>(find.byKey(const Key('confirm'))).onPressed,
      isNull,
    );
    await giveReason(tester, 'Ticket 42: menu sync');
    expect(fake.platform.calls, [
      'grantSupportAccess:org-a:2:Ticket 42: menu sync',
    ]);
    expect(find.textContaining('You can read this tenant'), findsOneWidget);

    await tester.tap(find.byKey(const Key('end-support')));
    await tester.pumpAndSettle();
    expect(fake.platform.calls.last, 'revokeMySupportAccess:org-a');
    expect(find.byKey(const Key('open-support')), findsOneWidget);
  });

  testWidgets('sets a plan, extends a trial and suspends, each with a reason', (
    tester,
  ) async {
    final fake = adminBackend();
    await pumpAdmin(tester, fake);
    await tester.tap(find.byKey(const Key('tenant-org-a')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('set-plan')));
    await tester.pumpAndSettle();
    await giveReason(tester, 'Signed franchise deal');

    await tester.tap(find.byKey(const Key('extend-trial')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('trial-days')), '21');
    await giveReason(tester, 'Pilot');

    await tester.ensureVisible(find.byKey(const Key('suspend')));
    await tester.tap(find.byKey(const Key('suspend')));
    await tester.pumpAndSettle();
    await giveReason(tester, 'Chargeback fraud');

    expect(fake.platform.calls, [
      'setManualPlan:org-a:franchise:true:Signed franchise deal',
      'extendTrial:org-a:21:Pilot',
      'setOrgSuspended:org-a:true:Chargeback fraud',
    ]);
  });

  testWidgets('shows health and resolves an incident', (tester) async {
    final fake = adminBackend();
    fake.platform
      ..healthSummary = const HealthSummary(
        staleDevices: 3,
        staleDevicesByOrg: {'org-a': 3},
        printerProblems: 0,
        stuckPayments: 1,
        openIncidents: 1,
      )
      ..incidents.add(
        const Incident(
          id: 'inc-1',
          kind: 'payment_stuck',
          message: 'Card payment still pending',
          orgId: 'org-a',
        ),
      );
    await pumpAdmin(tester, fake);
    await tester.tap(find.text('Health'));
    await tester.pumpAndSettle();
    expect(find.text('Devices offline'), findsOneWidget);
    expect(find.text('Card payment still pending'), findsOneWidget);

    await tester.tap(find.text('Resolve'));
    await tester.pumpAndSettle();
    await giveReason(tester, 'Guest paid cash');
    expect(fake.platform.calls, ['resolveIncident:inc-1:Guest paid cash']);
    expect(find.text('Card payment still pending'), findsNothing);
  });

  testWidgets('creates a restaurant and shows the owner invite link', (
    tester,
  ) async {
    final fake = adminBackend();
    await pumpAdmin(tester, fake);
    await tester.tap(find.text('Onboard'));
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
