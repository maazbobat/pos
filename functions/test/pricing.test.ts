import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { priceOrder, taxRatesFrom, type Discount, type TaxRate } from "../src/orders/pricing.js";

// Run from functions/. The same cases the Dart tests use, so the POS and the server agree to the cent.
const cases = JSON.parse(
  readFileSync(resolve(process.cwd(), "../packages/shared/test/fixtures/pricing_cases.json"), "utf8"),
).cases as {
  name: string;
  lines: [number, boolean][];
  discounts: Discount[];
  rates: TaxRate[];
  expect: { subtotalCents: number; discountCents: number; taxCents: number; totalCents: number; taxCents_each: number[] };
}[];

describe("order pricing matches the POS", () => {
  it.each(cases)("$name", (c) => {
    const totals = priceOrder(c.lines.map(([cents, taxable]) => ({ lineTotalCents: cents, taxable })), c.discounts, c.rates);
    expect(totals.subtotalCents).toBe(c.expect.subtotalCents);
    expect(totals.discountCents).toBe(c.expect.discountCents);
    expect(totals.taxCents).toBe(c.expect.taxCents);
    expect(totals.totalCents).toBe(c.expect.totalCents);
    expect(totals.taxes.map((t) => t.cents)).toEqual(c.expect.taxCents_each);
  });

  it("reads tax settings and skips malformed rates", () => {
    expect(taxRatesFrom({ rates: [{ id: "hst", name: "HST", rate: 0.13 }, { id: "x", rate: "13%" }, null] }))
      .toEqual([{ id: "hst", name: "HST", rate: 0.13 }]);
    expect(taxRatesFrom(undefined)).toEqual([]);
  });
});
