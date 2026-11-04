enum LocationStatus { active, closed }

class Location {
  const Location({
    required this.id,
    required this.orgId,
    required this.name,
    required this.status,
    required this.timezone,
    required this.province,
  });

  final String id;
  final String orgId;
  final String name;
  final LocationStatus status;

  /// IANA time zone, for example `America/Toronto`.
  final String timezone;

  /// Two-letter province code. Drives the default GST/HST profile.
  final String province;

  factory Location.fromMap(String id, Map<String, Object?> data) => Location(
    id: id,
    orgId: data['orgId'] as String,
    name: data['name'] as String? ?? '',
    status: data['status'] == 'active'
        ? LocationStatus.active
        : LocationStatus.closed,
    timezone: data['timezone'] as String? ?? 'America/Toronto',
    province: data['province'] as String? ?? 'ON',
  );

  Map<String, Object?> toMap() => {
    'orgId': orgId,
    'locationId': id,
    'name': name,
    'status': status.name,
    'timezone': timezone,
    'province': province,
  };
}
