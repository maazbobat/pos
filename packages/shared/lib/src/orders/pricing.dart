import '../menu/money.dart';

/// Order pricing in whole cents. `functions/src/orders/pricing.ts` is the
/// same arithmetic for orders the server prices (online and delivery); both
/// are checked against the same examples, so the POS and the server always
/// agree to the cent.
///
/// The steps:
/// 1. Each line is `qty × (unit price + chosen option prices)`.
/// 2. Discounts come off the subtotal before tax. A percent discount is
///    rounded half up; an amount discount can't go below zero.
/// 3. The discount is shared between taxable and non-taxable lines in
///    proportion to their subtotals, rounded half up.
/// 4. Each tax rate is applied to the taxable amount on its own and rounded
///    half up, so a receipt shows each tax exactly as charged.

/// A tax rate as stored in `settings/tax.rates`: `rate` is a fraction, for
/// example 0.13 for Ontario HST or 0.09975 for QST.
class TaxRate {
  const TaxRate({required this.id, required this.name, required this.rate});

  final String id;
  final String name;
  final double rate;

  /// The rate in units of 0.001% (0.13 → 13000), so the tax itself is
  /// computed with integers only.
  int get rateUnits => (rate * 100000).round();

  factory TaxRate.fromMap(Map<String, Object?> data) => TaxRate(
    id: data['id'] as String? ?? '',
    name: data['name'] as String? ?? '',
    rate: (data['rate'] as num?)?.toDouble() ?? 0,
  );

  Map<String, Object?> toMap() => {'id': id, 'name': name, 'rate': rate};
}

enum DiscountType {
  percent,
  amount;

  static DiscountType fromWire(String? value) =>
      value == 'amount' ? amount : percent;
}

/// An order-level discount. No manager PIN is needed: any seller can apply
/// one, and it is recorded with its reason.
class Discount {
  const Discount({required this.type, required this.value, this.reason});

  final DiscountType type;

  /// Whole percent (1-100) for [DiscountType.percent], cents for
  /// [DiscountType.amount].
  final int value;
  final String? reason;

  factory Discount.fromMap(Map<String, Object?> data) => Discount(
    type: DiscountType.fromWire(data['type'] as String?),
    value: (data['value'] as num?)?.toInt() ?? 0,
    reason: data['reason'] as String?,
  );

  Map<String, Object?> toMap() => {
    'type': type.name,
    'value': value,
    'reason': reason,
  };
}

class TaxLine {
  const TaxLine({
    required this.id,
    required this.name,
    required this.rate,
    required this.cents,
  });

  final String id;
  final String name;
  final double rate;
  final int cents;

  factory TaxLine.fromMap(Map<String, Object?> data) => TaxLine(
    id: data['id'] as String? ?? '',
    name: data['name'] as String? ?? '',
    rate: (data['rate'] as num?)?.toDouble() ?? 0,
    cents: (data['cents'] as num?)?.toInt() ?? 0,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'rate': rate,
    'cents': cents,
  };
}

class OrderTotals {
  const OrderTotals({
    required this.subtotalCents,
    required this.discountCents,
    required this.taxCents,
    required this.totalCents,
    this.taxes = const [],
  });

  static const zero = OrderTotals(
    subtotalCents: 0,
    discountCents: 0,
    taxCents: 0,
    totalCents: 0,
  );

  final int subtotalCents;
  final int discountCents;
  final int taxCents;
  final int totalCents;
  final List<TaxLine> taxes;

  factory OrderTotals.fromMap(Map<String, Object?> data) => OrderTotals(
    subtotalCents: (data['subtotalCents'] as num?)?.toInt() ?? 0,
    discountCents: (data['discountCents'] as num?)?.toInt() ?? 0,
    taxCents: (data['taxCents'] as num?)?.toInt() ?? 0,
    totalCents: (data['totalCents'] as num?)?.toInt() ?? 0,
    taxes: [
      for (final t in (data['taxes'] as List?) ?? const [])
        TaxLine.fromMap(Map<String, Object?>.from(t as Map)),
    ],
  );

  Map<String, Object?> toMap() => {
    'subtotalCents': subtotalCents,
    'discountCents': discountCents,
    'taxCents': taxCents,
    'totalCents': totalCents,
    'taxes': [for (final t in taxes) t.toMap()],
  };
}

/// What [priceOrder] needs from a line.
class PricedLine {
  const PricedLine({required this.lineTotalCents, required this.taxable});
  final int lineTotalCents;
  final bool taxable;
}

/// `a × b / c` rounded half up, for non-negative integers.
int mulDivRound(int a, int b, int c) => c == 0 ? 0 : (a * b * 2 + c) ~/ (c * 2);

/// The discount in cents for [subtotalCents], never more than the subtotal.
int discountCentsFor(List<Discount> discounts, int subtotalCents) {
  var remaining = subtotalCents;
  for (final d in discounts) {
    final off = switch (d.type) {
      DiscountType.percent => mulDivRound(remaining, d.value.clamp(0, 100), 100),
      DiscountType.amount => d.value.clamp(0, remaining),
    };
    remaining -= off;
  }
  return subtotalCents - remaining;
}

OrderTotals priceOrder({
  required List<PricedLine> lines,
  List<Discount> discounts = const [],
  List<TaxRate> taxRates = const [],
}) {
  var subtotal = 0;
  var taxableSubtotal = 0;
  for (final line in lines) {
    subtotal += line.lineTotalCents;
    if (line.taxable) taxableSubtotal += line.lineTotalCents;
  }
  final discount = discountCentsFor(discounts, subtotal);
  final taxableDiscount = mulDivRound(discount, taxableSubtotal, subtotal);
  final taxableBase = taxableSubtotal - taxableDiscount;
  final taxes = [
    for (final rate in taxRates)
      TaxLine(
        id: rate.id,
        name: rate.name,
        rate: rate.rate,
        cents: mulDivRound(taxableBase, rate.rateUnits, 100000),
      ),
  ];
  final tax = taxes.fold(0, (sum, t) => sum + t.cents);
  return OrderTotals(
    subtotalCents: subtotal,
    discountCents: discount,
    taxCents: tax,
    totalCents: subtotal - discount + tax,
    taxes: taxes,
  );
}

/// Change to hand back for [tenderedCents] of cash, or null if not enough.
int? changeDue(int totalCents, int tenderedCents) =>
    tenderedCents >= totalCents ? tenderedCents - totalCents : null;

/// Quick cash buttons for a total: exact, then the next round amounts a
/// guest is likely to hand over.
List<int> quickCashAmounts(int totalCents) {
  final amounts = <int>{totalCents};
  for (final step in const [500, 1000, 2000, 5000, 10000]) {
    final next = ((totalCents + step - 1) ~/ step) * step;
    if (next > totalCents && next <= maxPriceCents) amounts.add(next);
    if (amounts.length >= 4) break;
  }
  return amounts.toList()..sort();
}
