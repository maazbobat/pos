import 'commercial.dart';
import 'menu/menu_models.dart';
import 'models/device.dart';
import 'models/location.dart';
import 'models/membership.dart';
import 'models/organization.dart';
import 'models/staff.dart';
import 'orders/orders_backend.dart';
import 'payments/counter_backend.dart';
import 'role.dart';

/// Everything the apps need from Firebase, behind interfaces so screens can
/// be tested with fakes. The Firebase implementation is in
/// `packages/firebase_backend`.
///
/// Reads go straight to Firestore and are limited by the rules; anything that
/// changes access goes through a Cloud Function ([OnboardingFunctions]).
abstract interface class AuthGateway {
  Stream<String?> uidChanges();
  String? get currentUid;
  String? get currentEmail;
  Future<void> signInWithEmail(String email, String password);
  Future<void> createAccount(String email, String password);
  Future<void> signInWithCustomToken(String token);
  Future<void> signOut();
}

/// A failure the server explained, for showing to the person as is.
class BackendException implements Exception {
  const BackendException(this.code, this.message);

  /// The Functions error code, for example `permission-denied`.
  final String code;
  final String message;

  @override
  String toString() => message;
}

class PairingCode {
  const PairingCode({required this.code, required this.expiresAt});
  final String code;
  final DateTime expiresAt;
}

class PairedDevice {
  const PairedDevice({
    required this.customToken,
    required this.orgId,
    required this.locationId,
    required this.deviceId,
    required this.deviceType,
  });
  final String customToken;
  final String orgId;
  final String locationId;
  final String deviceId;
  final DeviceType deviceType;
}

class CreatedInvite {
  const CreatedInvite({
    required this.inviteId,
    required this.token,
    required this.expiresAt,
  });
  final String inviteId;
  final String token;
  final DateTime expiresAt;
}

class StaffSession {
  const StaffSession({required this.uid, required this.role, this.displayName});
  final String uid;
  final Role role;
  final String? displayName;
  String get label => displayName ?? uid;
}

/// Typed wrappers for the callables in `functions/src/index.ts`.
abstract interface class OnboardingFunctions {
  Future<({String orgId, CreatedInvite ownerInvite})> createOrganization({
    required String name,
    required OrgType type,
    required String ownerEmail,
    String? ownerName,
  });
  Future<String> createLocation({
    required String orgId,
    required String name,
    required String province,
    required String timezone,
    String? address,
  });
  Future<void> setLocationStatus(
    String orgId,
    String locationId,
    LocationStatus status,
  );

  /// Pass [locationId] null with [Role.owner] for an org-wide owner invite.
  Future<CreatedInvite> inviteStaff({
    required String orgId,
    required String? locationId,
    required Role role,
    required String email,
    String? displayName,
  });
  Future<void> revokeInvite(String orgId, String inviteId);
  Future<void> acceptInvite(String orgId, String inviteId, String token);

  /// [role] null removes the person from that location.
  Future<void> setMemberRole(
    String orgId,
    String locationId,
    String uid,
    Role? role,
  );

  Future<PairingCode> createPairingCode({
    required String orgId,
    required String locationId,
    required DeviceType deviceType,
    required String deviceName,
  });
  Future<PairedDevice> redeemPairingCode(
    String code, {
    String? appVersion,
    String? platform,
  });
  Future<void> revokeDevice(String orgId, String locationId, String deviceId);

  Future<void> setStaffPin(String orgId, String pin);
  Future<StaffSession> startStaffSession(String orgId, String pin);
}

/// Live reads and the direct writes the rules allow.
abstract interface class TenantData {
  /// From `users/{uid}.orgIds`.
  Stream<List<String>> orgIdsOf(String uid);
  Stream<Organization?> org(String orgId);
  Stream<Membership?> member(String orgId, String uid);
  Stream<Location?> location(String orgId, String locationId);

  /// Every location in the org. Owners only; others read by ID.
  Stream<List<Location>> allLocations(String orgId);

  Stream<List<StaffEntry>> staff(String orgId, String locationId);

  /// Pending invites for one location (the query the rules require).
  Stream<List<Invite>> invites(String orgId, String locationId);
  Stream<List<Device>> devices(String orgId, String locationId);

  /// One device. A paired tablet may read only its own.
  Stream<Device?> device(String orgId, String locationId, String deviceId);

  Stream<List<MenuCategory>> menuCategories(String orgId);
  Stream<List<MenuItem>> menuItems(String orgId);
  Stream<List<ModifierGroup>> modifierGroups(String orgId);
  Stream<List<MenuOverride>> menuOverrides(String orgId, String locationId);

  /// Owner only. Creates when [MenuItem.id] is empty. Returns the ID.
  Future<String> saveMenuItem(MenuItem item);
  Future<String> saveMenuCategory(MenuCategory category);

  /// Managers set price and availability; front-of-house roles and devices
  /// may only change availability. A null [MenuOverride.priceCents] leaves
  /// the local price as it is unless [resetPrice] is true, which goes back
  /// to the org price.
  Future<void> saveMenuOverride(
    MenuOverride override, {
    bool resetPrice = false,
  });
}

/// What an app is given at startup.
class Backend {
  const Backend({
    required this.auth,
    required this.functions,
    required this.data,
    required this.billing,
    required this.platform,
    required this.orders,
    required this.counter,
  });
  final AuthGateway auth;
  final OnboardingFunctions functions;
  final TenantData data;
  final BillingBackend billing;
  final PlatformBackend platform;
  final OrdersBackend orders;
  final CounterBackend counter;
}
