import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:pos_shared/pos_shared.dart';

ClientPlatform get currentClientPlatform {
  if (kIsWeb) return ClientPlatform.web;
  return defaultTargetPlatform == TargetPlatform.android
      ? ClientPlatform.android
      : ClientPlatform.other;
}

/// Firebase options for [env] on this platform. Throws with every missing
/// setting listed, so a misconfigured build fails at start-up instead of
/// quietly talking to the wrong place.
FirebaseOptions firebaseOptionsFor(AppEnvironment env) {
  if (env.usesEmulators) {
    return FirebaseOptions(
      apiKey: 'demo-api-key',
      appId: '1:0:web:0',
      messagingSenderId: '0',
      projectId: env.projectId,
    );
  }
  final platform = currentClientPlatform;
  final problems = env.problems(platform);
  if (problems.isNotEmpty) {
    throw StateError(
      'This build isn\'t configured for ${env.envName}:\n'
      '${problems.map((p) => '- $p').join('\n')}\n'
      'See docs/environments.md.',
    );
  }
  return FirebaseOptions(
    apiKey: env.apiKeyFor(platform),
    appId: env.appIdFor(platform),
    messagingSenderId: env.messagingSenderId,
    projectId: env.projectId,
    authDomain: env.authDomain.isEmpty ? null : env.authDomain,
    storageBucket: env.storageBucket.isEmpty ? null : env.storageBucket,
  );
}

/// Wraps an app in a DEV or STAGING corner ribbon. Prod and local builds
/// are left as they are.
Widget withEnvironmentBanner(
  Widget app, [
  AppEnvironment env = AppEnvironment.current,
]) {
  final label = env.bannerLabel;
  if (label == null) return app;
  return Directionality(
    textDirection: TextDirection.ltr,
    child: Banner(
      message: label,
      location: BannerLocation.topEnd,
      color: env.env == DeployEnv.staging
          ? const Color(0xFFB45309)
          : const Color(0xFF6D28D9),
      child: app,
    ),
  );
}
