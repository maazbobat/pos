/// Billing, support access, audit and monitoring: what the manager app shows
/// owners about their subscription, and what the platform admin portal
/// reads. Mirrors docs/commercial.md and `functions/src/billing/access.ts`.
///
/// Every map passed to a `fromMap` has its Firestore Timestamps already
/// turned into [DateTime]s by the backend.
library;

enum Plan {
  trial,
  starter,
  professional,
  franchise;

  String get label => switch (this) {
    Plan.trial => 'Free trial',
    Plan.starter => 'Starter',
    Plan.professional => 'Professional',
    Plan.franchise => 'Franchise',
  };

  /// Plans an owner can buy through Stripe Checkout. Franchise is custom.
  static const selfServe = [Plan.starter, Plan.professional];

  static Plan parse(Object? v) =>
      Plan.values.where((p) => p.name == v).firstOrNull ?? Plan.trial;
}

enum BillingSource {
  trial,
  stripe,
  manual;

  static BillingSource parse(Object? v) =>
      BillingSource.values.where((s) => s.name == v).firstOrNull ??
      BillingSource.trial;
}

/// Stripe's subscription status, as the server stores it.
enum BillingStatus {
  trialing,
  active,
  pastDue('past_due'),
  unpaid,
  canceled,
  incomplete,
  incompleteExpired('incomplete_expired'),
  paused;

  const BillingStatus([this._wire]);
  final String? _wire;
  String get wireName => _wire ?? name;

  bool get inGoodStanding =>
      this == BillingStatus.active || this == BillingStatus.trialing;

  static BillingStatus parse(Object? v) =>
      BillingStatus.values.where((s) => s.wireName == v).firstOrNull ??
      BillingStatus.incomplete;
}

DateTime? _date(Object? v) => v is DateTime ? v : null;
String? _str(Object? v) => v is String ? v : null;
int _int(Object? v) => v is int ? v : 0;

/// `orgs/{orgId}/billing/subscription`, readable by the owner, franchise
/// owners and accountants. Written only by Functions.
class Subscription {
  const Subscription({
    required this.plan,
    required this.source,
    required this.status,
    required this.readOnly,
    this.trialEndsAt,
    this.graceEndsAt,
    this.currentPeriodEnd,
    this.cancelAtPeriodEnd = false,
    this.hasStripeCustomer = false,
  });

  final Plan plan;
  final BillingSource source;
  final BillingStatus status;
  final bool readOnly;
  final DateTime? trialEndsAt;

  /// Set while a lapsed subscription still has full access.
  final DateTime? graceEndsAt;
  final DateTime? currentPeriodEnd;
  final bool cancelAtPeriodEnd;
  final bool hasStripeCustomer;

  /// Lapsed but still in the grace period.
  bool get inGrace => !readOnly && graceEndsAt != null;

  /// Whether the owner can start Checkout (the server checks again).
  bool get canStartCheckout =>
      !(source == BillingSource.manual && status == BillingStatus.active) &&
      !(source == BillingSource.stripe &&
          (status.inGoodStanding || status == BillingStatus.pastDue));

  factory Subscription.fromMap(Map<String, Object?> d) => Subscription(
    plan: Plan.parse(d['plan']),
    source: BillingSource.parse(d['source']),
    status: BillingStatus.parse(d['status']),
    readOnly: d['accessLevel'] == 'read_only',
    trialEndsAt: _date(d['trialEndsAt']),
    graceEndsAt: _date(d['graceEndsAt']),
    currentPeriodEnd: _date(d['currentPeriodEnd']),
    cancelAtPeriodEnd: d['cancelAtPeriodEnd'] == true,
    hasStripeCustomer: d['stripeCustomerId'] is String,
  );
}

/// `platformOrgs/{orgId}`: what the admin portal knows about a tenant
/// without a support grant.
class TenantSummary {
  const TenantSummary({
    required this.orgId,
    required this.name,
    required this.suspended,
    required this.readOnly,
    required this.plan,
    required this.billingStatus,
    required this.billingSource,
    this.type,
    this.ownerEmail,
    this.locationCount = 0,
    this.trialEndsAt,
    this.graceEndsAt,
    this.createdAt,
  });

  final String orgId;
  final String name;
  final String? type;
  final bool suspended;
  final bool readOnly;
  final Plan plan;
  final BillingStatus billingStatus;
  final BillingSource billingSource;
  final String? ownerEmail;
  final int locationCount;
  final DateTime? trialEndsAt;
  final DateTime? graceEndsAt;
  final DateTime? createdAt;

  factory TenantSummary.fromMap(String id, Map<String, Object?> d) =>
      TenantSummary(
        orgId: id,
        name: _str(d['name']) ?? id,
        type: _str(d['type']),
        suspended: d['status'] == 'suspended',
        readOnly: d['accessLevel'] == 'read_only',
        plan: Plan.parse(d['plan']),
        billingStatus: BillingStatus.parse(d['billingStatus']),
        billingSource: BillingSource.parse(d['billingSource']),
        ownerEmail: _str(d['ownerEmail']),
        locationCount: _int(d['locationCount']),
        trialEndsAt: _date(d['trialEndsAt']),
        graceEndsAt: _date(d['graceEndsAt']),
        createdAt: _date(d['createdAt']),
      );
}

/// One entry of `orgs/{orgId}/auditLog` or `platformAuditLog`.
class AuditEntry {
  const AuditEntry({
    required this.id,
    required this.action,
    required this.actorUid,
    required this.actorKind,
    this.orgId,
    this.locationId,
    this.staffUid,
    this.reason,
    this.createdAt,
  });

  final String id;
  final String action;
  final String actorUid;

  /// user, device, platform_admin, billing or system.
  final String actorKind;
  final String? orgId;
  final String? locationId;
  final String? staffUid;
  final String? reason;
  final DateTime? createdAt;

  factory AuditEntry.fromMap(String id, Map<String, Object?> d) => AuditEntry(
    id: id,
    action: _str(d['action']) ?? '',
    actorUid: _str(d['actorUid']) ?? '',
    actorKind: _str(d['actorKind']) ?? 'user',
    orgId: _str(d['orgId']),
    locationId: _str(d['locationId']),
    staffUid: _str(d['staffUid']),
    reason: _str(d['reason']),
    createdAt: _date(d['createdAt']),
  );
}

/// `orgs/{orgId}/supportGrants/{adminUid}`: time-boxed read access for a
/// platform admin. Readable by the org's owner and the admin.
class SupportGrant {
  const SupportGrant({
    required this.adminUid,
    required this.reason,
    required this.expiresAt,
    this.adminEmail,
  });

  final String adminUid;
  final String? adminEmail;
  final String reason;
  final DateTime expiresAt;

  bool get isActive => expiresAt.isAfter(DateTime.now());

  factory SupportGrant.fromMap(String id, Map<String, Object?> d) =>
      SupportGrant(
        adminUid: id,
        adminEmail: _str(d['adminEmail']),
        reason: _str(d['reason']) ?? '',
        expiresAt:
            _date(d['expiresAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
      );
}

/// `platformHealth/summary`, from the 15-minute health sweep.
class HealthSummary {
  const HealthSummary({
    required this.staleDevices,
    required this.staleDevicesByOrg,
    required this.printerProblems,
    required this.stuckPayments,
    required this.openIncidents,
    this.checkedAt,
  });

  final int staleDevices;
  final Map<String, int> staleDevicesByOrg;
  final int printerProblems;
  final int stuckPayments;
  final int openIncidents;
  final DateTime? checkedAt;

  bool get allClear =>
      staleDevices == 0 &&
      printerProblems == 0 &&
      stuckPayments == 0 &&
      openIncidents == 0;

  factory HealthSummary.fromMap(Map<String, Object?> d) => HealthSummary(
    staleDevices: _int(d['staleDevices']),
    staleDevicesByOrg: {
      for (final e in ((d['staleDevicesByOrg'] as Map?) ?? const {}).entries)
        '${e.key}': _int(e.value),
    },
    printerProblems: _int(d['printerProblems']),
    stuckPayments: _int(d['stuckPayments']),
    openIncidents: _int(d['openIncidents']),
    checkedAt: _date(d['checkedAt']),
  );
}

/// `platformIncidents/{id}`: something a person should look at.
class Incident {
  const Incident({
    required this.id,
    required this.kind,
    required this.message,
    this.orgId,
    this.createdAt,
  });

  final String id;
  final String kind;
  final String message;
  final String? orgId;
  final DateTime? createdAt;

  factory Incident.fromMap(String id, Map<String, Object?> d) => Incident(
    id: id,
    kind: _str(d['kind']) ?? '',
    message: _str(d['message']) ?? '',
    orgId: _str(d['orgId']),
    createdAt: _date(d['createdAt']),
  );
}

/// What the manager app needs for billing and support access. Owners only;
/// the server refuses everyone else.
abstract interface class BillingBackend {
  Stream<Subscription?> subscription(String orgId);

  /// Returns the Stripe Checkout page to open.
  Future<Uri> startCheckout(String orgId, Plan plan);

  /// Returns Stripe's customer portal page to open.
  Future<Uri> openBillingPortal(String orgId);

  Stream<List<SupportGrant>> supportGrants(String orgId);
  Future<void> revokeSupportAccess(String orgId, String adminUid);

  /// The org's audit log, newest first.
  Stream<List<AuditEntry>> auditLog(String orgId, {int limit = 50});
}

/// What the platform admin portal reads and calls. Every call is checked
/// against `platformAdmins` server-side and audited.
abstract interface class PlatformBackend {
  Stream<bool> isPlatformAdmin(String uid);
  Stream<List<TenantSummary>> tenants();
  Stream<TenantSummary?> tenant(String orgId);

  /// Newest first; [orgId] narrows to one tenant.
  Stream<List<AuditEntry>> platformAudit({String? orgId, int limit = 50});
  Stream<HealthSummary?> health();
  Stream<List<Incident>> openIncidents();

  /// The admin's own grant on [orgId], if any.
  Stream<SupportGrant?> mySupportGrant(String orgId, String adminUid);

  Future<DateTime> grantSupportAccess(
    String orgId, {
    required String reason,
    required int hours,
  });
  Future<void> revokeMySupportAccess(String orgId);
  Future<void> setOrgSuspended(
    String orgId, {
    required bool suspended,
    required String reason,
  });
  Future<void> setManualPlan(
    String orgId, {
    required Plan plan,
    required bool active,
    required String reason,
  });
  Future<DateTime> extendTrial(
    String orgId, {
    required int days,
    required String reason,
  });
  Future<void> resolveIncident(String incidentId, {required String note});
}
