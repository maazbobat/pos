import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:pos_shared/pos_shared.dart';

import 'environment.dart';
import 'orders_backend.dart';

/// Connects to the Firebase project this build was made for (see
/// [AppEnvironment] and docs/environments.md). With no dart-defines that's
/// the local emulators under the `demo-pos` project ID.
Future<Backend> initFirebaseBackend([
  AppEnvironment env = AppEnvironment.current,
]) async {
  final app = await Firebase.initializeApp(options: firebaseOptionsFor(env));
  final auth = FirebaseAuth.instanceFor(app: app);
  final firestore = FirebaseFirestore.instanceFor(app: app);
  final functions = FirebaseFunctions.instanceFor(
    app: app,
    region: Callables.region,
  );
  if (env.usesEmulators) {
    await auth.useAuthEmulator(env.emulatorHost, 9099);
    firestore.useFirestoreEmulator(env.emulatorHost, 8080);
    functions.useFunctionsEmulator(env.emulatorHost, 5001);
  }

  return Backend(
    auth: FirebaseAuthGateway(auth),
    functions: FirebaseOnboardingFunctions(functions),
    data: FirestoreTenantData(firestore, auth),
    billing: FirebaseBillingBackend(firestore, functions),
    platform: FirebasePlatformBackend(firestore, functions),
    orders: FirestoreOrdersBackend(firestore, auth, functions),
    counter: FirestoreCounterBackend(firestore, auth, functions),
  );
}

/// For the public ordering site: only the storefront Functions, no sign-in.
Future<StorefrontBackend> initStorefrontBackend([
  AppEnvironment env = AppEnvironment.current,
]) async {
  final app = await Firebase.initializeApp(options: firebaseOptionsFor(env));
  final functions = FirebaseFunctions.instanceFor(
    app: app,
    region: Callables.region,
  );
  if (env.usesEmulators) {
    functions.useFunctionsEmulator(env.emulatorHost, 5001);
  }
  return FirebaseStorefrontBackend(functions);
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
  Stream<Device?> device(String orgId, String locationId, String deviceId) =>
      _doc(
        '${FirestorePaths.devices(orgId, locationId)}/$deviceId',
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

/// Shared helpers for the billing and platform backends.
mixin _FirestoreReads {
  FirebaseFirestore get db;
  FirebaseFunctions get fns;

  static Map<String, Object?> plain(Map<String, dynamic> data) => {
    for (final e in data.entries)
      e.key: e.value is Timestamp ? (e.value as Timestamp).toDate() : e.value,
  };

  Stream<T?> doc<T>(
    String path,
    T Function(String id, Map<String, Object?> d) parse,
  ) => db.doc(path).snapshots().map((s) {
    final data = s.data();
    return data == null ? null : parse(s.id, plain(data));
  });

  Stream<List<T>> list<T>(
    Query<Map<String, dynamic>> query,
    T Function(String id, Map<String, Object?> d) parse,
  ) => query.snapshots().map(
    (q) => [for (final d in q.docs) parse(d.id, plain(d.data()))],
  );

  Future<Map<String, Object?>> call(
    String name,
    Map<String, Object?> data,
  ) async {
    try {
      final result = await fns.httpsCallable(name).call<Object?>(data);
      final value = result.data;
      return value is Map ? Map<String, Object?>.from(value) : const {};
    } on FirebaseFunctionsException catch (e) {
      throw BackendException(e.code, e.message ?? 'Something went wrong.');
    }
  }
}

class FirebaseBillingBackend with _FirestoreReads implements BillingBackend {
  FirebaseBillingBackend(this.db, this.fns);
  @override
  final FirebaseFirestore db;
  @override
  final FirebaseFunctions fns;

  @override
  Stream<Subscription?> subscription(String orgId) => doc(
    'orgs/$orgId/billing/subscription',
    (_, d) => Subscription.fromMap(d),
  );

  @override
  Future<Uri> startCheckout(String orgId, Plan plan) async {
    final r = await call(Callables.startCheckout, {
      'orgId': orgId,
      'plan': plan.name,
    });
    return Uri.parse(r['url'] as String);
  }

  @override
  Future<Uri> openBillingPortal(String orgId) async {
    final r = await call(Callables.openBillingPortal, {'orgId': orgId});
    return Uri.parse(r['url'] as String);
  }

  @override
  Stream<List<SupportGrant>> supportGrants(String orgId) =>
      list(db.collection('orgs/$orgId/supportGrants'), SupportGrant.fromMap);

  @override
  Future<void> revokeSupportAccess(String orgId, String adminUid) => call(
    Callables.revokeSupportAccess,
    {'orgId': orgId, 'adminUid': adminUid},
  );

  @override
  Stream<List<AuditEntry>> auditLog(String orgId, {int limit = 50}) => list(
    db
        .collection('orgs/$orgId/auditLog')
        .orderBy('createdAt', descending: true)
        .limit(limit),
    AuditEntry.fromMap,
  );
}

class FirebasePlatformBackend with _FirestoreReads implements PlatformBackend {
  FirebasePlatformBackend(this.db, this.fns);
  @override
  final FirebaseFirestore db;
  @override
  final FirebaseFunctions fns;

  @override
  Stream<bool> isPlatformAdmin(String uid) =>
      db.doc('platformAdmins/$uid').snapshots().map((s) => s.exists);

  @override
  Stream<List<TenantSummary>> tenants() => list(
    db.collection('platformOrgs').orderBy('name'),
    TenantSummary.fromMap,
  );

  @override
  Stream<TenantSummary?> tenant(String orgId) =>
      doc('platformOrgs/$orgId', TenantSummary.fromMap);

  @override
  Stream<List<AuditEntry>> platformAudit({String? orgId, int limit = 50}) {
    Query<Map<String, dynamic>> q = db.collection('platformAuditLog');
    if (orgId != null) q = q.where('orgId', isEqualTo: orgId);
    return list(
      q.orderBy('createdAt', descending: true).limit(limit),
      AuditEntry.fromMap,
    );
  }

  @override
  Stream<HealthSummary?> health() =>
      doc('platformHealth/summary', (_, d) => HealthSummary.fromMap(d));

  @override
  Stream<List<Incident>> openIncidents() => list(
    db
        .collection('platformIncidents')
        .where('resolved', isEqualTo: false)
        .orderBy('createdAt', descending: true),
    Incident.fromMap,
  );

  @override
  Stream<SupportGrant?> mySupportGrant(String orgId, String adminUid) =>
      doc('orgs/$orgId/supportGrants/$adminUid', SupportGrant.fromMap);

  @override
  Future<DateTime> grantSupportAccess(
    String orgId, {
    required String reason,
    required int hours,
  }) async {
    final r = await call(Callables.grantSupportAccess, {
      'orgId': orgId,
      'reason': reason,
      'hours': hours,
    });
    return DateTime.fromMillisecondsSinceEpoch(r['expiresAt'] as int);
  }

  @override
  Future<void> revokeMySupportAccess(String orgId) =>
      call(Callables.revokeSupportAccess, {'orgId': orgId});

  @override
  Future<void> setOrgSuspended(
    String orgId, {
    required bool suspended,
    required String reason,
  }) => call(Callables.setOrgStatus, {
    'orgId': orgId,
    'status': suspended ? 'suspended' : 'active',
    'reason': reason,
  });

  @override
  Future<void> setManualPlan(
    String orgId, {
    required Plan plan,
    required bool active,
    required String reason,
  }) => call(Callables.setManualPlan, {
    'orgId': orgId,
    'plan': plan.name,
    'active': active,
    'reason': reason,
  });

  @override
  Future<DateTime> extendTrial(
    String orgId, {
    required int days,
    required String reason,
  }) async {
    final r = await call(Callables.extendTrial, {
      'orgId': orgId,
      'days': days,
      'reason': reason,
    });
    return DateTime.fromMillisecondsSinceEpoch(r['trialEndsAt'] as int);
  }

  @override
  Future<void> resolveIncident(String incidentId, {required String note}) =>
      call(Callables.resolveIncident, {'incidentId': incidentId, 'note': note});
}
