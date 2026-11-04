/** Mirrors firestore.rules and packages/shared/lib/src/role.dart. */
export const LOCATION_ROLES = [
  "franchise_owner",
  "store_manager",
  "cashier",
  "kitchen",
  "inventory_manager",
  "accountant",
  "device",
] as const;

export type LocationRole = (typeof LOCATION_ROLES)[number];
/** Roles a person (not a device) can be invited to at a location. */
export type StaffRole = Exclude<LocationRole, "device">;
export type Role = "owner" | LocationRole;

export const STAFF_ROLES: readonly StaffRole[] = LOCATION_ROLES.filter(
  (r): r is StaffRole => r !== "device",
);

export const MANAGERS: readonly Role[] = ["owner", "franchise_owner", "store_manager"];

/**
 * Which location roles each role may hand out (invite, change to, or remove)
 * at a location where it acts. Only owners create owners.
 *
 *   owner            any staff role, and other owners
 *   franchise_owner  up to store manager, plus accountants
 *   store_manager    cashier, kitchen, inventory manager
 */
const ASSIGNABLE: Partial<Record<Role, readonly StaffRole[]>> = {
  owner: STAFF_ROLES,
  franchise_owner: ["store_manager", "cashier", "kitchen", "inventory_manager", "accountant"],
  store_manager: ["cashier", "kitchen", "inventory_manager"],
};

export function canAssign(actor: Role | null, role: StaffRole): boolean {
  if (actor === null) return false;
  return (ASSIGNABLE[actor] ?? []).includes(role);
}

export function isManager(role: Role | null): boolean {
  return role !== null && MANAGERS.includes(role);
}
