import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pos_manager/src/app.dart';
import 'package:pos_shared/pos_shared.dart';
import 'package:pos_shared/testing.dart';

/// A signed-in [uid] with [role] at Cambridge (or owner when [owner]).
FakeBackend backendFor(String uid, {Role? role, bool owner = false}) {
  final fake = FakeBackend();
  fake.data
    ..orgIds[uid] = ['org-a']
    ..orgs['org-a'] = const Organization(
      id: 'org-a',
      name: 'Maple Tea Co',
      type: OrgType.franchise,
      status: OrgStatus.active,
      accessLevel: AccessLevel.full,
    )
    ..locations['org-a/cambridge'] = const Location(
      id: 'cambridge',
      orgId: 'org-a',
      name: 'Cambridge',
      status: LocationStatus.active,
      timezone: 'America/Toronto',
      province: 'ON',
    )
    ..members['org-a/$uid'] = Membership(
      uid: uid,
      orgId: 'org-a',
      kind: MemberKind.user,
      status: MemberStatus.active,
      isOwner: owner,
      locationRoles: role == null ? const {} : {'cambridge': role},
    )
    ..staffByLocation['cambridge'] = [
      StaffEntry(uid: uid, role: role ?? Role.storeManager, displayName: 'Me'),
      const StaffEntry(uid: 'sam', role: Role.cashier, displayName: 'Sam'),
      const StaffEntry(uid: 'mo', role: Role.storeManager, displayName: 'Mo'),
    ]
    ..devicesByLocation['cambridge'] = [
      const Device(
        id: 'dev_1',
        orgId: 'org-a',
        locationId: 'cambridge',
        type: DeviceType.pos,
        name: 'Front counter',
        status: DeviceStatus.active,
      ),
    ]
    ..categories.add(const MenuCategory(id: 'tea', orgId: 'org-a', name: 'Tea'))
    ..items.add(
      const MenuItem(
        id: 'taro',
        orgId: 'org-a',
        name: 'Taro milk tea',
        categoryId: 'tea',
        priceCents: 625,
      ),
    );
  fake.auth.signInAs(uid, email: '$uid@example.com');
  return fake;
}

Future<void> openCambridge(WidgetTester tester, FakeBackend fake) async {
  await tester.pumpWidget(ManagerApp(backend: fake.backend));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Maple Tea Co'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Cambridge'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('sign in, then join a restaurant with an invite link', (
    tester,
  ) async {
    final fake = FakeBackend();
    fake.auth.accounts['sam@example.com'] = 'secret1';
    await tester.pumpWidget(ManagerApp(backend: fake.backend));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('email')), 'sam@example.com');
    await tester.enterText(find.byKey(const Key('password')), 'wrong');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('That email and password don\'t match.'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('password')), 'secret1');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
    expect(find.textContaining('not part of a restaurant yet'), findsOneWidget);

    await tester.tap(find.byKey(const Key('join')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('invite-link')), 'not a link');
    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();
    expect(find.text('Paste the whole invite link.'), findsOneWidget);

    const link = InviteLink(orgId: 'org-a', inviteId: 'inv-9', token: 'tok/+=');
    await tester.enterText(
      find.byKey(const Key('invite-link')),
      'https://pos.example${link.toPath()}',
    );
    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();
    expect(fake.functions.calls, ['acceptInvite:org-a:inv-9:tok/+=']);
  });

  testWidgets('a store manager can invite only the roles they can give', (
    tester,
  ) async {
    final fake = backendFor('me', role: Role.storeManager);
    await openCambridge(tester, fake);
    expect(find.text('Team'), findsWidgets);

    // Sam (cashier) can be managed; Mo (another manager) and yourself can't.
    expect(
      find.descendant(
        of: find.byKey(const Key('staff-sam')),
        matching: find.byIcon(Icons.edit_outlined),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('staff-mo')),
        matching: find.byIcon(Icons.edit_outlined),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('staff-me')),
        matching: find.byIcon(Icons.edit_outlined),
      ),
      findsNothing,
    );

    await tester.tap(find.byKey(const Key('invite')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('invite-role')));
    await tester.pumpAndSettle();
    expect(find.text('Kitchen').hitTestable(), findsOneWidget);
    expect(find.text('Inventory manager').hitTestable(), findsOneWidget);
    expect(find.text('Store manager').hitTestable(), findsNothing);
    expect(find.text('Accountant').hitTestable(), findsNothing);
    await tester.tap(find.text('Kitchen').hitTestable());
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('invite-email')),
      'new@example.com',
    );
    await tester.tap(find.text('Create invite'));
    await tester.pumpAndSettle();
    expect(fake.functions.calls, [
      'inviteStaff:cambridge:kitchen:new@example.com',
    ]);
    final link = tester
        .widget<SelectableText>(find.byKey(const Key('invite-link-text')))
        .data!;
    final parsed = InviteLink.parse(link)!;
    expect(
      (parsed.orgId, parsed.inviteId, parsed.token),
      ('org-a', 'inv-1', 'tok-1'),
    );
  });

  testWidgets('removing a staff member goes through setMemberRole', (
    tester,
  ) async {
    final fake = backendFor('me', role: Role.storeManager);
    await openCambridge(tester, fake);
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('staff-sam')),
        matching: find.byIcon(Icons.edit_outlined),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('remove-staff')));
    await tester.pumpAndSettle();
    expect(fake.functions.calls, ['setMemberRole:cambridge:sam:null']);
  });

  testWidgets('pairing shows a code; revoking asks first', (tester) async {
    final fake = backendFor('me', role: Role.storeManager);
    await openCambridge(tester, fake);
    await tester.tap(find.text('Devices'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('pair-device')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kitchen display'));
    await tester.enterText(
      find.byKey(const Key('device-name')),
      'Grill screen',
    );
    await tester.tap(find.text('Get code'));
    await tester.pumpAndSettle();
    expect(fake.functions.calls, [
      'createPairingCode:cambridge:kds:Grill screen',
    ]);
    expect(find.text('7KQM-3XWP'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Revoke'));
    await tester.pumpAndSettle();
    expect(find.text('Revoke Front counter?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Revoke'));
    await tester.pumpAndSettle();
    expect(fake.functions.calls.last, 'revokeDevice:dev_1');
  });

  testWidgets(
    'an owner adds a menu item; a bad price is caught before saving',
    (tester) async {
      final fake = backendFor('boss', owner: true);
      await openCambridge(tester, fake);
      await tester.tap(find.text('Menu'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('add-item')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('item-name')), 'Mango slush');
      await tester.enterText(find.byKey(const Key('item-price')), '5.555');
      await tester.tap(find.byKey(const Key('save-item')));
      await tester.pumpAndSettle();
      expect(find.text('Enter a price like 5.50'), findsOneWidget);
      expect(fake.data.writes, isEmpty);

      await tester.enterText(find.byKey(const Key('item-price')), '5.75');
      await tester.tap(find.byKey(const Key('save-item')));
      await tester.pumpAndSettle();
      expect(fake.data.writes, ['menuItem:item-2']);
      expect(fake.data.items.last.priceCents, 575);
      expect(find.text('Mango slush'), findsOneWidget);
    },
  );

  testWidgets(
    'a store manager sets a local price but can\'t edit the org menu',
    (tester) async {
      final fake = backendFor('me', role: Role.storeManager);
      await openCambridge(tester, fake);
      await tester.tap(find.text('Menu'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('add-item')), findsNothing);

      await tester.tap(find.byKey(const Key('local-price-taro')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('local-price')), '6.50');
      await tester.tap(find.byKey(const Key('save-local-price')));
      await tester.pumpAndSettle();
      expect(fake.data.writes, ['override:taro:true:650:me']);
      expect(find.textContaining(r'$6.50 here'), findsOneWidget);
    },
  );

  testWidgets('a cashier only sees the menu and can mark items sold out', (
    tester,
  ) async {
    final fake = backendFor('sam', role: Role.cashier);
    await openCambridge(tester, fake);
    expect(
      find.byType(NavigationBar),
      findsNothing,
      reason: 'no Team or Devices tabs',
    );
    expect(find.byKey(const Key('local-price-taro')), findsNothing);

    await tester.tap(find.byKey(const Key('available-taro')));
    await tester.pumpAndSettle();
    expect(fake.data.writes, ['override:taro:false:null:sam']);
    expect(find.textContaining('Sold out'), findsOneWidget);
  });

  testWidgets('an accountant sees the menu read-only', (tester) async {
    final fake = backendFor('acct', role: Role.accountant);
    await openCambridge(tester, fake);
    expect(find.text('Taro milk tea'), findsOneWidget);
    expect(find.byKey(const Key('available-taro')), findsNothing);
  });

  testWidgets('setting a PIN checks the two entries match', (tester) async {
    final fake = backendFor('sam', role: Role.cashier);
    await tester.pumpWidget(ManagerApp(backend: fake.backend));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Maple Tea Co'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('set-pin')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('pin')), '2580');
    await tester.enterText(find.byKey(const Key('pin-confirm')), '2581');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('The PINs don\'t match.'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('pin-confirm')), '2580');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(fake.functions.calls, ['setStaffPin:org-a:2580']);
    expect(find.text('PIN saved'), findsOneWidget);
  });

  testWidgets('owners can add a location', (tester) async {
    final fake = backendFor('boss', owner: true);
    await tester.pumpWidget(ManagerApp(backend: fake.backend));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Maple Tea Co'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add-location')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('location-name')), 'Waterloo');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(fake.functions.calls, ['createLocation:org-a:Waterloo:ON']);
  });

  testWidgets('a manager turns on online ordering with a web address', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fake = backendFor('mgr', role: Role.storeManager);
    await openCambridge(tester, fake);
    await tester.tap(find.text('Online'));
    await tester.pumpAndSettle();
    final slug = tester.widget<TextField>(find.byKey(const Key('online-slug')));
    expect(slug.controller!.text, 'maple-tea-co-cambridge');
    expect(find.byKey(const Key('online-stripe')), findsNothing);

    await tester.tap(find.byKey(const Key('online-enabled')));
    await tester.pumpAndSettle();
    expect(fake.orders.calls, [
      'online:enabled=true,slug=maple-tea-co-cambridge',
    ]);
    expect(find.textContaining('/maple-tea-co-cambridge'), findsWidgets);

    await tester.tap(find.byKey(const Key('online-paused')));
    await tester.pumpAndSettle();
    expect(fake.orders.calls.last, 'online:paused=true');
  });

  testWidgets('a manager sets the phone and email guests see', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fake = backendFor('mgr', role: Role.storeManager);
    await openCambridge(tester, fake);
    await tester.tap(find.text('Online'));
    await tester.pumpAndSettle();
    expect(find.text('No street address on file'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('online-phone')),
      '519-555-0199',
    );
    await tester.enterText(
      find.byKey(const Key('online-email')),
      'hello@maple.example',
    );
    await tester.ensureVisible(find.byKey(const Key('online-save')));
    await tester.tap(find.byKey(const Key('online-save')));
    await tester.pumpAndSettle();
    expect(fake.orders.online?.contactPhone, '519-555-0199');
    expect(fake.orders.online?.contactEmail, 'hello@maple.example');
  });

  testWidgets('only the owner sees the Stripe account field', (tester) async {
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fake = backendFor('own', owner: true);
    await openCambridge(tester, fake);
    await tester.tap(find.text('Online'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('online-stripe')), findsOneWidget);
  });

  testWidgets(
    'a manager adds an Epson printer with the cash drawer and pairs a Stripe reader',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fake = backendFor('mgr', role: Role.storeManager);
      await openCambridge(tester, fake);
      await tester.tap(find.text('Counter'));
      await tester.pumpAndSettle();

      // No Stripe account yet: readers wait for the owner.
      expect(find.text('Connect Stripe first'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('add-reader')))
            .onPressed,
        isNull,
      );

      await tester.tap(find.byKey(const Key('add-printer')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('printer-name')),
        'Front counter',
      );
      await tester.enterText(
        find.byKey(const Key('printer-host')),
        'not an ip!',
      );
      await tester.tap(find.byKey(const Key('printer-save')));
      await tester.pump();
      expect(find.textContaining('IP address, for example'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('printer-host')),
        '192.168.1.50',
      );
      await tester.tap(find.byKey(const Key('printer-drawer')));
      await tester.tap(find.byKey(const Key('printer-save')));
      await tester.pumpAndSettle();
      final p = fake.counter.hardwareSettings.printers.single;
      expect(p.id, 'front-counter');
      expect(p.connection, PrinterConnection.epos);
      expect(p.hasDrawer, isTrue);
      expect(p.jobs, {PrinterJob.receipt});
      expect(
        find.textContaining('192.168.1.50 · ePOS · 80 mm'),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const Key('receipt-tax')),
        '123456789 RT0001',
      );
      await tester.tap(find.byKey(const Key('receipt-save')));
      await tester.pumpAndSettle();
      expect(
        fake.counter.hardwareSettings.receipt.taxNumber,
        '123456789 RT0001',
      );
      expect(fake.counter.hardwareSettings.printers, hasLength(1));

      fake.orders
        ..online = const OnlineOrderingSettings(stripeAccountId: 'acct_maple')
        ..notify();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('add-reader')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reader-line1')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('reader-code')),
        'Apple Grape Orange',
      );
      await tester.enterText(
        find.byKey(const Key('reader-line1')),
        '10 Main St',
      );
      await tester.enterText(find.byKey(const Key('reader-city')), 'Cambridge');
      await tester.enterText(find.byKey(const Key('reader-postal')), 'N1R 5S2');
      await tester.tap(find.byKey(const Key('reader-save')));
      await tester.pumpAndSettle();
      expect(
        fake.counter.calls.last,
        'register:front-counter:apple-grape-orange',
      );
      expect(find.text('Stripe Reader S700'), findsOneWidget);
    },
  );
}
