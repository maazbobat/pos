import 'order.dart';
import 'pricing.dart';

/// An order being built, on the POS or the ordering site. Immutable: every
/// change returns a new cart, which keeps widget state simple.
class Cart {
  const Cart({
    this.lines = const [],
    this.discounts = const [],
    this.taxRates = const [],
    this.fulfillment = Fulfillment.here,
  });

  final List<OrderLine> lines;
  final List<Discount> discounts;
  final List<TaxRate> taxRates;
  final Fulfillment fulfillment;

  bool get isEmpty => lines.isEmpty;
  int get itemCount => lines.fold(0, (sum, l) => sum + l.qty);

  OrderTotals get totals => priceOrder(
    lines: [for (final l in lines) l.priced],
    discounts: discounts,
    taxRates: taxRates,
  );

  Cart _with({
    List<OrderLine>? lines,
    List<Discount>? discounts,
    List<TaxRate>? taxRates,
    Fulfillment? fulfillment,
  }) => Cart(
    lines: lines ?? this.lines,
    discounts: discounts ?? this.discounts,
    taxRates: taxRates ?? this.taxRates,
    fulfillment: fulfillment ?? this.fulfillment,
  );

  /// Adds [line], or adds to the quantity of an identical line.
  Cart add(OrderLine line) {
    final i = lines.indexWhere((l) => l.sameAs(line));
    if (i == -1) {
      if (lines.length >= maxOrderLines) return this;
      return _with(lines: [...lines, line]);
    }
    final qty = (lines[i].qty + line.qty).clamp(1, maxLineQty);
    return _with(lines: [...lines]..[i] = lines[i].copyWith(qty: qty));
  }

  /// Sets a line's quantity; zero removes it.
  Cart setQty(String lineId, int qty) {
    if (qty <= 0) {
      return _with(lines: lines.where((l) => l.lineId != lineId).toList());
    }
    return _with(
      lines: [
        for (final l in lines)
          l.lineId == lineId ? l.copyWith(qty: qty.clamp(1, maxLineQty)) : l,
      ],
    );
  }

  Cart withDiscount(Discount? discount) =>
      _with(discounts: discount == null ? const [] : [discount]);
  Cart withTaxRates(List<TaxRate> rates) => _with(taxRates: rates);
  Cart withFulfillment(Fulfillment f) => _with(fulfillment: f);
  Cart clear() => Cart(taxRates: taxRates, fulfillment: fulfillment);
}
