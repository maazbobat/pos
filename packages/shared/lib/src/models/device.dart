enum DeviceType {
  /// Front-counter POS.
  pos,

  /// Kitchen display.
  kds;

  static DeviceType? fromWire(String? value) {
    for (final type in values) {
      if (type.name == value) return type;
    }
    return null;
  }
}

enum DeviceStatus { active, revoked }

/// A paired tablet at one location.
///
/// Stored at `orgs/{orgId}/locations/{locationId}/devices/{deviceId}`. The
/// device ID is also its auth uid and its membership ID. Created by the
/// `redeemPairingCode` Function; the device itself may only update
/// [appVersion], `lastSeenAt`, `printerStatus` and `health`.
class Device {
  const Device({
    required this.id,
    required this.orgId,
    required this.locationId,
    required this.type,
    required this.name,
    required this.status,
    this.appVersion,
    this.currentStaffUid,
  });

  final String id;
  final String orgId;
  final String locationId;
  final DeviceType type;
  final String name;
  final DeviceStatus status;
  final String? appVersion;

  /// Who last signed in on the PIN pad.
  final String? currentStaffUid;

  factory Device.fromMap(String id, Map<String, Object?> data) => Device(
    id: id,
    orgId: data['orgId'] as String,
    locationId: data['locationId'] as String,
    type: DeviceType.fromWire(data['type'] as String?) ?? DeviceType.pos,
    name: (data['name'] as String?) ?? id,
    status: data['status'] == 'active'
        ? DeviceStatus.active
        : DeviceStatus.revoked,
    appVersion: data['appVersion'] as String?,
    currentStaffUid: data['currentStaffUid'] as String?,
  );
}

/// Formats what someone types into a pairing code the way the server
/// normalizes it: uppercase, no spaces or dashes. Returns null when it can't
/// be a code, so the app can reject it before a network call.
String? normalizePairingCode(String raw) {
  final code = raw.toUpperCase().replaceAll(RegExp(r'[\s-]'), '');
  return RegExp(r'^[2-9A-HJKMNP-Z]{8}$').hasMatch(code) ? code : null;
}
