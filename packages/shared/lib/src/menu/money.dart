/// Formats whole cents as Canadian dollars, for example `$5.50` or `-$1.25`.
///
/// Money is always stored and computed as integer cents. Never use doubles
/// for prices: 0.1 + 0.2 != 0.3.
String formatCad(int cents) {
  final sign = cents < 0 ? '-' : '';
  final abs = cents.abs();
  final dollars = abs ~/ 100;
  final rest = (abs % 100).toString().padLeft(2, '0');
  final grouped = dollars.toString().replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );
  return '$sign\$$grouped.$rest';
}

/// Parses what someone types into a price field ("5", "5.5", "$5.50",
/// "1,250.00") into cents. Returns null for anything else, including more
/// than two decimal places or a negative amount.
int? parseCad(String input) {
  final cleaned = input.trim().replaceAll(RegExp(r'[\s$,]'), '');
  final match = RegExp(r'^(\d+)(?:\.(\d{1,2}))?$').firstMatch(cleaned);
  if (match == null) return null;
  final dollars = int.parse(match.group(1)!);
  final fraction = (match.group(2) ?? '').padRight(2, '0');
  final cents = dollars * 100 + int.parse(fraction);
  return cents <= maxPriceCents ? cents : null;
}

/// The largest price the rules accept: $100,000.00.
const maxPriceCents = 10000000;
