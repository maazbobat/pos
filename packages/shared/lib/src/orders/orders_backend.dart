import '../menu/location_menu.dart';
import '../menu/menu_models.dart';
import 'cart.dart';
import 'order.dart';
import 'pricing.dart';

/// An order rung up on the POS, ready to write.
class PosOrderDraft {
  const PosOrderDraft({
    required this.orgId,
    required this.locationId,
    required this.orderId,
    required this.deviceId,
    required this.staffUid,
    required this.cart,
    this.notes,
  });

  final String orgId;
  final String locationId;

  /// From [OrdersBackend.newOrderId], made on the tablet so it works offline.
  final String orderId;
  final String? deviceId;
  final String? staffUid;
  final Cart cart;
  final String? notes;

  String get ticket => ticketFor(orderId);

  /// The document the rules expect (firestore.rules, validPosOrder), without
  /// the server timestamps the backend adds.
  Map<String, Object?> toMap({
    required String createdBy,
    required PaymentStatus paymentStatus,
  }) {
    final totals = cart.totals;
    return {
      'orgId': orgId,
      'locationId': locationId,
      'source': OrderSource.pos.name,
      'ticket': ticket,
      'status': OrderStatus.newOrder.wire,
      'paymentStatus': paymentStatus.wire,
      'fulfillment': cart.fulfillment.name,
      'items': [for (final l in cart.lines) l.toMap()],
      'totals': totals.toMap(),
      'discounts': [for (final d in cart.discounts) d.toMap()],
      'notes': notes,
      'createdBy': createdBy,
      'deviceId': deviceId,
      'staffUid': staffUid,
      'idempotencyKey': orderId,
    };
  }
}

/// The ID of the cash payment for an order. Also its idempotency key, so a
/// retried write can't record the same cash twice.
String cashPaymentIdFor(String orderId) => 'cash_$orderId';

/// `settings/onlineOrdering`, written only by the updateOnlineOrdering Function.
class OnlineOrderingSettings {
  const OnlineOrderingSettings({
    this.enabled = false,
    this.paused = false,
    this.slug,
    this.payAtPickup = true,
    this.payOnline = false,
    this.pickupLeadMinutes = 15,
    this.stripeAccountId,
    this.contactPhone,
    this.contactEmail,
  });

  final bool enabled;
  final bool paused;

  /// The store's web address on the ordering site, for example `maple-cambridge`.
  final String? slug;
  final bool payAtPickup;
  final bool payOnline;
  final int pickupLeadMinutes;

  /// The restaurant's connected Stripe account (acct_…), owner-set.
  final String? stripeAccountId;

  /// Shown to guests on the ordering site and its privacy page.
  final String? contactPhone;
  final String? contactEmail;

  factory OnlineOrderingSettings.fromMap(Map<String, Object?> data) =>
      OnlineOrderingSettings(
        enabled: data['enabled'] as bool? ?? false,
        paused: data['paused'] as bool? ?? false,
        slug: data['slug'] as String?,
        payAtPickup: data['payAtPickup'] as bool? ?? true,
        payOnline: data['payOnline'] as bool? ?? false,
        pickupLeadMinutes: (data['pickupLeadMinutes'] as num?)?.toInt() ?? 15,
        stripeAccountId: data['stripeAccountId'] as String?,
        contactPhone: data['contactPhone'] as String?,
        contactEmail: data['contactEmail'] as String?,
      );
}

/// Orders at one location: what the POS and kitchen display read and write.
abstract interface class OrdersBackend {
  /// A new random order ID, made locally so ringing up works offline.
  String newOrderId(String orgId, String locationId);

  /// The location's tax rates from `settings/tax`.
  Stream<List<TaxRate>> taxRates(String orgId, String locationId);

  /// Writes the order and its cash payment together. Returns once the write
  /// is queued: Firestore sends it when the tablet is online, so a dropped
  /// connection never stops a sale.
  Future<void> placeCashOrder(PosOrderDraft draft);

  /// Orders the kitchen is working on, oldest first.
  Stream<List<Order>> kitchenOrders(String orgId, String locationId);

  /// Today's orders, newest first, for the POS order list.
  Stream<List<Order>> recentOrders(
    String orgId,
    String locationId, {
    int limit = 50,
  });

  Future<void> setOrderStatus(Order order, OrderStatus status);

  /// Cash taken at the counter for an order placed earlier, such as an
  /// online order paid at pickup.
  Future<void> recordCashPayment(Order order, {String? staffUid});

  Stream<OnlineOrderingSettings?> onlineOrdering(
    String orgId,
    String locationId,
  );

  /// Calls updateOnlineOrdering. Leave a field null to keep it; an empty
  /// [contactPhone] or [contactEmail] clears it.
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
  });
}

/// The ordering site's view of a store, from the public getStorefront Function.
class Storefront {
  const Storefront({
    required this.slug,
    required this.brandName,
    required this.locationName,
    required this.open,
    required this.payAtPickup,
    required this.payOnline,
    required this.pickupLeadMinutes,
    required this.taxRates,
    required this.sections,
    this.closedReason,
    this.address,
    this.province,
    this.phone,
    this.email,
  });

  final String slug;
  final String brandName;
  final String locationName;

  /// The location's street address, phone and email as the restaurant
  /// entered them. Null when not set: the site never makes one up.
  final String? address;
  final String? province;
  final String? phone;
  final String? email;

  /// "Brand · Location", or whichever of the two is set.
  String get displayName =>
      [brandName, locationName].where((s) => s.trim().isNotEmpty).join(' · ');
  final bool open;
  final String? closedReason;
  final bool payAtPickup;
  final bool payOnline;
  final int pickupLeadMinutes;
  final List<TaxRate> taxRates;

  /// Built into the same shapes the POS uses, so the site can use [Cart] and
  /// [OrderLine.fromMenu] to show prices. The server prices the order again.
  final List<LocationMenuSection> sections;

  factory Storefront.fromMap(Map<String, Object?> data) {
    final slug = data['slug'] as String? ?? '';
    List<Map<String, Object?>> maps(Object? v) => [
      for (final e in (v as List?) ?? const [])
        Map<String, Object?>.from(e as Map),
    ];
    return Storefront(
      slug: slug,
      brandName: data['brandName'] as String? ?? '',
      locationName: data['locationName'] as String? ?? '',
      open: data['open'] as bool? ?? false,
      closedReason: data['closedReason'] as String?,
      address: data['address'] as String?,
      province: data['province'] as String?,
      phone: data['phone'] as String?,
      email: data['email'] as String?,
      payAtPickup: data['payAtPickup'] as bool? ?? false,
      payOnline: data['payOnline'] as bool? ?? false,
      pickupLeadMinutes: (data['pickupLeadMinutes'] as num?)?.toInt() ?? 15,
      taxRates: [for (final r in maps(data['taxRates'])) TaxRate.fromMap(r)],
      sections: [
        for (final (i, s) in maps(data['sections']).indexed)
          LocationMenuSection(
            category: MenuCategory(
              id: s['id'] as String? ?? '',
              orgId: '',
              name: s['name'] as String? ?? '',
              sortOrder: i,
            ),
            items: [
              for (final item in maps(s['items']))
                LocationMenuItem(
                  item: MenuItem(
                    id: item['id'] as String? ?? '',
                    orgId: '',
                    name: item['name'] as String? ?? '',
                    description: item['description'] as String?,
                    categoryId: s['id'] as String? ?? '',
                    priceCents: (item['priceCents'] as num?)?.toInt() ?? 0,
                    taxable: item['taxable'] as bool? ?? true,
                    imagePath: item['imagePath'] as String?,
                  ),
                  priceCents: (item['priceCents'] as num?)?.toInt() ?? 0,
                  available: item['available'] as bool? ?? false,
                  modifierGroups: [
                    for (final g in maps(item['modifierGroups']))
                      ModifierGroup.fromMap(g['id'] as String? ?? '', {
                        ...g,
                        'orgId': '',
                      }),
                  ],
                ),
            ],
          ),
      ],
    );
  }
}

enum OnlinePayment {
  atPickup('at_pickup'),
  online('online');

  const OnlinePayment(this.wire);
  final String wire;
}

class PlacedOnlineOrder {
  const PlacedOnlineOrder({
    required this.orderId,
    required this.ticket,
    required this.totalCents,
    required this.status,
    this.checkoutUrl,
  });
  final String orderId;
  final String ticket;
  final int totalCents;
  final OrderStatus status;

  /// Send the guest here to pay by card.
  final String? checkoutUrl;
}

class OnlineOrderProgress {
  const OnlineOrderProgress({
    required this.orderId,
    required this.ticket,
    required this.status,
    required this.paymentStatus,
    required this.totalCents,
    required this.items,
    this.pickupAt,
    this.checkoutUrl,
    this.storeName = '',
    this.address,
    this.phone,
  });
  final String orderId;

  /// Who has the order and where to pick it up, for the thank-you page.
  final String storeName;
  final String? address;
  final String? phone;
  final String ticket;
  final OrderStatus status;
  final PaymentStatus paymentStatus;
  final int totalCents;
  final DateTime? pickupAt;
  final String? checkoutUrl;
  final List<({String name, int qty, List<String> modifiers})> items;

  factory OnlineOrderProgress.fromMap(Map<String, Object?> data) {
    final pickup = data['pickupAt'];
    return OnlineOrderProgress(
      orderId: data['orderId'] as String? ?? '',
      ticket: data['ticket'] as String? ?? '',
      status: OrderStatus.fromWire(data['status'] as String?),
      paymentStatus: PaymentStatus.fromWire(data['paymentStatus'] as String?),
      totalCents: (data['totalCents'] as num?)?.toInt() ?? 0,
      pickupAt: pickup is num
          ? DateTime.fromMillisecondsSinceEpoch(pickup.toInt())
          : null,
      checkoutUrl: data['checkoutUrl'] as String?,
      storeName: data['storeName'] as String? ?? '',
      address: data['address'] as String?,
      phone: data['phone'] as String?,
      items: [
        for (final l in (data['items'] as List?) ?? const [])
          (
            name: (l as Map)['name'] as String? ?? '',
            qty: (l['qty'] as num?)?.toInt() ?? 1,
            modifiers: [
              for (final m in (l['modifiers'] as List?) ?? const [])
                m as String,
            ],
          ),
      ],
    );
  }
}

/// The public Functions the ordering site calls. Guests don't sign in.
abstract interface class StorefrontBackend {
  Future<Storefront> storefront(String slug);

  /// [orderToken] is a random string the site makes once per checkout: a
  /// retry with the same token returns the first order.
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
  });

  Future<OnlineOrderProgress> orderStatus({
    required String slug,
    required String orderId,
    required String orderToken,
  });
}

/// The cart in the shape placeOnlineOrder takes: item IDs and picks only,
/// never prices.
List<Map<String, Object?>> cartRequest(Cart cart) => [
  for (final l in cart.lines)
    {
      'itemId': l.itemId,
      'qty': l.qty,
      'modifiers': {
        for (final groupId in {for (final m in l.modifiers) m.groupId})
          groupId: [
            for (final m in l.modifiers)
              if (m.groupId == groupId) m.optionId,
          ],
      },
      'notes': l.notes,
    },
];
