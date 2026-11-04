/// A role a member holds in an organization.
///
/// [owner] is org-wide. Every other role is held per location, see
/// `Membership.locationRoles`. Roles are not ranked: what each one may do is
/// defined by the permission matrix (`tests/rules/src/matrix.ts`) and enforced
/// by `firestore.rules` and Cloud Functions, never by the UI alone.
enum Role {
  owner('owner'),
  franchiseOwner('franchise_owner'),
  storeManager('store_manager'),
  cashier('cashier'),
  kitchen('kitchen'),
  inventoryManager('inventory_manager'),
  accountant('accountant'),

  /// A paired POS or kitchen display. Staff switch on the device with a PIN.
  device('device');

  const Role(this.wireName);

  /// The value stored in Firestore.
  final String wireName;

  static Role? fromWire(String? value) {
    for (final role in Role.values) {
      if (role.wireName == value) return role;
    }
    return null;
  }

  /// Roles that manage a location: settings, prices, staff and devices.
  static const Set<Role> management = {owner, franchiseOwner, storeManager};

  /// Roles that can ring up sales and take cash.
  static const Set<Role> selling = {
    owner,
    franchiseOwner,
    storeManager,
    cashier,
    device,
  };
}
