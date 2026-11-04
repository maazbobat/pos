import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:pos_shared/pos_shared.dart';

/// Where the apps connect. Until real dev, staging and prod projects exist,
/// every build talks to the local emulators under the `demo-pos` project ID,
/// which can't reach anything real.
///
/// Run with `--dart-define=EMULATOR_HOST=10.0.2.2` on an Android emulator
/// (or the LAN IP of the machine running `firebase emulators:start` when
/// testing on a tablet).
class BackendConfig {
  const BackendConfig({
    this.projectId = 'demo-pos',
    this.emulatorHost = const String.fromEnvironment(
      'EMULATOR_HOST',
      defaultValue: 'localhost',
    ),
  });

  final String projectId;
  final String emulatorHost;
}

Future<Backend> initFirebaseBackend([
  BackendConfig config = const BackendConfig(),
]) async {
  final app = await Firebase.initializeApp(
    options: FirebaseOptions(
      apiKey: 'demo-api-key',
      appId: '1:0:web:0',
      messagingSenderId: '0',
      projectId: config.projectId,
    ),
  );
  final auth = FirebaseAuth.instanceFor(app: app);
  final firestore = FirebaseFirestore.instanceFor(app: app);
  final functions = FirebaseFunctions.instanceFor(
    app: app,
    region: Callables.region,
  );
  await auth.useAuthEmulator(config.emulatorHost, 9099);
  firestore.useFirestoreEmulator(config.emulatorHost, 8080);
  functions.useFunctionsEmulator(config.emulatorHost, 5001);

  return Backend(
    auth: FirebaseAuthGateway(auth),
    functions: FirebaseOnboardingFunctions(functions),
    data: FirestoreTenantData(firestore, auth),
  );
}

class FirebaseAuthGateway implements AuthGateway {
  FirebaseAuthGateway(this._auth);
  final FirebaseAuth _auth;

  @override
  Stream<String?> uidChanges() => _auth.authStateChanges().map((u) => u?.uid);

  @override
  String? get currentUid => _auth.currentUser?.uid;

  @override
  String? get currentEmail => _auth.currentUser?.email;

  @override
  Future<void> signInWithEmail(String email, String password) => _guard(
    () => _auth.signInWithEmailAndPassword(email: email, password: password),
  );

  @override
  Future<void> createAccount(String email, String password) => _guard(
    () =>
        _auth.createUserWithEmailAndPassword(email: email, password: password),
  );

  @override
  Future<void> signInWithCustomToken(String token) =>
      _guard(() => _auth.signInWithCustomToken(token));

  @override
  Future<void> signOut() => _auth.signOut();

  Future<void> _guard(Future<Object?> Function() run) async {
    try {
      await run();
    } on FirebaseAuthException catch (e) {
      throw BackendException(e.code, _authMessage(e));
    }
  }

  static String _authMessage(FirebaseAuthException e) => switch (e.code) {
    'invalid-credential' ||
    'wrong-password' ||
    'user-not-found' => 'That email and password don\'t match.',
    'email-already-in-use' =>
      'There\'s already an account with that email. Sign in instead.',
    'weak-password' => 'Use a password of at least 6 characters.',
    'invalid-email' => 'That email doesn\'t look right.',
    'network-request-failed' =>
      'No connection. Check the network and try again.',
    _ => e.message ?? 'Sign-in failed.',
  };
}

class FirebaseOnboardingFunctions implements OnboardingFunctions {
  FirebaseOnboardingFunctions(this._functions);
  final FirebaseFunctions _functions;

  Future<Map<String, Object?>> _call(
    String name,
    Map<String, Object?> data,
  ) async {
    try {
      final result = await _functions.httpsCallable(name).call<Object?>(data);
      final value = result.data;
      return value is Map ? Map<String, Object?>.from(value) : const {};
    } on FirebaseFunctionsException catch (e) {
      throw BackendException(e.code, e.message ?? 'Something went wrong.');
    }
  }

  static CreatedInvite _invite(Map<String, Object?> m) => CreatedInvite(
    inviteId: m['inviteId'] as String,
    token: m['token'] as String,
    expiresAt: DateTime.parse(m['expiresAt'] as String),
  );

  @override
  Future<({String orgId, CreatedInvite ownerInvite})> createOrganization({
    required String name,
    required OrgType type,
    required String ownerEmail,
    String? ownerName,
  }) async {
    final r = await _call(Callables.createOrganization, {
      'name': name,
      'type': type.name,
      'ownerEmail': ownerEmail,
      'ownerName': ownerName,
    });
    return (
      orgId: r['orgId'] as String,
      ownerInvite: _invite(Map<String, Object?>.from(r['ownerInvite'] as Map)),
    );
  }

  @override
  Future<String> createLocation({
    required String orgId,
    required String name,
    required String province,
    required String timezone,
    String? address,
  }) async {
    final r = await _call(Callables.createLocation, {
      'orgId': orgId,
      'name': name,
      'province': province,
      'timezone': timezone,
      'address': address,
    });
    return r['locationId'] as String;
  }

  @override
  Future<void> setLocationStatus(
    String orgId,
    String locationId,
    LocationStatus status,
  ) => _call(Callables.setLocationStatus, {
    'orgId': orgId,
    'locationId': locationId,
    'status': status.name,
  });

  @override
  Future<CreatedInvite> inviteStaff({
    required String orgId,
    required String? locationId,
    required Role role,
    required String email,
    String? displayName,
  }) async => _invite(
    await _call(Callables.inviteStaff, {
      'orgId': orgId,
      'locationId': locationId,
      'role': role.wireName,
      'email': email,
      'displayName': displayName,
    }),
  );

  @override
  Future<void> revokeInvite(String orgId, String inviteId) =>
      _call(Callables.revokeInvite, {'orgId': orgId, 'inviteId': inviteId});

  @override
  Future<void> acceptInvite(String orgId, String inviteId, String token) =>
      _call(Callables.acceptInvite, {
        'orgId': orgId,
        'inviteId': inviteId,
        'token': token,
      });

  @override
  Future<void> setMemberRole(
    String orgId,
    String locationId,
    String uid,
    Role? role,
  ) => _call(Callables.setMemberRole, {
    'orgId': orgId,
    'locationId': locationId,
    'uid': uid,
    'role': role?.wireName,
  });

  @override
  Future<PairingCode> createPairingCode({
    required String orgId,
    required String locationId,
    required DeviceType deviceType,
    required String deviceName,
  }) async {
    final r = await _call(Callables.createPairingCode, {
      'orgId': orgId,
      'locationId': locationId,
      'deviceType': deviceType.name,
      'deviceName': deviceName,
    });
    return PairingCode(
      code: r['code'] as String,
      expiresAt: DateTime.parse(r['expiresAt'] as String),
    );
  }

  @override
  Future<PairedDevice> redeemPairingCode(
    String code, {
    String? appVersion,
    String? platform,
  }) async {
    final r = await _call(Callables.redeemPairingCode, {
      'code': code,
      'appVersion': appVersion,
      'platform': platform ?? defaultTargetPlatform.name,
    });
    return PairedDevice(
      customToken: r['customToken'] as String,
      orgId: r['orgId'] as String,
      locationId: r['locationId'] as String,
      deviceId: r['deviceId'] as String,
      deviceType:
          DeviceType.fromWire(r['deviceType'] as String?) ?? DeviceType.pos,
    );
  }

  @override
  Future<void> revokeDevice(String orgId, String locationId, String deviceId) =>
      _call(Callables.revokeDevice, {
        'orgId': orgId,
        'locationId': locationId,
        'deviceId': deviceId,
      });

  @override
  Future<void> setStaffPin(String orgId, String pin) =>
      _call(Callables.setStaffPin, {'orgId': orgId, 'pin': pin});

  @override
  Future<StaffSession> startStaffSession(String orgId, String pin) async {
    final r = await _call(Callables.startStaffSession, {
      'orgId': orgId,
      'pin': pin,
    });
    return StaffSession(
      uid: r['uid'] as String,
      role: Role.fromWire(r['role'] as String?) ?? Role.cashier,
      displayName: r['displayName'] as String?,
    );
  }
}

class FirestoreTenantData implements TenantData {
  FirestoreTenantData(this._db, this._auth);
  final FirebaseFirestore _db;
  final FirebaseAuth _auth;

  /// Timestamps become DateTimes so the shared models stay Firebase-free.
  static Map<String, Object?> _plain(Map<String, dynamic> data) => {
    for (final e in data.entries)
      e.key: e.value is Timestamp ? (e.value as Timestamp).toDate() : e.value,
  };

  Stream<T?> _doc<T>(
    String path,
    T Function(String id, Map<String, Object?> d) parse,
  ) => _db.doc(path).snapshots().map((s) {
    final data = s.data();
    return data == null ? null : parse(s.id, _plain(data));
  });

  Stream<List<T>> _list<T>(
    Query<Map<String, dynamic>> query,
    T Function(String id, Map<String, Object?> d) parse,
  ) => query.snapshots().map(
    (s) => [for (final d in s.docs) parse(d.id, _plain(d.data()))],
  );

  @override
  Stream<List<String>> orgIdsOf(String uid) => _db
      .doc(FirestorePaths.user(uid))
      .snapshots()
      .map(
        (s) => [
          for (final id in (s.data()?['orgIds'] as List?) ?? const [])
            id as String,
        ],
      );

  @override
  Stream<Organization?> org(String orgId) =>
      _doc(FirestorePaths.org(orgId), Organization.fromMap);

  @override
  Stream<Membership?> member(String orgId, String uid) =>
      _doc(FirestorePaths.member(orgId, uid), Membership.fromMap);

  @override
  Stream<Location?> location(String orgId, String locationId) =>
      _doc(FirestorePaths.location(orgId, locationId), Location.fromMap);

  @override
  Stream<List<Location>> allLocations(String orgId) =>
      _list(_db.collection(FirestorePaths.locations(orgId)), Location.fromMap);

  @override
  Stream<List<StaffEntry>> staff(String orgId, String locationId) => _list(
    _db.collection(FirestorePaths.staff(orgId, locationId)),
    StaffEntry.fromMap,
  );

  @override
  Stream<List<Invite>> invites(String orgId, String locationId) => _list(
    _db
        .collection(FirestorePaths.invites(orgId))
        .where('locationId', isEqualTo: locationId)
        .where('status', isEqualTo: 'pending'),
    Invite.fromMap,
  );

  @override
  Stream<List<Device>> devices(String orgId, String locationId) => _list(
    _db.collection(FirestorePaths.devices(orgId, locationId)),
    Device.fromMap,
  );

  @override
  Stream<List<MenuCategory>> menuCategories(String orgId) => _list(
    _db.collection(FirestorePaths.menuCategories(orgId)),
    MenuCategory.fromMap,
  );

  @override
  Stream<List<MenuItem>> menuItems(String orgId) =>
      _list(_db.collection(FirestorePaths.menuItems(orgId)), MenuItem.fromMap);

  @override
  Stream<List<ModifierGroup>> modifierGroups(String orgId) => _list(
    _db.collection(FirestorePaths.modifierGroups(orgId)),
    ModifierGroup.fromMap,
  );

  @override
  Stream<List<MenuOverride>> menuOverrides(String orgId, String locationId) =>
      _list(
        _db.collection(FirestorePaths.menuOverrides(orgId, locationId)),
        MenuOverride.fromMap,
      );

  Map<String, Object?> _stamp(Map<String, Object?> data) => {
    ...data,
    'updatedAt': FieldValue.serverTimestamp(),
    'updatedBy': _auth.currentUser?.uid,
  };

  Future<String> _save(
    String collection,
    String id,
    Map<String, Object?> data,
  ) async {
    final ref = id.isEmpty
        ? _db.collection(collection).doc()
        : _db.collection(collection).doc(id);
    try {
      await ref.set(_stamp(data));
    } on FirebaseException catch (e) {
      throw BackendException(
        e.code,
        e.code == 'permission-denied'
            ? 'You don\'t have permission to change the menu.'
            : (e.message ?? 'Couldn\'t save.'),
      );
    }
    return ref.id;
  }

  @override
  Future<String> saveMenuItem(MenuItem item) {
    item.validate();
    return _save(FirestorePaths.menuItems(item.orgId), item.id, item.toMap());
  }

  @override
  Future<String> saveMenuCategory(MenuCategory category) {
    category.validate();
    return _save(
      FirestorePaths.menuCategories(category.orgId),
      category.id,
      category.toMap(),
    );
  }

  @override
  Future<void> saveMenuOverride(
    MenuOverride override, {
    bool resetPrice = false,
  }) async {
    final ref = _db.doc(
      '${FirestorePaths.menuOverrides(override.orgId, override.locationId)}/${override.itemId}',
    );
    try {
      // Merge so a cashier's sold-out toggle only touches the fields they may change.
      await ref.set(
        _stamp({
          'orgId': override.orgId,
          'locationId': override.locationId,
          'itemId': override.itemId,
          'available': override.available,
          if (override.priceCents != null || resetPrice)
            'priceCents': override.priceCents,
        }),
        SetOptions(merge: true),
      );
    } on FirebaseException catch (e) {
      throw BackendException(e.code, e.message ?? 'Couldn\'t save.');
    }
  }
}
