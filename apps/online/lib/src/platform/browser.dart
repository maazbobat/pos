/// The few browser features the ordering site uses directly: the page's
/// head tags, a small key-value store for the guest's cookie choice, and the
/// analytics tag. On the Dart VM (tests) these do nothing.
library;

export 'browser_stub.dart' if (dart.library.js_interop) 'browser_web.dart';
