/**
 * A store's menu as the server sees it, for the ordering site and delivery
 * menus, and server-side pricing of what a guest asks for. Prices, names and
 * availability always come from Firestore here, never from the request.
 */
import { db } from "../lib/firebase.js";
import { fail } from "../lib/errors.js";
import { paths } from "../lib/tenant.js";

export interface MenuOption {
  id: string;
  name: string;
  priceDeltaCents: number;
}

export interface MenuGroup {
  id: string;
  name: string;
  minSelect: number;
  maxSelect: number;
  options: MenuOption[];
}

export interface StoreItem {
  id: string;
  name: string;
  description: string | null;
  priceCents: number;
  available: boolean;
  taxable: boolean;
  kitchenStation: string | null;
  imagePath: string | null;
  modifierGroups: MenuGroup[];
}

export interface StoreSection {
  id: string;
  name: string;
  items: StoreItem[];
}

const num = (v: unknown, fallback = 0) => (typeof v === "number" && Number.isInteger(v) ? v : fallback);
const strOr = (v: unknown, fallback: string | null = null) => (typeof v === "string" ? v : fallback);
const bySortThenName = (a: { sortOrder: number; name: string }, b: { sortOrder: number; name: string }) =>
  a.sortOrder - b.sortOrder || a.name.localeCompare(b.name);

/**
 * Active categories and items in order, with this store's prices and
 * sold-out flags, the same way the POS builds it (buildLocationMenu).
 */
export async function loadStoreMenu(orgId: string, locationId: string): Promise<StoreSection[]> {
  const org = paths.org(orgId);
  const [cats, items, groups, overrides] = await Promise.all([
    db().collection(`${org}/menuCategories`).get(),
    db().collection(`${org}/menuItems`).get(),
    db().collection(`${org}/modifierGroups`).get(),
    db().collection(`${paths.location(orgId, locationId)}/menuOverrides`).get(),
  ]);
  const groupsById = new Map<string, MenuGroup>(groups.docs.map((g) => [g.id, {
    id: g.id,
    name: strOr(g.get("name"), "")!,
    minSelect: num(g.get("minSelect")),
    maxSelect: num(g.get("maxSelect"), 1),
    options: ((g.get("options") ?? []) as unknown[]).flatMap((o) => {
      const opt = o as Partial<MenuOption>;
      return typeof opt?.id === "string" && typeof opt.name === "string"
        ? [{ id: opt.id, name: opt.name, priceDeltaCents: Math.max(0, num(opt.priceDeltaCents)) }]
        : [];
    }),
  }]));
  const overridesById = new Map(overrides.docs.map((o) => [o.id, o.data()]));

  const sections: StoreSection[] = [];
  const categories = cats.docs
    .filter((c) => c.get("active") === true)
    .map((c) => ({ id: c.id, name: strOr(c.get("name"), "")!, sortOrder: num(c.get("sortOrder")) }))
    .sort(bySortThenName);
  for (const cat of categories) {
    const inCat = items.docs
      .filter((i) => i.get("active") === true && i.get("categoryId") === cat.id)
      .map((i) => ({ doc: i, name: strOr(i.get("name"), "")!, sortOrder: num(i.get("sortOrder")) }))
      .sort(bySortThenName);
    if (inCat.length === 0) continue;
    sections.push({
      id: cat.id,
      name: cat.name,
      items: inCat.map(({ doc }) => {
        const override = overridesById.get(doc.id);
        const localPrice = override?.priceCents;
        return {
          id: doc.id,
          name: strOr(doc.get("name"), "")!,
          description: strOr(doc.get("description")),
          priceCents: typeof localPrice === "number" ? localPrice : num(doc.get("priceCents")),
          available: override?.available !== false,
          taxable: doc.get("taxable") !== false,
          kitchenStation: strOr(doc.get("kitchenStation")),
          imagePath: strOr(doc.get("imagePath")),
          modifierGroups: ((doc.get("modifierGroupIds") ?? []) as string[])
            .map((id) => groupsById.get(id))
            .filter((g): g is MenuGroup => g !== undefined),
        };
      }),
    });
  }
  return sections;
}

export interface RequestedLine {
  itemId: string;
  qty: number;
  /** groupId → chosen option IDs. */
  modifiers: Record<string, string[]>;
  notes: string | null;
}

export interface OrderLineDoc {
  lineId: string;
  itemId: string;
  name: string;
  qty: number;
  unitPriceCents: number;
  modifiers: { groupId: string; optionId: string; name: string; priceDeltaCents: number }[];
  lineTotalCents: number;
  taxable: boolean;
  kitchenStation: string | null;
  notes: string | null;
}

export const MAX_LINES = 50;
export const MAX_QTY = 99;

/** Parses the guest's cart from untrusted input. */
export function parseRequestedLines(value: unknown): RequestedLine[] {
  if (!Array.isArray(value) || value.length === 0) throw fail.invalid("The order has no items.");
  if (value.length > MAX_LINES) throw fail.invalid(`At most ${MAX_LINES} lines per order.`);
  return value.map((raw) => {
    const line = (raw ?? {}) as Record<string, unknown>;
    if (typeof line.itemId !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(line.itemId)) {
      throw fail.invalid("An item ID is missing.");
    }
    const qty = line.qty;
    if (typeof qty !== "number" || !Number.isInteger(qty) || qty < 1 || qty > MAX_QTY) {
      throw fail.invalid(`Quantities are 1 to ${MAX_QTY}.`);
    }
    const modifiers: Record<string, string[]> = {};
    const rawMods = line.modifiers ?? {};
    if (typeof rawMods !== "object" || Array.isArray(rawMods)) throw fail.invalid("Bad modifiers.");
    for (const [groupId, ids] of Object.entries(rawMods as Record<string, unknown>)) {
      if (!Array.isArray(ids) || ids.length > 50 || !ids.every((id) => typeof id === "string")) {
        throw fail.invalid("Bad modifiers.");
      }
      modifiers[groupId] = ids as string[];
    }
    const notes = typeof line.notes === "string" && line.notes.trim() ? line.notes.trim().slice(0, 140) : null;
    return { itemId: line.itemId, qty, modifiers, notes };
  });
}

/**
 * Turns the guest's picks into order lines priced from the store's menu.
 * Refuses sold-out or unknown items and picks outside a group's min and max,
 * with a message the guest can act on.
 */
export function priceRequestedLines(menu: StoreSection[], requested: RequestedLine[]): OrderLineDoc[] {
  const items = new Map(menu.flatMap((s) => s.items.map((i) => [i.id, i] as const)));
  return requested.map((req, index) => {
    const item = items.get(req.itemId);
    if (!item) throw fail.precondition("Something in your order is no longer on the menu.");
    if (!item.available) throw fail.precondition(`${item.name} is sold out.`);
    const known = new Set(item.modifierGroups.map((g) => g.id));
    for (const groupId of Object.keys(req.modifiers)) {
      if (!known.has(groupId)) throw fail.invalid(`${item.name} has no option group ${groupId}.`);
    }
    const modifiers: OrderLineDoc["modifiers"] = [];
    for (const group of item.modifierGroups) {
      const picks = req.modifiers[group.id] ?? [];
      if (picks.length < group.minSelect || picks.length > group.maxSelect) {
        throw fail.invalid(group.minSelect === group.maxSelect
          ? `Pick ${group.minSelect} for ${group.name}.`
          : `Pick ${group.minSelect} to ${group.maxSelect} for ${group.name}.`);
      }
      if (new Set(picks).size !== picks.length) throw fail.invalid(`An option for ${group.name} was picked twice.`);
      for (const id of picks) {
        const option = group.options.find((o) => o.id === id);
        if (!option) throw fail.invalid(`Unknown option for ${group.name}.`);
        modifiers.push({ groupId: group.id, optionId: option.id, name: option.name, priceDeltaCents: option.priceDeltaCents });
      }
    }
    const each = item.priceCents + modifiers.reduce((sum, m) => sum + m.priceDeltaCents, 0);
    return {
      lineId: `l${index + 1}`,
      itemId: item.id,
      name: item.name,
      qty: req.qty,
      unitPriceCents: item.priceCents,
      modifiers,
      lineTotalCents: each * req.qty,
      taxable: item.taxable,
      kitchenStation: item.kitchenStation,
      notes: req.notes,
    };
  });
}
