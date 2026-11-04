import '../role.dart';

/// `orgs/{orgId}/locations/{locationId}/staff/{uid}`, mirrored from
/// memberships by Functions. Managers read it to list a store's team.
class StaffEntry {
  const StaffEntry({
    required this.uid,
    required this.role,
    this.displayName,
    this.email,
  });

  final String uid;
  final Role role;
  final String? displayName;
  final String? email;

  String get label => displayName ?? email ?? uid;

  factory StaffEntry.fromMap(String uid, Map<String, Object?> data) =>
      StaffEntry(
        uid: uid,
        role: Role.fromWire(data['role'] as String?) ?? Role.cashier,
        displayName: data['displayName'] as String?,
        email: data['email'] as String?,
      );
}

/// `orgs/{orgId}/invites/{inviteId}`. Written only by Functions.
class Invite {
  const Invite({
    required this.id,
    required this.email,
    required this.role,
    required this.status,
    this.locationId,
    this.displayName,
    this.expiresAt,
  });

  final String id;
  final String email;
  final Role role;

  /// `pending`, `accepted` or `revoked`.
  final String status;

  /// Null for an owner invite, which covers every location.
  final String? locationId;
  final String? displayName;
  final DateTime? expiresAt;

  bool get isPending =>
      status == 'pending' &&
      (expiresAt == null || expiresAt!.isAfter(DateTime.now()));

  factory Invite.fromMap(String id, Map<String, Object?> data) => Invite(
    id: id,
    email: data['email'] as String? ?? '',
    role: Role.fromWire(data['role'] as String?) ?? Role.cashier,
    status: data['status'] as String? ?? 'pending',
    locationId: data['locationId'] as String?,
    displayName: data['displayName'] as String?,
    expiresAt: data['expiresAt'] as DateTime?,
  );
}

/// What the invite link carries. The manager app parses it back on the
/// accept screen; the token is a one-time secret, so it is never logged.
class InviteLink {
  const InviteLink({
    required this.orgId,
    required this.inviteId,
    required this.token,
  });

  final String orgId;
  final String inviteId;
  final String token;

  /// The path the manager app opens. A hosting domain is added once a real
  /// Firebase project exists.
  String toPath() =>
      '/invite?org=${Uri.encodeQueryComponent(orgId)}'
      '&id=${Uri.encodeQueryComponent(inviteId)}'
      '&token=${Uri.encodeQueryComponent(token)}';

  /// Accepts a full URL or just the path, as pasted by the invitee.
  static InviteLink? parse(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null) return null;
    final q = uri.queryParameters;
    final org = q['org'], id = q['id'], token = q['token'];
    if (org == null || id == null || token == null) return null;
    if (org.isEmpty || id.isEmpty || token.isEmpty) return null;
    return InviteLink(orgId: org, inviteId: id, token: token);
  }
}
