/// Builds Firestore document and collection paths.
///
/// Tenancy is defined by the path: every tenant document lives under
/// `orgs/{orgId}`, and store data under `orgs/{orgId}/locations/{locationId}`.
/// Use these helpers rather than hand-built strings so a typo can't send a
/// query to the wrong tenant.
abstract final class FirestorePaths {
  static String user(String uid) => 'users/$uid';

  static String org(String orgId) => 'orgs/$orgId';
  static String subscription(String orgId) =>
      '${org(orgId)}/billing/subscription';
  static String members(String orgId) => '${org(orgId)}/members';
  static String member(String orgId, String uid) => '${members(orgId)}/$uid';
  static String orgConfig(String orgId, String id) =>
      '${org(orgId)}/config/$id';
  static String menuCategories(String orgId) => '${org(orgId)}/menuCategories';
  static String menuItems(String orgId) => '${org(orgId)}/menuItems';
  static String modifierGroups(String orgId) => '${org(orgId)}/modifierGroups';
  static String combos(String orgId) => '${org(orgId)}/combos';
  static String promotions(String orgId) => '${org(orgId)}/promotions';
  static String auditLog(String orgId) => '${org(orgId)}/auditLog';

  /// Pending staff invites. Managers must query with `locationId ==`.
  static String invites(String orgId) => '${org(orgId)}/invites';
  static String orgReports(String orgId) => '${org(orgId)}/reports';

  static String locations(String orgId) => '${org(orgId)}/locations';
  static String location(String orgId, String locationId) =>
      '${locations(orgId)}/$locationId';

  static String _loc(String orgId, String locationId, String rest) =>
      '${location(orgId, locationId)}/$rest';

  static String settings(String orgId, String locationId, String id) =>
      _loc(orgId, locationId, 'settings/$id');
  static String menuOverrides(String orgId, String locationId) =>
      _loc(orgId, locationId, 'menuOverrides');
  static String staff(String orgId, String locationId) =>
      _loc(orgId, locationId, 'staff');
  static String devices(String orgId, String locationId) =>
      _loc(orgId, locationId, 'devices');
  static String orders(String orgId, String locationId) =>
      _loc(orgId, locationId, 'orders');
  static String payments(String orgId, String locationId, String orderId) =>
      _loc(orgId, locationId, 'orders/$orderId/payments');
  static String cashSessions(String orgId, String locationId) =>
      _loc(orgId, locationId, 'cashSessions');
  static String cashMovements(
    String orgId,
    String locationId,
    String sessionId,
  ) => _loc(orgId, locationId, 'cashSessions/$sessionId/movements');
  static String inventoryItems(String orgId, String locationId) =>
      _loc(orgId, locationId, 'inventoryItems');
  static String stockMovements(String orgId, String locationId) =>
      _loc(orgId, locationId, 'stockMovements');
  static String purchaseOrders(String orgId, String locationId) =>
      _loc(orgId, locationId, 'purchaseOrders');
  static String locationReports(String orgId, String locationId) =>
      _loc(orgId, locationId, 'reports');
}
