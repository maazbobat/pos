enum LocationStatus { active, closed }

class Location {
  const Location({
    required this.id,
    required this.orgId,
    required this.name,
    required this.status,
    required this.timezone,
    required this.province,
    this.address,
  });

  final String id;
  final String orgId;
  final String name;
  final LocationStatus status;

  /// IANA time zone, for example `America/Toronto`.
  final String timezone;

  /// Two-letter province code. Drives the default GST/HST profile.
  final String province;

  /// The street address entered when the location was created. The ordering
  /// site shows it to guests; null when none was entered.
  final String? address;

  factory Location.fromMap(String id, Map<String, Object?> data) => Location(
    id: id,
    orgId: data['orgId'] as String,
    name: data['name'] as String? ?? '',
    status: data['status'] == 'active'
        ? LocationStatus.active
        : LocationStatus.closed,
    timezone: data['timezone'] as String? ?? 'America/Toronto',
    province: data['province'] as String? ?? 'ON',
    address: (data['address'] as String?)?.trim().isEmpty ?? true
        ? null
        : (data['address'] as String).trim(),
  );

  Map<String, Object?> toMap() => {
    'orgId': orgId,
    'locationId': id,
    'name': name,
    'status': status.name,
    'timezone': timezone,
    'province': province,
    'address': ?address,
  };
}
