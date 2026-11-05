import '../orders/order.dart';
import '../orders/orders_backend.dart';
import '../printing/printers.dart';

/// A card reader at a counter, from `settings/payments.terminals.{id}`.
class CardReader {
  const CardReader({required this.id, required this.name, this.model});
  final String id;
  final String name;

  /// Stripe's device type, for example `stripe_s700` or `bbpos_wisepos_e`.
  final String? model;
}

/// `settings/payments`: which card processor a location uses and its readers.
class PaymentSettings {
  const PaymentSettings({this.cardProvider, this.readers = const []});

  /// `stripe_terminal`, `clover` or (emulator only) `fake_card`. Null when
  /// the location takes cash only.
  final String? cardProvider;
  final List<CardReader> readers;

  bool get cardsEnabled => cardProvider != null && readers.isNotEmpty;

  factory PaymentSettings.fromMap(Map<String, Object?> d) {
    final terminals = Map<String, Object?>.from((d['terminals'] as Map?) ?? {});
    return PaymentSettings(
      cardProvider: d['cardProvider'] as String?,
      readers: [
        for (final e in terminals.entries)
          CardReader(
            id: e.key,
            name: (e.value as Map)['name'] as String? ?? e.key,
            model: (e.value as Map)['model'] as String?,
          ),
      ]..sort((a, b) => a.name.compareTo(b.name)),
    );
  }
}

enum CardPaymentStatus {
  pending,
  succeeded,
  failed,
  canceled;

  static CardPaymentStatus fromWire(String? v) =>
      values.where((s) => s.name == v).firstOrNull ?? pending;

  bool get done => this != pending;
}

/// Where a card payment is, from startCardPayment or refreshPayment.
class CardPaymentState {
  const CardPaymentState({
    required this.paymentId,
    required this.status,
    this.failureReason,
  });
  final String paymentId;
  final CardPaymentStatus status;
  final String? failureReason;

  factory CardPaymentState.fromMap(Map<String, Object?> d) => CardPaymentState(
    paymentId: d['paymentId'] as String? ?? '',
    status: CardPaymentStatus.fromWire(d['status'] as String?),
    failureReason: d['failureReason'] as String?,
  );

  /// For the cashier, in plain words.
  String get message => switch (status) {
    CardPaymentStatus.succeeded => 'Approved',
    CardPaymentStatus.canceled => 'Cancelled',
    CardPaymentStatus.pending => 'Waiting for the card',
    CardPaymentStatus.failed => switch (failureReason) {
      'reader_offline' => 'The card reader is offline. Check its Wi-Fi or power.',
      'reader_busy' => 'The card reader is busy with another payment.',
      'insufficient_funds' => 'Declined: insufficient funds.',
      'card_declined' || 'generic_decline' || 'do_not_honor' => 'The card was declined.',
      'expired_card' => 'The card has expired.',
      'incorrect_pin' || 'invalid_pin' => 'Wrong PIN.',
      'not_configured' => 'Card payments aren\'t set up at this location yet.',
      'not_received' => 'The reader never got the payment.',
      final r? => 'The payment failed ($r).',
      null => 'The payment failed.',
    },
  };
}

/// A payment on an order, for the order screen, refunds and receipts.
class OrderPayment {
  const OrderPayment({
    required this.id,
    required this.method,
    required this.provider,
    required this.amountCents,
    required this.status,
    this.tipCents = 0,
    this.refundedCents = 0,
  });
  final String id;

  /// `cash` or `card`.
  final String method;
  final String provider;
  final int amountCents;
  final int tipCents;
  final int refundedCents;
  final CardPaymentStatus status;

  int get refundableCents => amountCents + tipCents - refundedCents;

  String get label => switch (provider) {
    'cash' => 'Cash',
    'stripe_online' => 'Paid online',
    _ => 'Card',
  };

  ReceiptPayment toReceipt({int? tenderedCents}) => ReceiptPayment(
    label: label,
    amountCents: amountCents,
    tipCents: tipCents,
    tenderedCents: tenderedCents,
  );

  factory OrderPayment.fromMap(String id, Map<String, Object?> d) => OrderPayment(
    id: id,
    method: d['method'] as String? ?? 'card',
    provider: d['provider'] as String? ?? 'cash',
    amountCents: (d['amountCents'] as num?)?.toInt() ?? 0,
    tipCents: (d['tipCents'] as num?)?.toInt() ?? 0,
    refundedCents: (d['refundedCents'] as num?)?.toInt() ?? 0,
    status: CardPaymentStatus.fromWire(d['status'] as String?),
  );
}

/// Card payments, refunds, voids and the counter's hardware settings. Card
/// calls go through the PaymentProvider Functions (docs/commercial.md).
abstract interface class CounterBackend {
  Stream<PaymentSettings> paymentSettings(String orgId, String locationId);
  Stream<HardwareSettings> hardware(String orgId, String locationId);

  /// Managers only (firestore.rules).
  Future<void> saveHardware(String orgId, String locationId, HardwareSettings settings);

  /// Writes the order unpaid and waits until the server has it, so a card
  /// payment can start on it. Card payments need a connection anyway.
  Future<void> placeUnpaidOrder(PosOrderDraft draft);

  /// Sends the charge to [readerId]. A retry with the same
  /// [idempotencyKey] returns the first attempt instead of charging again.
  Future<CardPaymentState> startCardPayment(
    Order order, {
    required int amountCents,
    required int tipCents,
    required String idempotencyKey,
    required String readerId,
  });

  Future<CardPaymentState> refreshPayment(Order order, String paymentId);
  Future<CardPaymentState> cancelCardPayment(Order order, String paymentId);

  Stream<List<OrderPayment>> payments(Order order);

  /// A manager signed in as themselves, or [managerPin] on a POS device.
  /// Returns `succeeded`, `pending` or `failed`.
  Future<String> refundPayment(
    Order order, {
    required String paymentId,
    required int amountCents,
    required String reason,
    required String idempotencyKey,
    String? managerPin,
  });

  Future<void> voidOrder(Order order, {required String reason, String? managerPin});

  /// Pairs a Stripe smart reader with a counter. Managers only. The street
  /// address is needed for the location's first reader.
  Future<CardReader> registerCardReader(
    String orgId,
    String locationId, {
    required String readerId,
    required String name,
    required String registrationCode,
    String? addressLine1,
    String? city,
    String? postalCode,
  });
}
