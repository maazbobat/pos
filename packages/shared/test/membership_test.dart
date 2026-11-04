import 'package:pos_shared/pos_shared.dart';
import 'package:test/test.dart';

void main() {
  group('Membership.roleAt', () {
    final member = Membership(
      uid: 'u1',
      orgId: 'org-a',
      kind: MemberKind.user,
      status: MemberStatus.active,
      locationRoles: {'cambridge': Role.storeManager, 'toronto': Role.cashier},
    );

    test('returns the role held at that location', () {
      expect(member.roleAt('cambridge'), Role.storeManager);
      expect(member.roleAt('toronto'), Role.cashier);
    });

    test('returns null at a location with no role', () {
      expect(member.roleAt('waterloo'), isNull);
    });

    test('owner acts as owner everywhere', () {
      final owner = Membership(
        uid: 'u2',
        orgId: 'org-a',
        kind: MemberKind.user,
        status: MemberStatus.active,
        isOwner: true,
      );
      expect(owner.roleAt('anywhere'), Role.owner);
    });

    test('suspended member has no role anywhere', () {
      final suspended = Membership(
        uid: 'u3',
        orgId: 'org-a',
        kind: MemberKind.user,
        status: MemberStatus.suspended,
        locationRoles: {'cambridge': Role.cashier},
      );
      expect(suspended.roleAt('cambridge'), isNull);
    });
  });

  test('Membership round-trips through a Firestore map', () {
    final member = Membership(
      uid: 'u1',
      orgId: 'org-a',
      kind: MemberKind.device,
      status: MemberStatus.active,
      locationRoles: {'cambridge': Role.device},
    );
    final copy = Membership.fromMap('u1', member.toMap());
    expect(copy.kind, MemberKind.device);
    expect(copy.roleAt('cambridge'), Role.device);
    expect(member.toMap()['roles'], ['device']);
  });

  test('unknown role strings are ignored', () {
    final member = Membership.fromMap('u1', {
      'orgId': 'org-a',
      'status': 'active',
      'locationRoles': {'cambridge': 'superuser'},
    });
    expect(member.roleAt('cambridge'), isNull);
  });

  test('paths keep store data under its org and location', () {
    expect(
      FirestorePaths.orders('org-a', 'cambridge'),
      'orgs/org-a/locations/cambridge/orders',
    );
    expect(
      FirestorePaths.cashMovements('org-a', 'cambridge', 's1'),
      'orgs/org-a/locations/cambridge/cashSessions/s1/movements',
    );
  });

  test('every role has a distinct wire name', () {
    final names = Role.values.map((r) => r.wireName).toSet();
    expect(names.length, Role.values.length);
    for (final role in Role.values) {
      expect(Role.fromWire(role.wireName), role);
    }
  });
}
