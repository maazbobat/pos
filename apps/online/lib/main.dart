import 'package:flutter/material.dart';
import 'package:pos_firebase_backend/pos_firebase_backend.dart';

import 'src/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final backend = await initStorefrontBackend();
  runApp(OnlineApp(backend: backend));
}
