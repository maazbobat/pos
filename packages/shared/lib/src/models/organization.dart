/// Set by the platform. A suspended org is closed to everyone but its owner.
enum OrgStatus { active, suspended }

/// Derived from billing by Cloud Functions. In [readOnly], members can still
/// read and export their data but cannot write.
enum AccessLevel { full, readOnly }

enum OrgType { independent, chain, franchise }

class Organization {
  const Organization({
    required this.id,
    required this.name,
    required this.type,
    required this.status,
    required this.accessLevel,
  });

  final String id;
  final String name;
  final OrgType type;
  final OrgStatus status;
  final AccessLevel accessLevel;

  bool get canWrite =>
      status == OrgStatus.active && accessLevel == AccessLevel.full;

  factory Organization.fromMap(String id, Map<String, Object?> data) =>
      Organization(
        id: id,
        name: data['name'] as String? ?? '',
        type: OrgType.values.byName(data['type'] as String? ?? 'independent'),
        status: data['status'] == 'active'
            ? OrgStatus.active
            : OrgStatus.suspended,
        accessLevel: data['accessLevel'] == 'full'
            ? AccessLevel.full
            : AccessLevel.readOnly,
      );

  Map<String, Object?> toMap() => {
    'name': name,
    'type': type.name,
    'status': status.name,
    'accessLevel': accessLevel == AccessLevel.full ? 'full' : 'read_only',
  };
}
