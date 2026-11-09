/// Which Firebase project a build talks to, and the public settings for it.
///
/// Values come from `--dart-define-from-file=config/<env>.json` at build
/// time (see docs/environments.md). With no defines the build uses the local
/// emulators under the `demo-pos` project ID, which can't reach anything
/// real, so `flutter run` and the tests keep working with no setup.
///
/// None of these values are secrets: Firebase web config is public by design
/// and is protected by the rules, App Check and API key restrictions.
library;

enum DeployEnv {
  emulator,
  dev,
  staging,
  prod;

  static DeployEnv? fromWire(String value) {
    for (final e in values) {
      if (e.name == value) return e;
    }
    return null;
  }
}

/// The platforms the apps are built for. iOS isn't set up yet.
enum ClientPlatform { web, android, other }

class AppEnvironment {
  const AppEnvironment({
    required this.envName,
    this.projectId = '',
    this.apiKey = '',
    this.authDomain = '',
    this.storageBucket = '',
    this.messagingSenderId = '',
    this.webAppId = '',
    this.androidAppId = '',
    this.androidApiKey = '',
    this.emulatorHost = 'localhost',
  });

  /// The local emulators. What the tests and `flutter run` use.
  static const emulator = AppEnvironment(
    envName: 'emulator',
    projectId: 'demo-pos',
  );

  /// This build's environment, from the dart-defines.
  static const current = AppEnvironment(
    envName: String.fromEnvironment('POS_ENV', defaultValue: 'emulator'),
    projectId: String.fromEnvironment(
      'FIREBASE_PROJECT_ID',
      defaultValue: 'demo-pos',
    ),
    apiKey: String.fromEnvironment('FIREBASE_API_KEY'),
    authDomain: String.fromEnvironment('FIREBASE_AUTH_DOMAIN'),
    storageBucket: String.fromEnvironment('FIREBASE_STORAGE_BUCKET'),
    messagingSenderId: String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID'),
    webAppId: String.fromEnvironment('FIREBASE_WEB_APP_ID'),
    androidAppId: String.fromEnvironment('FIREBASE_ANDROID_APP_ID'),
    androidApiKey: String.fromEnvironment('FIREBASE_ANDROID_API_KEY'),
    // An Android emulator reaches the host at 10.0.2.2; a tablet on the LAN
    // uses the IP of the machine running `firebase emulators:start`.
    emulatorHost: String.fromEnvironment(
      'EMULATOR_HOST',
      defaultValue: 'localhost',
    ),
  );

  /// The raw `POS_ENV` value. Use [env], which is null if it's unknown.
  final String envName;
  final String projectId;
  final String apiKey;
  final String authDomain;
  final String storageBucket;
  final String messagingSenderId;
  final String webAppId;
  final String androidAppId;

  /// Android's own API key if the project restricts keys per platform.
  /// Empty means use [apiKey].
  final String androidApiKey;
  final String emulatorHost;

  DeployEnv? get env => DeployEnv.fromWire(envName);

  bool get usesEmulators => env == DeployEnv.emulator;

  /// A corner ribbon so nobody mistakes a test build for the real thing.
  /// Null on prod and on the local emulators.
  String? get bannerLabel => switch (env) {
    DeployEnv.dev => 'DEV',
    DeployEnv.staging => 'STAGING',
    _ => null,
  };

  String appIdFor(ClientPlatform platform) => switch (platform) {
    ClientPlatform.web => webAppId,
    ClientPlatform.android => androidAppId,
    ClientPlatform.other => '',
  };

  String apiKeyFor(ClientPlatform platform) =>
      platform == ClientPlatform.android && androidApiKey.isNotEmpty
      ? androidApiKey
      : apiKey;

  /// What's wrong with this configuration for [platform], or an empty list.
  /// The apps refuse to start with problems rather than half-connect.
  List<String> problems(ClientPlatform platform) {
    final e = env;
    if (e == null) {
      return ['Unknown POS_ENV "$envName". Use dev, staging or prod.'];
    }
    if (e == DeployEnv.emulator) return const [];
    final out = <String>[];
    void need(String name, String value) {
      if (value.isEmpty || value.contains('REPLACE_ME')) {
        out.add('$name is not set for $envName (config/$envName.json).');
      }
    }

    need('FIREBASE_PROJECT_ID', projectId);
    if (projectId.startsWith('demo-')) {
      out.add('$envName can\'t use a demo- project ID.');
    }
    need('FIREBASE_API_KEY', apiKey);
    need('FIREBASE_MESSAGING_SENDER_ID', messagingSenderId);
    switch (platform) {
      case ClientPlatform.web:
        need('FIREBASE_WEB_APP_ID', webAppId);
        need('FIREBASE_AUTH_DOMAIN', authDomain);
      case ClientPlatform.android:
        need('FIREBASE_ANDROID_APP_ID', androidAppId);
      case ClientPlatform.other:
        out.add('Only web and Android builds are set up for $envName.');
    }
    return out;
  }
}
