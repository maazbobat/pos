/**
 * Order pricing in whole cents, for orders the server prices (online and
 * delivery menus). The same arithmetic as packages/shared/lib/src/orders/
 * pricing.dart, checked against the same examples
 * (packages/shared/test/fixtures/pricing_cases.json), so the POS, the
 * ordering site and the server agree to the cent.
 */

export interface TaxRate {
  id: string;
  name: string;
  /** A fraction: 0.13 for Ontario HST, 0.09975 for QST. */
  rate: number;
}

export interface Discount {
  type: "percent" | "amount";
  /** Whole percent, or cents. */
  value: number;
  reason?: string | null;
}

export interface TaxLine {
  id: string;
  name: string;
  rate: number;
  cents: number;
}

export interface OrderTotals {
  subtotalCents: number;
  discountCents: number;
  taxCents: number;
  totalCents: number;
  taxes: TaxLine[];
}

export interface PricedLine {
  lineTotalCents: number;
  taxable: boolean;
}

/** a × b / c rounded half up, for non-negative integers. */
export function mulDivRound(a: number, b: number, c: number): number {
  if (c === 0) return 0;
  return Math.floor((a * b * 2 + c) / (c * 2));
}

/** A rate in units of 0.001%, so tax is computed with integers only. */
export const rateUnits = (rate: number) => Math.round(rate * 100000);

export function discountCentsFor(discounts: Discount[], subtotalCents: number): number {
  let remaining = subtotalCents;
  for (const d of discounts) {
    const off = d.type === "amount"
      ? Math.min(Math.max(d.value, 0), remaining)
      : mulDivRound(remaining, Math.min(Math.max(d.value, 0), 100), 100);
    remaining -= off;
  }
  return subtotalCents - remaining;
}

export function priceOrder(lines: PricedLine[], discounts: Discount[], taxRates: TaxRate[]): OrderTotals {
  let subtotal = 0;
  let taxableSubtotal = 0;
  for (const line of lines) {
    subtotal += line.lineTotalCents;
    if (line.taxable) taxableSubtotal += line.lineTotalCents;
  }
  const discount = discountCentsFor(discounts, subtotal);
  const taxableBase = taxableSubtotal - mulDivRound(discount, taxableSubtotal, subtotal);
  const taxes = taxRates.map((r) => ({
    id: r.id,
    name: r.name,
    rate: r.rate,
    cents: mulDivRound(taxableBase, rateUnits(r.rate), 100000),
  }));
  const tax = taxes.reduce((sum, t) => sum + t.cents, 0);
  return { subtotalCents: subtotal, discountCents: discount, taxCents: tax, totalCents: subtotal - discount + tax, taxes };
}

/** Reads `settings/tax.rates`, skipping anything malformed. */
export function taxRatesFrom(settings: Record<string, unknown> | undefined): TaxRate[] {
  const rates = Array.isArray(settings?.rates) ? settings.rates : [];
  return rates.flatMap((r: unknown) => {
    const rate = r as Partial<TaxRate>;
    return typeof rate?.id === "string" && typeof rate.name === "string" && typeof rate.rate === "number"
      && rate.rate >= 0 && rate.rate < 1
      ? [{ id: rate.id, name: rate.name, rate: rate.rate }]
      : [];
  });
}
