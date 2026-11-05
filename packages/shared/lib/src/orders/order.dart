import '../menu/location_menu.dart';
import '../menu/menu_models.dart';
import 'pricing.dart';

/// Where an order came from.
enum OrderSource {
  /// Rung up on a POS tablet or by staff.
  pos,

  /// The restaurant's own ordering site. Priced by the server.
  online,

  /// Uber Eats, DoorDash, SkipTheDishes and others, through an aggregator.
  delivery;

  static OrderSource fromWire(String? value) =>
      values.where((s) => s.name == value).firstOrNull ?? pos;
}

/// Kitchen progress. Staff move orders through `new → in_progress → ready →
/// completed`. The server alone sets the others: online orders wait in
/// `awaiting_payment` until paid and become `canceled` if never paid, and
/// `voided` comes from the `voidOrder` Function.
enum OrderStatus {
  awaitingPayment('awaiting_payment'),
  newOrder('new'),
  inProgress('in_progress'),
  ready('ready'),
  completed('completed'),
  canceled('canceled'),
  voided('voided');

  const OrderStatus(this.wire);
  final String wire;

  static OrderStatus fromWire(String? value) =>
      values.where((s) => s.wire == value).firstOrNull ?? newOrder;

  /// Shown on the kitchen display.
  bool get isActive => this == newOrder || this == inProgress || this == ready;

  /// The next step when someone taps the ticket, or null at the end.
  OrderStatus? get next => switch (this) {
    newOrder => inProgress,
    inProgress => ready,
    ready => completed,
    _ => null,
  };

  /// The statuses the kitchen display asks for.
  static const kitchen = [newOrder, inProgress, ready];
}

enum PaymentStatus {
  unpaid('unpaid'),
  paid('paid'),
  partiallyRefunded('partially_refunded'),
  refunded('refunded');

  const PaymentStatus(this.wire);
  final String wire;

  static PaymentStatus fromWire(String? value) =>
      values.where((s) => s.wire == value).firstOrNull ?? unpaid;
}

/// How the guest gets the food.
enum Fulfillment {
  here,
  takeout,
  pickup,
  delivery;

  static Fulfillment fromWire(String? value) =>
      values.where((s) => s.name == value).firstOrNull ?? here;
}

/// A chosen modifier option, copied onto the order so later menu edits never
/// change what was sold.
class LineModifier {
  const LineModifier({
    required this.groupId,
    required this.optionId,
    required this.name,
    this.priceDeltaCents = 0,
  });

  final String groupId;
  final String optionId;
  final String name;
  final int priceDeltaCents;

  factory LineModifier.fromMap(Map<String, Object?> data) => LineModifier(
    groupId: data['groupId'] as String? ?? '',
    optionId: data['optionId'] as String? ?? '',
    name: data['name'] as String? ?? '',
    priceDeltaCents: (data['priceDeltaCents'] as num?)?.toInt() ?? 0,
  );

  Map<String, Object?> toMap() => {
    'groupId': groupId,
    'optionId': optionId,
    'name': name,
    'priceDeltaCents': priceDeltaCents,
  };
}

/// One line of an order: an item, its options and quantity, with names and
/// prices copied from the menu at the time of sale.
class OrderLine {
  const OrderLine({
    required this.lineId,
    required this.itemId,
    required this.name,
    required this.qty,
    required this.unitPriceCents,
    this.modifiers = const [],
    this.taxable = true,
    this.kitchenStation,
    this.notes,
  });

  final String lineId;
  final String itemId;
  final String name;
  final int qty;

  /// The item's price at this store, before options.
  final int unitPriceCents;
  final List<LineModifier> modifiers;
  final bool taxable;
  final String? kitchenStation;
  final String? notes;

  int get eachCents =>
      unitPriceCents + modifiers.fold(0, (sum, m) => sum + m.priceDeltaCents);
  int get lineTotalCents => qty * eachCents;

  PricedLine get priced =>
      PricedLine(lineTotalCents: lineTotalCents, taxable: taxable);

  OrderLine copyWith({int? qty, String? notes}) => OrderLine(
    lineId: lineId,
    itemId: itemId,
    name: name,
    qty: qty ?? this.qty,
    unitPriceCents: unitPriceCents,
    modifiers: modifiers,
    taxable: taxable,
    kitchenStation: kitchenStation,
    notes: notes ?? this.notes,
  );

  /// Same item with the same options and notes, so the cart can add to the
  /// quantity instead of adding a line.
  bool sameAs(OrderLine other) =>
      itemId == other.itemId &&
      unitPriceCents == other.unitPriceCents &&
      notes == other.notes &&
      modifiers.map((m) => '${m.groupId}/${m.optionId}').join(',') ==
          other.modifiers.map((m) => '${m.groupId}/${m.optionId}').join(',');

  /// Builds a line from the store's menu and the guest's picks, checking
  /// each modifier group's min and max. Throws [MenuValidationError].
  factory OrderLine.fromMenu({
    required String lineId,
    required LocationMenuItem entry,
    required Map<String, List<String>> selections,
    int qty = 1,
    String? notes,
  }) {
    if (!entry.available) {
      throw MenuValidationError('${entry.item.name} is sold out.');
    }
    if (qty < 1 || qty > maxLineQty) {
      throw const MenuValidationError('Quantity is 1 to $maxLineQty.');
    }
    final modifiers = <LineModifier>[];
    for (final group in entry.modifierGroups) {
      final picks = selections[group.id] ?? const [];
      group.priceForSelection(picks);
      for (final id in picks) {
        final option = group.options.firstWhere((o) => o.id == id);
        modifiers.add(
          LineModifier(
            groupId: group.id,
            optionId: option.id,
            name: option.name,
            priceDeltaCents: option.priceDeltaCents,
          ),
        );
      }
    }
    final trimmed = notes?.trim();
    return OrderLine(
      lineId: lineId,
      itemId: entry.item.id,
      name: entry.item.name,
      qty: qty,
      unitPriceCents: entry.priceCents,
      modifiers: modifiers,
      taxable: entry.item.taxable,
      kitchenStation: entry.item.kitchenStation,
      notes: trimmed == null || trimmed.isEmpty ? null : trimmed,
    );
  }

  factory OrderLine.fromMap(Map<String, Object?> data) => OrderLine(
    lineId: data['lineId'] as String? ?? '',
    itemId: data['itemId'] as String? ?? '',
    name: data['name'] as String? ?? '',
    qty: (data['qty'] as num?)?.toInt() ?? 1,
    unitPriceCents: (data['unitPriceCents'] as num?)?.toInt() ?? 0,
    modifiers: [
      for (final m in (data['modifiers'] as List?) ?? const [])
        LineModifier.fromMap(Map<String, Object?>.from(m as Map)),
    ],
    taxable: data['taxable'] as bool? ?? true,
    kitchenStation: data['kitchenStation'] as String?,
    notes: data['notes'] as String?,
  );

  Map<String, Object?> toMap() => {
    'lineId': lineId,
    'itemId': itemId,
    'name': name,
    'qty': qty,
    'unitPriceCents': unitPriceCents,
    'modifiers': [for (final m in modifiers) m.toMap()],
    'lineTotalCents': lineTotalCents,
    'taxable': taxable,
    'kitchenStation': kitchenStation,
    'notes': notes,
  };
}

const maxLineQty = 99;
const maxOrderLines = 100;

/// The guest's name and how to reach them, for online and delivery orders.
/// Personal information: kept only on the order and shown to staff at
/// that store.
class OrderCustomer {
  const OrderCustomer({required this.name, this.phone, this.email});
  final String name;
  final String? phone;
  final String? email;

  factory OrderCustomer.fromMap(Map<String, Object?> data) => OrderCustomer(
    name: data['name'] as String? ?? '',
    phone: data['phone'] as String?,
    email: data['email'] as String?,
  );

  Map<String, Object?> toMap() => {
    'name': name,
    'phone': phone,
    'email': email,
  };
}

/// `orgs/{orgId}/locations/{locationId}/orders/{orderId}`. See docs/orders.md.
class Order {
  const Order({
    required this.id,
    required this.orgId,
    required this.locationId,
    required this.source,
    required this.ticket,
    required this.status,
    required this.paymentStatus,
    required this.fulfillment,
    required this.items,
    required this.totals,
    this.discounts = const [],
    this.customer,
    this.pickupAt,
    this.createdAt,
    this.createdBy,
    this.deviceId,
    this.staffUid,
    this.channel,
    this.notes,
  });

  final String id;
  final String orgId;
  final String locationId;
  final OrderSource source;

  /// What staff call out: a short number, unique enough for one store's day.
  final String ticket;
  final OrderStatus status;
  final PaymentStatus paymentStatus;
  final Fulfillment fulfillment;
  final List<OrderLine> items;
  final OrderTotals totals;
  final List<Discount> discounts;
  final OrderCustomer? customer;
  final DateTime? pickupAt;
  final DateTime? createdAt;
  final String? createdBy;
  final String? deviceId;
  final String? staffUid;

  /// For delivery orders: `uber_eats`, `doordash`, `skip` and so on.
  final String? channel;
  final String? notes;

  int get itemCount => items.fold(0, (sum, l) => sum + l.qty);

  factory Order.fromMap(
    String id,
    Map<String, Object?> data, {
    DateTime? Function(Object?)? readTime,
  }) {
    final time = readTime ?? (v) => v is DateTime ? v : null;
    final customer = data['customer'];
    return Order(
      id: id,
      orgId: data['orgId'] as String? ?? '',
      locationId: data['locationId'] as String? ?? '',
      source: OrderSource.fromWire(data['source'] as String?),
      ticket: data['ticket'] as String? ?? '',
      status: OrderStatus.fromWire(data['status'] as String?),
      paymentStatus: PaymentStatus.fromWire(data['paymentStatus'] as String?),
      fulfillment: Fulfillment.fromWire(data['fulfillment'] as String?),
      items: [
        for (final l in (data['items'] as List?) ?? const [])
          OrderLine.fromMap(Map<String, Object?>.from(l as Map)),
      ],
      totals: OrderTotals.fromMap(
        Map<String, Object?>.from((data['totals'] as Map?) ?? const {}),
      ),
      discounts: [
        for (final d in (data['discounts'] as List?) ?? const [])
          Discount.fromMap(Map<String, Object?>.from(d as Map)),
      ],
      customer: customer is Map
          ? OrderCustomer.fromMap(Map<String, Object?>.from(customer))
          : null,
      pickupAt: time(data['pickupAt']),
      createdAt: time(data['createdAt']),
      createdBy: data['createdBy'] as String?,
      deviceId: data['deviceId'] as String?,
      staffUid: data['staffUid'] as String?,
      channel: data['channel'] as String?,
      notes: data['notes'] as String?,
    );
  }
}

/// A POS ticket number from an order's random ID: three digits, so it is
/// easy to call out. Two orders sharing a number on one day is possible but
/// rare, and the kitchen display shows the time and items alongside it.
String ticketFor(String orderId) {
  var hash = 0;
  for (final unit in orderId.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return (100 + hash % 900).toString();
}
