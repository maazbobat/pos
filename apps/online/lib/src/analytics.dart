import 'package:flutter/foundation.dart';

import 'platform/browser.dart' as browser;

/// Where the site's analytics go. Swap the implementation to change
/// provider; the site only ever talks to [ConsentGatedAnalytics].
abstract interface class AnalyticsSink {
  /// Called once, the first time the guest agrees. Load scripts here, never before.
  void start();
  void setConsent({required bool granted});
  void event(String name, Map<String, Object?> params);
}

/// The Google tag: Firebase Analytics or GA4 with a `G-...` measurement ID.
class GoogleTagSink implements AnalyticsSink {
  const GoogleTagSink(this.measurementId);
  final String measurementId;

  @override
  void start() => browser.loadGoogleTag(measurementId);

  @override
  void setConsent({required bool granted}) =>
      browser.setGoogleTagConsent(granted: granted);

  @override
  void event(String name, Map<String, Object?> params) =>
      browser.googleTagEvent(name, params);
}

/// The guest's choice about optional cookies, kept in their browser.
enum Consent { unknown, granted, denied }

/// Remembers the guest's choice. [read] and [write] default to the browser's
/// local storage; tests pass their own.
class ConsentController extends ChangeNotifier {
  ConsentController({
    String? Function(String key)? read,
    void Function(String key, String value)? write,
  }) : _write = write ?? browser.writeStored {
    _consent = switch ((read ?? browser.readStored)(storageKey)) {
      'granted' => Consent.granted,
      'denied' => Consent.denied,
      _ => Consent.unknown,
    };
  }

  /// Bump the version when what we ask consent for changes, to ask again.
  static const storageKey = 'site.cookieConsent.v1';

  final void Function(String key, String value) _write;
  late Consent _consent;
  var _reopened = false;

  Consent get consent => _consent;

  /// Whether to show the cookie banner: no choice yet, or the guest opened
  /// "Cookie settings".
  bool get asking => _consent == Consent.unknown || _reopened;

  void choose({required bool analytics}) {
    _consent = analytics ? Consent.granted : Consent.denied;
    _reopened = false;
    _write(storageKey, _consent.name);
    notifyListeners();
  }

  void reopen() {
    _reopened = true;
    notifyListeners();
  }
}

/// Sends events to [sink] only while the guest has agreed to analytics.
/// With no sink (no measurement ID built in) there's nothing to agree to,
/// so the site shows no cookie banner.
class ConsentGatedAnalytics {
  ConsentGatedAnalytics({required this.consent, this.sink}) {
    consent.addListener(_apply);
    _apply();
  }

  final ConsentController consent;
  final AnalyticsSink? sink;
  var _started = false;
  Map<String, Object?>? _lastPage;

  /// Whether the site uses optional cookies at all.
  bool get enabled => sink != null;

  bool get _granted => consent.consent == Consent.granted;

  void _apply() {
    final s = sink;
    if (s == null) return;
    if (_granted && !_started) {
      _started = true;
      s.start();
      s.setConsent(granted: true);
      // Count the page the guest was on when they said yes.
      if (_lastPage case final page?) s.event('page_view', page);
      return;
    }
    if (_started) s.setConsent(granted: _granted);
  }

  void event(String name, [Map<String, Object?> params = const {}]) {
    if (_granted) sink?.event(name, params);
  }

  /// A screen view. Paths only, never query strings: order links carry a secret.
  void pageView(String title, String path) {
    _lastPage = {'page_title': title, 'page_path': path};
    event('page_view', _lastPage!);
  }

  void dispose() => consent.removeListener(_apply);
}

/// The sink to use for this build: the Google tag when a measurement ID was
/// passed with `--dart-define=ANALYTICS_MEASUREMENT_ID=G-...`, else none.
AnalyticsSink? configuredAnalyticsSink() {
  const id = String.fromEnvironment('ANALYTICS_MEASUREMENT_ID');
  return id.startsWith('G-') ? const GoogleTagSink(id) : null;
}

@visibleForTesting
class RecordingSink implements AnalyticsSink {
  final events = <String>[];
  var started = 0;
  bool? granted;

  @override
  void start() => started++;
  @override
  void setConsent({required bool granted}) => this.granted = granted;
  @override
  void event(String name, Map<String, Object?> params) => events.add(name);
}
