import 'dart:js_interop';

import 'package:web/web.dart' as web;

void _setMeta(String attr, String key, String content) {
  var el = web.document.head?.querySelector('meta[$attr="$key"]');
  if (el == null) {
    el = web.document.createElement('meta')..setAttribute(attr, key);
    web.document.head?.append(el);
  }
  el.setAttribute('content', content);
}

void setPageMeta({
  required String title,
  required String description,
  required bool noindex,
  String? canonicalPath,
}) {
  web.document.title = title;
  _setMeta('name', 'description', description);
  _setMeta('name', 'robots', noindex ? 'noindex' : 'index, follow');
  _setMeta('property', 'og:title', title);
  _setMeta('property', 'og:description', description);
  if (canonicalPath != null) {
    final href = '${web.window.location.origin}$canonicalPath';
    var link = web.document.head?.querySelector('link[rel="canonical"]');
    if (link == null) {
      link = web.document.createElement('link')
        ..setAttribute('rel', 'canonical');
      web.document.head?.append(link);
    }
    link.setAttribute('href', href);
    _setMeta('property', 'og:url', href);
  }
}

String? readStored(String key) {
  try {
    return web.window.localStorage.getItem(key);
  } catch (_) {
    return null; // Private mode or storage blocked: ask again next visit.
  }
}

void writeStored(String key, String value) {
  try {
    web.window.localStorage.setItem(key, value);
  } catch (_) {}
}

/// web/analytics.js: loads the Google tag only when asked, after consent.
@JS('siteAnalytics.load')
external void _load(String measurementId);
@JS('siteAnalytics.consent')
external void _consent(bool granted);
@JS('siteAnalytics.event')
external void _event(String name, JSAny? params);

@JS('siteAnalytics')
external JSObject? get _siteAnalytics;

bool get _available => _siteAnalytics != null;

void loadGoogleTag(String measurementId) {
  if (_available) _load(measurementId);
}

void setGoogleTagConsent({required bool granted}) {
  if (_available) _consent(granted);
}

void googleTagEvent(String name, Map<String, Object?> params) {
  if (_available) _event(name, params.jsify());
}

void hideLoadingSplash() {
  web.document.getElementById('loading')?.remove();
}
