/// An in-memory [Backend] for widget tests. It applies no permission rules:
/// those are tested against the emulators in `tests/rules` and `functions/`.
library;

import 'dart:async';

import 'pos_shared.dart';

class FakeBackend {
  FakeBackend() {
    backend = Backend(
      auth: auth,
      functions: functions,
      data: data,
      billing: billing,
      platform: platform,
      orders: orders,
      counter: counter,
    );
  }

  late final Backend backend;
  final FakeAuth auth = FakeAuth();
  final FakeFunctions functions = FakeFunctions();
  late final FakeData data = FakeData(auth);
  final FakeBilling billing = FakeBilling();
  final FakePlatform platform = FakePlatform();
  final FakeOrders orders = FakeOrders();
  late final FakeCounter counter = FakeCounter(orders);
}

/// A broadcast of "something changed", for the fakes' streams.
class _Changes {
  final _c = StreamController<void>.broadcast();
  void notify() => _c.add(null);
  Stream<T> watch<T>(T Function() read) async* {
    yield read();
    yield* _c.stream.map((_) => read());
  }
}

class FakeBilling implements BillingBackend {
  final _changes = _Changes();
  final List<String> calls = [];
  final Map<String, Subscription> subscriptions = {};
  final Map<String, List<SupportGrant>> grants = {};
  final Map<String, List<AuditEntry>> audit = {};

  void notify() => _changes.notify();

  @override
  Stream<Subscription?> subscription(String orgId) =>
      _changes.watch(() => subscriptions[orgId]);

  @override
  Future<Uri> startCheckout(String orgId, Plan plan) async {
    calls.add('startCheckout:$orgId:${plan.name}');
    return Uri.parse('https://checkout.stripe.test/${plan.name}');
  }

  @override
  Future<Uri> openBillingPortal(String orgId) async {
    calls.add('openBillingPortal:$orgId');
    return Uri.parse('https://billing.stripe.test/$orgId');
  }

  @override
  Stream<List<SupportGrant>> supportGrants(String orgId) =>
      _changes.watch(() => grants[orgId] ?? const []);

  @override
  Future<void> revokeSupportAccess(String orgId, String adminUid) async {
    calls.add('revokeSupportAccess:$orgId:$adminUid');
    grants[orgId]?.removeWhere((g) => g.adminUid == adminUid);
    notify();
  }

  @override
  Stream<List<AuditEntry>> auditLog(String orgId, {int limit = 50}) =>
      _changes.watch(() => audit[orgId] ?? const []);
}

class FakePlatform implements PlatformBackend {
  final _changes = _Changes();
  final List<String> calls = [];
  final Set<String> admins = {};
  final Map<String, TenantSummary> tenantsById = {};
  final List<AuditEntry> auditEntries = [];
  HealthSummary? healthSummary;
  final List<Incident> incidents = [];
  final Map<String, SupportGrant> grants = {}; // key: orgId/adminUid

  void notify() => _changes.notify();

  @override
  Stream<bool> isPlatformAdmin(String uid) =>
      _changes.watch(() => admins.contains(uid));
  @override
  Stream<List<TenantSummary>> tenants() =>
      _changes.watch(() => tenantsById.values.toList());
  @override
  Stream<TenantSummary?> tenant(String orgId) =>
      _changes.watch(() => tenantsById[orgId]);
  @override
  Stream<List<AuditEntry>> platformAudit({String? orgId, int limit = 50}) =>
      _changes.watch(
        () => [
          for (final e in auditEntries)
            if (orgId == null || e.orgId == orgId) e,
        ],
      );
  @override
  Stream<HealthSummary?> health() => _changes.watch(() => healthSummary);
  @override
  Stream<List<Incident>> openIncidents() =>
      _changes.watch(() => List.of(incidents));
  @override
  Stream<SupportGrant?> mySupportGrant(String orgId, String adminUid) =>
      _changes.watch(() => grants['$orgId/$adminUid']);

  @override
  Future<DateTime> grantSupportAccess(
    String orgId, {
    required String reason,
    required int hours,
  }) async {
    calls.add('grantSupportAccess:$orgId:$hours:$reason');
    final expiresAt = DateTime.now().add(Duration(hours: hours));
    grants['$orgId/platform-admin'] = SupportGrant(
      adminUid: 'platform-admin',
      reason: reason,
      expiresAt: expiresAt,
    );
    notify();
    return expiresAt;
  }

  @override
  Future<void> revokeMySupportAccess(String orgId) async {
    calls.add('revokeMySupportAccess:$orgId');
    grants.remove('$orgId/platform-admin');
    notify();
  }

  @override
  Future<void> setOrgSuspended(
    String orgId, {
    required bool suspended,
    required String reason,
  }) async => calls.add('setOrgSuspended:$orgId:$suspended:$reason');

  @override
  Future<void> setManualPlan(
    String orgId, {
    required Plan plan,
    required bool active,
    required String reason,
  }) async => calls.add('setManualPlan:$orgId:${plan.name}:$active:$reason');

  @override
  Future<DateTime> extendTrial(
    String orgId, {
    required int days,
    required String reason,
  }) async {
    calls.add('extendTrial:$orgId:$days:$reason');
    return DateTime.now().add(Duration(days: days));
  }

  @override
  Future<void> resolveIncident(
    String incidentId, {
    required String note,
  }) async {
    calls.add('resolveIncident:$incidentId:$note');
    incidents.removeWhere((i) => i.id == incidentId);
    notify();
  }
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
  Stream<Device?> device(String orgId, String locationId, String deviceId) =>
      _watch(
        () => (devicesByLocation[locationId] ?? const <Device>[])
            .where((d) => d.id == deviceId)
            .firstOrNull,
      );
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

/// Orders kept in memory. [placed] records what the POS wrote, payments
/// included, in the shape the rules check.
class FakeOrders implements OrdersBackend {
  final _changes = _Changes();
  final Map<String, Order> orders = {};
  final List<Map<String, Object?>> placed = [];
  final List<String> calls = [];
  List<TaxRate> rates = const [TaxRate(id: 'hst', name: 'HST', rate: 0.13)];
  OnlineOrderingSettings? online;
  var _next = 0;
  DateTime now = DateTime(2026, 11, 5, 12);

  void notify() => _changes.notify();

  @override
  String newOrderId(String orgId, String locationId) => 'order-${++_next}';

  @override
  Stream<List<TaxRate>> taxRates(String orgId, String locationId) =>
      _changes.watch(() => rates);

  @override
  Future<void> placeCashOrder(PosOrderDraft draft) async {
    final data = draft.toMap(
      createdBy: 'device',
      paymentStatus: PaymentStatus.paid,
    );
    placed.add({
      ...data,
      'payment': {
        'id': cashPaymentIdFor(draft.orderId),
        'amountCents': draft.cart.totals.totalCents,
        'method': 'cash',
      },
    });
    orders[draft.orderId] = Order.fromMap(draft.orderId, {
      ...data,
      'createdAt': now,
    });
    notify();
  }

  @override
  Stream<List<Order>> kitchenOrders(String orgId, String locationId) =>
      _changes.watch(
        () => [
          for (final o in orders.values)
            if (o.locationId == locationId && o.status.isActive) o,
        ],
      );

  @override
  Stream<List<Order>> recentOrders(
    String orgId,
    String locationId, {
    int limit = 50,
  }) => _changes.watch(
    () => [
      for (final o in orders.values.toList().reversed)
        if (o.locationId == locationId) o,
    ],
  );

  Order _copy(Order o, {OrderStatus? status, PaymentStatus? paymentStatus}) =>
      Order(
        id: o.id,
        orgId: o.orgId,
        locationId: o.locationId,
        source: o.source,
        ticket: o.ticket,
        status: status ?? o.status,
        paymentStatus: paymentStatus ?? o.paymentStatus,
        fulfillment: o.fulfillment,
        items: o.items,
        totals: o.totals,
        discounts: o.discounts,
        customer: o.customer,
        pickupAt: o.pickupAt,
        createdAt: o.createdAt,
        channel: o.channel,
        notes: o.notes,
      );

  @override
  Future<void> setOrderStatus(Order order, OrderStatus status) async {
    calls.add('status:${order.id}:${status.wire}');
    orders[order.id] = _copy(orders[order.id] ?? order, status: status);
    notify();
  }

  @override
  Future<void> recordCashPayment(Order order, {String? staffUid}) async {
    calls.add('cash:${order.id}:${order.totals.totalCents}');
    orders[order.id] = _copy(
      orders[order.id] ?? order,
      paymentStatus: PaymentStatus.paid,
    );
    notify();
  }

  @override
  Stream<OnlineOrderingSettings?> onlineOrdering(
    String orgId,
    String locationId,
  ) => _changes.watch(() => online);

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
    String? contactPhone,
    String? contactEmail,
  }) async {
    final o = online ?? const OnlineOrderingSettings();
    String? contact(String? next, String? old) =>
        next == null ? old : (next.trim().isEmpty ? null : next.trim());
    calls.add(
      'online:${[if (enabled != null) 'enabled=$enabled', if (paused != null) 'paused=$paused', if (slug != null) 'slug=$slug'].join(',')}',
    );
    online = OnlineOrderingSettings(
      enabled: enabled ?? o.enabled,
      paused: paused ?? o.paused,
      slug: slug ?? o.slug,
      payAtPickup: payAtPickup ?? o.payAtPickup,
      payOnline: payOnline ?? o.payOnline,
      pickupLeadMinutes: pickupLeadMinutes ?? o.pickupLeadMinutes,
      stripeAccountId: stripeAccountId ?? o.stripeAccountId,
      contactPhone: contact(contactPhone, o.contactPhone),
      contactEmail: contact(contactEmail, o.contactEmail),
    );
    notify();
    return online!;
  }
}

/// The ordering site's Functions, in memory.
class FakeStorefrontBackend implements StorefrontBackend {
  FakeStorefrontBackend(this.store);
  Storefront store;
  final List<Map<String, Object?>> placed = [];
  OrderStatus progress = OrderStatus.newOrder;

  /// Make the next storefront or order-status call fail, like a dropped connection.
  Object? failNext;

  /// Make placeOrder wait for this before answering, to see the busy state.
  Completer<void>? holdPlaceOrder;

  Object? _takeFailure() {
    final f = failNext;
    failNext = null;
    return f;
  }

  @override
  Future<Storefront> storefront(String slug) async {
    if (_takeFailure() case final f?) throw f;
    if (slug != store.slug) {
      throw const BackendException(
        'not-found',
        "We couldn't find that restaurant.",
      );
    }
    return store;
  }

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
    placed.add({
      'slug': slug,
      'orderToken': orderToken,
      'items': cartRequest(cart),
      'payment': payment.wire,
      'customer': {'name': customerName, 'phone': phone, 'email': email},
    });
    await holdPlaceOrder?.future;
    return PlacedOnlineOrder(
      orderId: 'web_1',
      ticket: 'W-417',
      totalCents: cart.totals.totalCents,
      status: payment == OnlinePayment.online
          ? OrderStatus.awaitingPayment
          : OrderStatus.newOrder,
      checkoutUrl: payment == OnlinePayment.online
          ? 'https://checkout.stripe.test/web_1'
          : null,
    );
  }

  @override
  Future<OnlineOrderProgress> orderStatus({
    required String slug,
    required String orderId,
    required String orderToken,
  }) async {
    if (_takeFailure() case final f?) throw f;
    return OnlineOrderProgress(
      orderId: orderId,
      storeName: store.displayName,
      address: store.address,
      phone: store.phone,
      ticket: 'W-417',
      status: progress,
      paymentStatus: PaymentStatus.unpaid,
      totalCents: 1639,
      items: const [
        (name: 'Taro milk tea', qty: 2, modifiers: ['Large']),
      ],
    );
  }
}

/// Card payments, refunds and hardware settings, in memory. Card charges
/// wait as pending until [settle] is called, like a guest at the reader.
class FakeCounter implements CounterBackend {
  FakeCounter(this.orders);
  final FakeOrders orders;
  final _changes = _Changes();
  PaymentSettings settings = const PaymentSettings();
  HardwareSettings hardwareSettings = const HardwareSettings();
  final Map<String, List<OrderPayment>> paymentsByOrder = {};
  final Map<String, CardPaymentState> charges = {};
  final List<String> calls = [];

  /// The manager PIN refunds and voids accept on a device.
  String managerPin = '2580';

  /// Make the next charge fail at once with this reason, like an offline reader.
  String? failNextWith;

  void notify() => _changes.notify();

  @override
  Stream<PaymentSettings> paymentSettings(String orgId, String locationId) =>
      _changes.watch(() => settings);

  @override
  Stream<HardwareSettings> hardware(String orgId, String locationId) =>
      _changes.watch(() => hardwareSettings);

  @override
  Future<void> saveHardware(
    String orgId,
    String locationId,
    HardwareSettings s,
  ) async {
    calls.add('hardware:${s.printers.length}');
    hardwareSettings = s;
    notify();
  }

  @override
  Future<void> placeUnpaidOrder(PosOrderDraft draft) async {
    final data = draft.toMap(
      createdBy: 'device',
      paymentStatus: PaymentStatus.unpaid,
    );
    orders.placed.add(data);
    orders.orders[draft.orderId] = Order.fromMap(draft.orderId, {
      ...data,
      'createdAt': orders.now,
    });
    orders.notify();
  }

  void _setPaid(String orderId, PaymentStatus status) {
    final o = orders.orders[orderId];
    if (o == null) return;
    orders.orders[orderId] = orders._copy(o, paymentStatus: status);
    orders.notify();
  }

  @override
  Future<CardPaymentState> startCardPayment(
    Order order, {
    required int amountCents,
    required int tipCents,
    required String idempotencyKey,
    required String readerId,
  }) async {
    final id = 'card_$idempotencyKey';
    if (charges[id] case final existing?) return existing;
    calls.add('charge:${order.id}:$amountCents+$tipCents@$readerId');
    final fail = failNextWith;
    failNextWith = null;
    final state = CardPaymentState(
      paymentId: id,
      status: fail == null
          ? CardPaymentStatus.pending
          : CardPaymentStatus.failed,
      failureReason: fail,
    );
    charges[id] = state;
    (paymentsByOrder[order.id] ??= []).add(
      OrderPayment(
        id: id,
        method: 'card',
        provider: 'stripe_terminal',
        amountCents: amountCents,
        tipCents: tipCents,
        status: state.status,
      ),
    );
    notify();
    return state;
  }

  /// The guest at the reader: approve or decline the pending charge.
  void settle(String paymentId, CardPaymentStatus status, {String? reason}) {
    charges[paymentId] = CardPaymentState(
      paymentId: paymentId,
      status: status,
      failureReason: reason,
    );
    for (final entry in paymentsByOrder.entries) {
      final list = entry.value;
      for (var i = 0; i < list.length; i++) {
        final p = list[i];
        if (p.id != paymentId) continue;
        list[i] = OrderPayment(
          id: p.id,
          method: p.method,
          provider: p.provider,
          amountCents: p.amountCents,
          tipCents: p.tipCents,
          status: status,
        );
        if (status == CardPaymentStatus.succeeded) {
          _setPaid(entry.key, PaymentStatus.paid);
        }
      }
    }
    notify();
  }

  @override
  Future<CardPaymentState> refreshPayment(Order order, String paymentId) async {
    calls.add('refresh:$paymentId');
    return charges[paymentId]!;
  }

  @override
  Future<CardPaymentState> cancelCardPayment(
    Order order,
    String paymentId,
  ) async {
    calls.add('cancel:$paymentId');
    if (charges[paymentId]?.status == CardPaymentStatus.pending) {
      settle(paymentId, CardPaymentStatus.canceled);
    }
    return charges[paymentId]!;
  }

  @override
  Stream<List<OrderPayment>> payments(Order order) => _changes.watch(() {
    final list = [...?paymentsByOrder[order.id]];
    if (list.isEmpty && order.paymentStatus != PaymentStatus.unpaid) {
      list.add(
        OrderPayment(
          id: cashPaymentIdFor(order.id),
          method: 'cash',
          provider: 'cash',
          amountCents: order.totals.totalCents,
          status: CardPaymentStatus.succeeded,
        ),
      );
    }
    return list;
  });

  void _checkPin(String? pin) {
    if (pin != null && pin != managerPin) {
      throw const BackendException(
        'permission-denied',
        'That PIN isn\'t a manager\'s.',
      );
    }
  }

  @override
  Future<String> refundPayment(
    Order order, {
    required String paymentId,
    required int amountCents,
    required String reason,
    required String idempotencyKey,
    String? managerPin,
  }) async {
    _checkPin(managerPin);
    calls.add('refund:$paymentId:$amountCents:$reason');
    _setPaid(order.id, PaymentStatus.refunded);
    return 'succeeded';
  }

  @override
  Future<void> voidOrder(
    Order order, {
    required String reason,
    String? managerPin,
  }) async {
    _checkPin(managerPin);
    calls.add('void:${order.id}:$reason');
    final o = orders.orders[order.id] ?? order;
    orders.orders[order.id] = orders._copy(o, status: OrderStatus.voided);
    orders.notify();
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
    calls.add('register:$readerId:$registrationCode');
    final reader = CardReader(id: readerId, name: name, model: 'stripe_s700');
    settings = PaymentSettings(
      cardProvider: 'stripe_terminal',
      readers: [...settings.readers, reader],
    );
    notify();
    return reader;
  }
}
