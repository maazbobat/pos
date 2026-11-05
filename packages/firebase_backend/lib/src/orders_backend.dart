import 'package:cloud_firestore/cloud_firestore.dart' hide Order;
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:pos_shared/pos_shared.dart';

Map<String, Object?> _plain(Map<String, dynamic> data) => {
  for (final e in data.entries)
    e.key: e.value is Timestamp ? (e.value as Timestamp).toDate() : e.value,
};

Future<Map<String, Object?>> _call(
  FirebaseFunctions fns,
  String name,
  Map<String, Object?> data,
) async {
  try {
    final result = await fns.httpsCallable(name).call<Object?>(data);
    final value = result.data;
    return value is Map ? _deep(value) : const {};
  } on FirebaseFunctionsException catch (e) {
    throw BackendException(e.code, e.message ?? 'Something went wrong.');
  }
}

/// Callable results arrive as `Map<Object?, Object?>` all the way down.
Map<String, Object?> _deep(Map<Object?, Object?> m) => {
  for (final e in m.entries) e.key as String: _deepValue(e.value),
};
Object? _deepValue(Object? v) => switch (v) {
  Map() => _deep(v),
  List() => [for (final x in v) _deepValue(x)],
  _ => v,
};

class FirestoreOrdersBackend implements OrdersBackend {
  FirestoreOrdersBackend(this._db, this._auth, this._fns);
  final FirebaseFirestore _db;
  final FirebaseAuth _auth;
  final FirebaseFunctions _fns;

  Order _order(DocumentSnapshot<Map<String, dynamic>> d) =>
      Order.fromMap(d.id, _plain(d.data() ?? const {}));

  @override
  String newOrderId(String orgId, String locationId) =>
      _db.collection(FirestorePaths.orders(orgId, locationId)).doc().id;

  @override
  Stream<List<TaxRate>> taxRates(String orgId, String locationId) => _db
      .doc(FirestorePaths.settings(orgId, locationId, 'tax'))
      .snapshots()
      .map(
        (s) => [
          for (final r in (s.data()?['rates'] as List?) ?? const [])
            TaxRate.fromMap(Map<String, Object?>.from(r as Map)),
        ],
      );

  void _commitInBackground(WriteBatch batch, String what) {
    // Offline, commit() only completes once the server has the write, so
    // don't wait for it: Firestore keeps the write and sends it later.
    batch.commit().catchError((Object e) {
      debugPrint('$what was refused: $e');
    });
  }

  @override
  Future<void> placeCashOrder(PosOrderDraft draft) async {
    final uid = _auth.currentUser!.uid;
    final orderRef = _db.doc(
      FirestorePaths.order(draft.orgId, draft.locationId, draft.orderId),
    );
    final paymentId = cashPaymentIdFor(draft.orderId);
    final batch = _db.batch()
      ..set(orderRef, {
        ...draft.toMap(createdBy: uid, paymentStatus: PaymentStatus.paid),
        'createdAt': FieldValue.serverTimestamp(),
      })
      ..set(orderRef.collection('payments').doc(paymentId), {
        'orgId': draft.orgId,
        'locationId': draft.locationId,
        'orderId': draft.orderId,
        'method': 'cash',
        'provider': 'cash',
        'amountCents': draft.cart.totals.totalCents,
        'tipCents': 0,
        'status': 'succeeded',
        'idempotencyKey': paymentId,
        'staffUid': draft.staffUid,
        'createdBy': uid,
        'createdAt': FieldValue.serverTimestamp(),
      });
    _commitInBackground(batch, 'Order ${draft.ticket}');
  }

  @override
  Stream<List<Order>> kitchenOrders(String orgId, String locationId) => _db
      .collection(FirestorePaths.orders(orgId, locationId))
      .where('status', whereIn: [for (final s in OrderStatus.kitchen) s.wire])
      .orderBy('createdAt')
      .limit(100)
      .snapshots()
      .map((q) => [for (final d in q.docs) _order(d)]);

  @override
  Stream<List<Order>> recentOrders(
    String orgId,
    String locationId, {
    int limit = 50,
  }) => _db
      .collection(FirestorePaths.orders(orgId, locationId))
      .orderBy('createdAt', descending: true)
      .limit(limit)
      .snapshots()
      .map((q) => [for (final d in q.docs) _order(d)]);

  @override
  Future<void> setOrderStatus(Order order, OrderStatus status) async {
    final batch = _db.batch()
      ..update(
        _db.doc(FirestorePaths.order(order.orgId, order.locationId, order.id)),
        {
          'status': status.wire,
          'updatedAt': FieldValue.serverTimestamp(),
          'updatedBy': _auth.currentUser?.uid,
        },
      );
    _commitInBackground(batch, 'Order ${order.ticket} status');
  }

  @override
  Future<void> recordCashPayment(Order order, {String? staffUid}) async {
    final uid = _auth.currentUser!.uid;
    final orderRef = _db.doc(
      FirestorePaths.order(order.orgId, order.locationId, order.id),
    );
    final paymentId = cashPaymentIdFor(order.id);
    final batch = _db.batch()
      ..set(orderRef.collection('payments').doc(paymentId), {
        'orgId': order.orgId,
        'locationId': order.locationId,
        'orderId': order.id,
        'method': 'cash',
        'provider': 'cash',
        'amountCents': order.totals.totalCents,
        'tipCents': 0,
        'status': 'succeeded',
        'idempotencyKey': paymentId,
        'staffUid': staffUid,
        'createdBy': uid,
        'createdAt': FieldValue.serverTimestamp(),
      })
      ..update(orderRef, {
        'paymentStatus': PaymentStatus.paid.wire,
        'staffUid': staffUid,
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedBy': uid,
      });
    _commitInBackground(batch, 'Payment for ${order.ticket}');
  }

  @override
  Stream<OnlineOrderingSettings?> onlineOrdering(
    String orgId,
    String locationId,
  ) => _db
      .doc(FirestorePaths.settings(orgId, locationId, 'onlineOrdering'))
      .snapshots()
      .map((s) {
        final data = s.data();
        return data == null ? null : OnlineOrderingSettings.fromMap(data);
      });

  @override
  Future<OnlineOrderingSettings> updateOnlineOrdering(
    String orgId,
    String locationId, {
    bool? enabled,
    bool? paused,
    String? slug,
    bool? payAtPickup,
    bool? payOnline,
    int? pickupLeadMinutes,
    String? stripeAccountId,
  }) async {
    final r = await _call(_fns, Callables.updateOnlineOrdering, {
      'orgId': orgId,
      'locationId': locationId,
      'enabled': ?enabled,
      'paused': ?paused,
      'slug': ?slug,
      'payAtPickup': ?payAtPickup,
      'payOnline': ?payOnline,
      'pickupLeadMinutes': ?pickupLeadMinutes,
      'stripeAccountId': ?stripeAccountId,
    });
    return OnlineOrderingSettings.fromMap(r);
  }
}

class FirebaseStorefrontBackend implements StorefrontBackend {
  FirebaseStorefrontBackend(this._fns);
  final FirebaseFunctions _fns;

  @override
  Future<Storefront> storefront(String slug) async => Storefront.fromMap(
    await _call(_fns, Callables.getStorefront, {'slug': slug}),
  );

  @override
  Future<PlacedOnlineOrder> placeOrder({
    required String slug,
    required String orderToken,
    required Cart cart,
    required OnlinePayment payment,
    required String customerName,
    String? phone,
    String? email,
    String? notes,
    DateTime? pickupAt,
  }) async {
    final r = await _call(_fns, Callables.placeOnlineOrder, {
      'slug': slug,
      'orderToken': orderToken,
      'payment': payment.wire,
      'items': cartRequest(cart),
      'customer': {'name': customerName, 'phone': phone, 'email': email},
      'notes': notes,
      'pickupAt': pickupAt?.millisecondsSinceEpoch,
    });
    return PlacedOnlineOrder(
      orderId: r['orderId'] as String,
      ticket: r['ticket'] as String,
      totalCents: (r['totalCents'] as num).toInt(),
      status: OrderStatus.fromWire(r['status'] as String?),
      checkoutUrl: r['checkoutUrl'] as String?,
    );
  }

  @override
  Future<OnlineOrderProgress> orderStatus({
    required String slug,
    required String orderId,
    required String orderToken,
  }) async => OnlineOrderProgress.fromMap(
    await _call(_fns, Callables.getOnlineOrderStatus, {
      'slug': slug,
      'orderId': orderId,
      'orderToken': orderToken,
    }),
  );
}

class FirestoreCounterBackend implements CounterBackend {
  FirestoreCounterBackend(this._db, this._auth, this._fns);
  final FirebaseFirestore _db;
  final FirebaseAuth _auth;
  final FirebaseFunctions _fns;

  Map<String, Object?> _ids(Order o) => {
    'orgId': o.orgId,
    'locationId': o.locationId,
    'orderId': o.id,
  };

  @override
  Stream<PaymentSettings> paymentSettings(String orgId, String locationId) =>
      _db
          .doc(FirestorePaths.settings(orgId, locationId, 'payments'))
          .snapshots()
          .map((s) => PaymentSettings.fromMap(s.data() ?? const {}));

  @override
  Stream<HardwareSettings> hardware(String orgId, String locationId) => _db
      .doc(FirestorePaths.settings(orgId, locationId, 'hardware'))
      .snapshots()
      .map((s) => HardwareSettings.fromMap(s.data() ?? const {}));

  @override
  Future<void> saveHardware(
    String orgId,
    String locationId,
    HardwareSettings settings,
  ) async {
    final ref = _db.doc(FirestorePaths.settings(orgId, locationId, 'hardware'));
    // Replace the printer map whole, so a removed printer goes away.
    await ref.set(
      {
        'orgId': orgId,
        'locationId': locationId,
        ...settings.toMap(),
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedBy': _auth.currentUser?.uid,
      },
      SetOptions(
        mergeFields: [
          'orgId',
          'locationId',
          'printers',
          'receipt',
          'autoPrintReceipt',
          'autoPrintKitchen',
          'updatedAt',
          'updatedBy',
        ],
      ),
    );
  }

  @override
  Future<void> placeUnpaidOrder(PosOrderDraft draft) async {
    final uid = _auth.currentUser!.uid;
    await _db
        .doc(FirestorePaths.order(draft.orgId, draft.locationId, draft.orderId))
        .set({
          ...draft.toMap(createdBy: uid, paymentStatus: PaymentStatus.unpaid),
          'createdAt': FieldValue.serverTimestamp(),
        });
  }

  @override
  Future<CardPaymentState> startCardPayment(
    Order order, {
    required int amountCents,
    required int tipCents,
    required String idempotencyKey,
    required String readerId,
  }) async => CardPaymentState.fromMap(
    await _call(_fns, Callables.startCardPayment, {
      ..._ids(order),
      'amountCents': amountCents,
      'tipCents': tipCents,
      'idempotencyKey': idempotencyKey,
      'terminalId': readerId,
    }),
  );

  @override
  Future<CardPaymentState> refreshPayment(
    Order order,
    String paymentId,
  ) async => CardPaymentState.fromMap(
    await _call(_fns, Callables.refreshPayment, {
      ..._ids(order),
      'paymentId': paymentId,
    }),
  );

  @override
  Future<CardPaymentState> cancelCardPayment(
    Order order,
    String paymentId,
  ) async => CardPaymentState.fromMap(
    await _call(_fns, Callables.cancelCardPayment, {
      ..._ids(order),
      'paymentId': paymentId,
    }),
  );

  @override
  Stream<List<OrderPayment>> payments(Order order) => _db
      .collection(
        FirestorePaths.payments(order.orgId, order.locationId, order.id),
      )
      .snapshots()
      .map(
        (q) => [
          for (final d in q.docs) OrderPayment.fromMap(d.id, _plain(d.data())),
        ],
      );

  @override
  Future<String> refundPayment(
    Order order, {
    required String paymentId,
    required int amountCents,
    required String reason,
    required String idempotencyKey,
    String? managerPin,
  }) async {
    final r = await _call(_fns, Callables.refundPayment, {
      ..._ids(order),
      'paymentId': paymentId,
      'amountCents': amountCents,
      'reason': reason,
      'idempotencyKey': idempotencyKey,
      'managerPin': ?managerPin,
    });
    return r['status'] as String? ?? 'failed';
  }

  @override
  Future<void> voidOrder(
    Order order, {
    required String reason,
    String? managerPin,
  }) async {
    await _call(_fns, Callables.voidOrder, {
      ..._ids(order),
      'reason': reason,
      'managerPin': ?managerPin,
    });
  }

  @override
  Future<CardReader> registerCardReader(
    String orgId,
    String locationId, {
    required String readerId,
    required String name,
    required String registrationCode,
    String? addressLine1,
    String? city,
    String? postalCode,
  }) async {
    final r = await _call(_fns, Callables.registerCardReader, {
      'orgId': orgId,
      'locationId': locationId,
      'terminalId': readerId,
      'name': name,
      'registrationCode': registrationCode,
      'addressLine1': ?addressLine1,
      'city': ?city,
      'postalCode': ?postalCode,
    });
    return CardReader(id: readerId, name: name, model: r['model'] as String?);
  }
}
