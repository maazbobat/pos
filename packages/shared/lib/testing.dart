/// An in-memory [Backend] for widget tests. It applies no permission rules:
/// those are tested against the emulators in `tests/rules` and `functions/`.
library;

import 'dart:async';

import 'pos_shared.dart';

class FakeBackend {
  FakeBackend() {
    backend = Backend(auth: auth, functions: functions, data: data);
  }

  late final Backend backend;
  final FakeAuth auth = FakeAuth();
  final FakeFunctions functions = FakeFunctions();
  late final FakeData data = FakeData(auth);
}

class FakeAuth implements AuthGateway {
  final _uid = StreamController<String?>.broadcast();
  String? _current;
  String? _email;

  /// Passwords by email, for [signInWithEmail].
  final Map<String, String> accounts = {};
  final List<String> customTokens = [];

  void signInAs(String uid, {String? email}) {
    _current = uid;
    _email = email;
    _uid.add(uid);
  }

  @override
  Stream<String?> uidChanges() async* {
    yield _current;
    yield* _uid.stream;
  }

  @override
  String? get currentUid => _current;

  @override
  String? get currentEmail => _email;

  @override
  Future<void> signInWithEmail(String email, String password) async {
    if (accounts[email] != password) {
      throw const BackendException(
        'invalid-credential',
        'That email and password don\'t match.',
      );
    }
    signInAs('uid:$email', email: email);
  }

  @override
  Future<void> createAccount(String email, String password) async {
    accounts[email] = password;
    signInAs('uid:$email', email: email);
  }

  @override
  Future<void> signInWithCustomToken(String token) async {
    customTokens.add(token);
    signInAs(token.replaceFirst('token:', ''));
  }

  @override
  Future<void> signOut() async {
    _current = null;
    _email = null;
    _uid.add(null);
  }
}

/// Records every call. Set the `on...` handlers to return results or throw.
class FakeFunctions implements OnboardingFunctions {
  final List<String> calls = [];

  Future<PairedDevice> Function(String code)? onRedeem;
  Future<StaffSession> Function(String pin)? onStartSession;
  Future<PairingCode> Function()? onCreatePairingCode;
  Future<CreatedInvite> Function(Role role, String email)? onInvite;

  Future<T> _record<T>(
    String call,
    Future<T> Function()? handler,
    T Function() fallback,
  ) {
    calls.add(call);
    return handler != null ? handler() : Future.value(fallback());
  }

  @override
  Future<({String orgId, CreatedInvite ownerInvite})> createOrganization({
    required String name,
    required OrgType type,
    required String ownerEmail,
    String? ownerName,
  }) => _record(
    'createOrganization:$name:$ownerEmail',
    null,
    () => (
      orgId: 'org-new',
      ownerInvite: CreatedInvite(
        inviteId: 'inv-1',
        token: 'tok-1',
        expiresAt: DateTime(2030),
      ),
    ),
  );

  @override
  Future<String> createLocation({
    required String orgId,
    required String name,
    required String province,
    required String timezone,
    String? address,
  }) => _record('createLocation:$orgId:$name:$province', null, () => 'loc-new');

  @override
  Future<void> setLocationStatus(
    String orgId,
    String locationId,
    LocationStatus status,
  ) => _record('setLocationStatus:$locationId:${status.name}', null, () {});

  @override
  Future<CreatedInvite> inviteStaff({
    required String orgId,
    required String? locationId,
    required Role role,
    required String email,
    String? displayName,
  }) => _record(
    'inviteStaff:$locationId:${role.wireName}:$email',
    onInvite == null ? null : () => onInvite!(role, email),
    () => CreatedInvite(
      inviteId: 'inv-1',
      token: 'tok-1',
      expiresAt: DateTime(2030),
    ),
  );

  @override
  Future<void> revokeInvite(String orgId, String inviteId) =>
      _record('revokeInvite:$inviteId', null, () {});

  @override
  Future<void> acceptInvite(String orgId, String inviteId, String token) =>
      _record('acceptInvite:$orgId:$inviteId:$token', null, () {});

  @override
  Future<void> setMemberRole(
    String orgId,
    String locationId,
    String uid,
    Role? role,
  ) => _record('setMemberRole:$locationId:$uid:${role?.wireName}', null, () {});

  @override
  Future<PairingCode> createPairingCode({
    required String orgId,
    required String locationId,
    required DeviceType deviceType,
    required String deviceName,
  }) => _record(
    'createPairingCode:$locationId:${deviceType.name}:$deviceName',
    onCreatePairingCode,
    () => PairingCode(
      code: '7KQM-3XWP',
      expiresAt: DateTime.now().add(const Duration(minutes: 15)),
    ),
  );

  @override
  Future<PairedDevice> redeemPairingCode(
    String code, {
    String? appVersion,
    String? platform,
  }) => _record(
    'redeemPairingCode:$code',
    onRedeem == null ? null : () => onRedeem!(code),
    () {
      throw const BackendException(
        'not-found',
        'That pairing code isn\'t valid.',
      );
    },
  );

  @override
  Future<void> revokeDevice(String orgId, String locationId, String deviceId) =>
      _record('revokeDevice:$deviceId', null, () {});

  @override
  Future<void> setStaffPin(String orgId, String pin) =>
      _record('setStaffPin:$orgId:$pin', null, () {});

  @override
  Future<StaffSession> startStaffSession(String orgId, String pin) => _record(
    'startStaffSession:$pin',
    onStartSession == null ? null : () => onStartSession!(pin),
    () => throw const BackendException(
      'permission-denied',
      'That PIN didn\'t match anyone at this location.',
    ),
  );
}

/// Plain mutable state. Call [notify] after changing it in a test.
class FakeData implements TenantData {
  FakeData(this._auth);
  final FakeAuth _auth;
  final _changes = StreamController<void>.broadcast();

  final Map<String, List<String>> orgIds = {};
  final Map<String, Organization> orgs = {};
  final Map<String, Membership> members = {}; // key: orgId/uid
  final Map<String, Location> locations = {}; // key: orgId/locationId
  final Map<String, List<StaffEntry>> staffByLocation = {};
  final Map<String, List<Invite>> invitesByLocation = {};
  final Map<String, List<Device>> devicesByLocation = {};
  final List<MenuCategory> categories = [];
  final List<MenuItem> items = [];
  final List<ModifierGroup> groups = [];
  final Map<String, List<MenuOverride>> overridesByLocation = {};
  final List<String> writes = [];

  void notify() => _changes.add(null);

  Stream<T> _watch<T>(T Function() read) async* {
    yield read();
    yield* _changes.stream.map((_) => read());
  }

  @override
  Stream<List<String>> orgIdsOf(String uid) =>
      _watch(() => orgIds[uid] ?? const []);
  @override
  Stream<Organization?> org(String orgId) => _watch(() => orgs[orgId]);
  @override
  Stream<Membership?> member(String orgId, String uid) =>
      _watch(() => members['$orgId/$uid']);
  @override
  Stream<Location?> location(String orgId, String locationId) =>
      _watch(() => locations['$orgId/$locationId']);
  @override
  Stream<List<Location>> allLocations(String orgId) => _watch(
    () => [
      for (final l in locations.values)
        if (l.orgId == orgId) l,
    ],
  );
  @override
  Stream<List<StaffEntry>> staff(String orgId, String locationId) =>
      _watch(() => staffByLocation[locationId] ?? const []);
  @override
  Stream<List<Invite>> invites(String orgId, String locationId) =>
      _watch(() => invitesByLocation[locationId] ?? const []);
  @override
  Stream<List<Device>> devices(String orgId, String locationId) =>
      _watch(() => devicesByLocation[locationId] ?? const []);
  @override
  Stream<List<MenuCategory>> menuCategories(String orgId) =>
      _watch(() => List.of(categories));
  @override
  Stream<List<MenuItem>> menuItems(String orgId) =>
      _watch(() => List.of(items));
  @override
  Stream<List<ModifierGroup>> modifierGroups(String orgId) =>
      _watch(() => List.of(groups));
  @override
  Stream<List<MenuOverride>> menuOverrides(String orgId, String locationId) =>
      _watch(() => overridesByLocation[locationId] ?? const []);

  @override
  Future<String> saveMenuItem(MenuItem item) async {
    item.validate();
    final id = item.id.isEmpty ? 'item-${items.length + 1}' : item.id;
    items
      ..removeWhere((i) => i.id == id)
      ..add(MenuItem.fromMap(id, item.toMap()));
    writes.add('menuItem:$id');
    notify();
    return id;
  }

  @override
  Future<String> saveMenuCategory(MenuCategory category) async {
    category.validate();
    final id = category.id.isEmpty
        ? 'cat-${categories.length + 1}'
        : category.id;
    categories
      ..removeWhere((c) => c.id == id)
      ..add(MenuCategory.fromMap(id, category.toMap()));
    writes.add('menuCategory:$id');
    notify();
    return id;
  }

  @override
  Future<void> saveMenuOverride(
    MenuOverride override, {
    bool resetPrice = false,
  }) async {
    final list = overridesByLocation.putIfAbsent(override.locationId, () => []);
    final old = list.where((o) => o.itemId == override.itemId).firstOrNull;
    list
      ..remove(old)
      ..add(
        MenuOverride(
          itemId: override.itemId,
          orgId: override.orgId,
          locationId: override.locationId,
          available: override.available,
          priceCents: resetPrice
              ? null
              : (override.priceCents ?? old?.priceCents),
        ),
      );
    writes.add(
      'override:${override.itemId}:${override.available}:${resetPrice ? 'reset' : override.priceCents}:${_auth.currentUid}',
    );
    notify();
  }
}
