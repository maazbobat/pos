import '../role.dart';

enum MemberKind { user, device }

enum MemberStatus { active, suspended }

/// A person's (or device's) access to one organization.
///
/// Stored at `orgs/{orgId}/members/{uid}` and written only by Cloud Functions.
class Membership {
  const Membership({
    required this.uid,
    required this.orgId,
    required this.kind,
    required this.status,
    this.isOwner = false,
    this.locationRoles = const {},
  });

  final String uid;
  final String orgId;
  final MemberKind kind;
  final MemberStatus status;

  /// Organization Owner: every role-checked operation at every location.
  final bool isOwner;

  /// One role per location, keyed by location ID.
  final Map<String, Role> locationRoles;

  /// The role this member acts with at [locationId], or null for none.
  Role? roleAt(String locationId) {
    if (status != MemberStatus.active) return null;
    if (isOwner) return Role.owner;
    return locationRoles[locationId];
  }

  /// Distinct roles held anywhere in the org. Mirrors the `roles` field the
  /// rules use for org-wide checks such as reading billing status.
  Set<Role> get roles => {if (isOwner) Role.owner, ...locationRoles.values};

  factory Membership.fromMap(String uid, Map<String, Object?> data) {
    final rawRoles = (data['locationRoles'] as Map?) ?? const {};
    return Membership(
      uid: uid,
      orgId: data['orgId'] as String,
      kind: data['kind'] == 'device' ? MemberKind.device : MemberKind.user,
      status: data['status'] == 'active'
          ? MemberStatus.active
          : MemberStatus.suspended,
      isOwner: data['orgRole'] == Role.owner.wireName,
      locationRoles: {
        for (final entry in rawRoles.entries)
          entry.key as String: ?Role.fromWire(entry.value as String?),
      },
    );
  }

  Map<String, Object?> toMap() => {
    'uid': uid,
    'orgId': orgId,
    'kind': kind.name,
    'status': status.name,
    'orgRole': isOwner ? Role.owner.wireName : null,
    'locationRoles': {
      for (final entry in locationRoles.entries)
        entry.key: entry.value.wireName,
    },
    'roles': [for (final role in roles) role.wireName],
  };
}
