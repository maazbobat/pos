import 'package:pos_shared/pos_shared.dart';
import 'package:test/test.dart';

void main() {
  group('InviteLink', () {
    test('round-trips a token with URL-unsafe characters', () {
      const link = InviteLink(
        orgId: 'org-a',
        inviteId: 'inv 1',
        token: 'a/b+c=',
      );
      final parsed = InviteLink.parse('https://pos.example${link.toPath()}')!;
      expect(
        (parsed.orgId, parsed.inviteId, parsed.token),
        ('org-a', 'inv 1', 'a/b+c='),
      );
      expect(InviteLink.parse(link.toPath())?.token, 'a/b+c=');
    });

    test('rejects text that is missing a part', () {
      expect(InviteLink.parse('hello'), isNull);
      expect(InviteLink.parse('/invite?org=a&id=b'), isNull);
      expect(InviteLink.parse('/invite?org=a&id=b&token='), isNull);
    });
  });

  // Mirrors the table in functions/src/lib/roles.ts and docs/onboarding.md.
  test('assignable roles match the server', () {
    expect(Role.owner.assignableRoles, {
      Role.franchiseOwner,
      Role.storeManager,
      Role.cashier,
      Role.kitchen,
      Role.inventoryManager,
      Role.accountant,
    });
    expect(Role.franchiseOwner.assignableRoles, {
      Role.storeManager,
      Role.cashier,
      Role.kitchen,
      Role.inventoryManager,
      Role.accountant,
    });
    expect(Role.storeManager.assignableRoles, {
      Role.cashier,
      Role.kitchen,
      Role.inventoryManager,
    });
    for (final r in [
      Role.cashier,
      Role.kitchen,
      Role.inventoryManager,
      Role.accountant,
      Role.device,
    ]) {
      expect(r.assignableRoles, isEmpty, reason: r.name);
    }
  });

  test('Invite.isPending ignores expired and used invites', () {
    final future = DateTime.now().add(const Duration(days: 1));
    final past = DateTime.now().subtract(const Duration(days: 1));
    Invite make(String status, DateTime expires) => Invite(
      id: 'i',
      email: 'a@b.c',
      role: Role.cashier,
      status: status,
      expiresAt: expires,
    );
    expect(make('pending', future).isPending, isTrue);
    expect(make('pending', past).isPending, isFalse);
    expect(make('accepted', future).isPending, isFalse);
  });
}
