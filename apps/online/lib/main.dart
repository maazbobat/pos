import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:pos_firebase_backend/pos_firebase_backend.dart';

import 'src/analytics.dart';
import 'src/app.dart';

Future<void> main() async {
  // Clean addresses (/maple-cambridge, not /#/maple-cambridge), so each page
  // has its own URL for search engines and link previews. Hosting sends
  // unknown paths to the `site` Function, which serves index.html.
  usePathUrlStrategy();
  WidgetsFlutterBinding.ensureInitialized();
  final backend = await initStorefrontBackend();
  runApp(OnlineApp(backend: backend, analyticsSink: configuredAnalyticsSink()));
}
