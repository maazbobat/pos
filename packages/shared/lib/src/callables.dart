/// Names of the Cloud Functions the apps call, matching `functions/src/index.ts`.
///
/// Everything that changes who can do what goes through one of these, never
/// a direct Firestore write. Every call is re-checked server-side.
abstract final class Callables {
  /// Functions are deployed to Montreal so data stays in Canada.
  static const region = 'northamerica-northeast1';

  // Onboarding (platform admin, then owner)
  static const createOrganization = 'createOrganization';
  static const createLocation = 'createLocation';
  static const setLocationStatus = 'setLocationStatus';

  // Staff
  static const inviteStaff = 'inviteStaff';
  static const revokeInvite = 'revokeInvite';
  static const acceptInvite = 'acceptInvite';
  static const setMemberRole = 'setMemberRole';
  static const setOwner = 'setOwner';

  // Devices
  static const createPairingCode = 'createPairingCode';
  static const redeemPairingCode = 'redeemPairingCode';
  static const revokeDevice = 'revokeDevice';

  // Staff PIN on a paired device
  static const setStaffPin = 'setStaffPin';
  static const startStaffSession = 'startStaffSession';

  // Support access and tenant status (platform admin)
  static const grantSupportAccess = 'grantSupportAccess';
  static const revokeSupportAccess = 'revokeSupportAccess';
  static const setOrgStatus = 'setOrgStatus';

  // Billing
  static const startCheckout = 'startCheckout';
  static const openBillingPortal = 'openBillingPortal';
  static const setManualPlan = 'setManualPlan';
  static const extendTrial = 'extendTrial';

  // Card payments, refunds and voids
  static const startCardPayment = 'startCardPayment';
  static const refreshPayment = 'refreshPayment';
  static const cancelCardPayment = 'cancelCardPayment';
  static const refundPayment = 'refundPayment';
  static const voidOrder = 'voidOrder';

  // Online ordering. The last three are public: guests don't sign in.
  static const updateOnlineOrdering = 'updateOnlineOrdering';
  static const getStorefront = 'getStorefront';
  static const placeOnlineOrder = 'placeOnlineOrder';
  static const getOnlineOrderStatus = 'getOnlineOrderStatus';

  // Delivery marketplaces through an aggregator
  static const linkDeliveryStore = 'linkDeliveryStore';
  static const syncDeliveryMenu = 'syncDeliveryMenu';

  // Monitoring
  static const resolveIncident = 'resolveIncident';
}
