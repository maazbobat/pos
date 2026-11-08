/// Sets the document title, description and robots tag for the current page.
void setPageMeta({
  required String title,
  required String description,
  required bool noindex,
  String? canonicalPath,
}) {}

String? readStored(String key) => null;
void writeStored(String key, String value) {}

/// Loads the Google tag (Firebase Analytics / GA4 on the web) for [measurementId].
void loadGoogleTag(String measurementId) {}

/// Turns analytics storage on or off in the Google tag's consent mode.
void setGoogleTagConsent({required bool granted}) {}
void googleTagEvent(String name, Map<String, Object?> params) {}

/// Removes the loading spinner index.html shows until Flutter draws.
void hideLoadingSplash() {}
