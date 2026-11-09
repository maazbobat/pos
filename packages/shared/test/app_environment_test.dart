import 'package:pos_shared/pos_shared.dart';
import 'package:test/test.dart';

const _staging = AppEnvironment(
  envName: 'staging',
  projectId: 'pos-staging-123',
  apiKey: 'AIza-web',
  authDomain: 'pos-staging-123.firebaseapp.com',
  messagingSenderId: '42',
  webAppId: '1:42:web:abc',
  androidAppId: '1:42:android:def',
);

void main() {
  test('no dart-defines means the local emulators', () {
    expect(AppEnvironment.current.env, DeployEnv.emulator);
    expect(AppEnvironment.current.projectId, 'demo-pos');
    expect(AppEnvironment.current.usesEmulators, isTrue);
    expect(AppEnvironment.current.bannerLabel, isNull);
    expect(AppEnvironment.emulator.problems(ClientPlatform.web), isEmpty);
  });

  test('a filled-in environment has no problems on web or Android', () {
    expect(_staging.usesEmulators, isFalse);
    expect(_staging.bannerLabel, 'STAGING');
    expect(_staging.problems(ClientPlatform.web), isEmpty);
    expect(_staging.problems(ClientPlatform.android), isEmpty);
    expect(_staging.appIdFor(ClientPlatform.android), '1:42:android:def');
    expect(_staging.apiKeyFor(ClientPlatform.android), 'AIza-web');
  });

  test('placeholders, demo projects and unknown names are refused', () {
    const env = AppEnvironment(
      envName: 'prod',
      projectId: 'demo-pos',
      apiKey: 'REPLACE_ME',
      messagingSenderId: '1',
      webAppId: '1:1:web:1',
    );
    final problems = env.problems(ClientPlatform.web);
    expect(problems, contains(contains('demo- project')));
    expect(problems, contains(contains('FIREBASE_API_KEY')));
    expect(problems, contains(contains('FIREBASE_AUTH_DOMAIN')));
    expect(
      env.problems(ClientPlatform.android),
      contains(contains('ANDROID_APP_ID')),
    );
    expect(env.bannerLabel, isNull);
    expect(
      const AppEnvironment(envName: 'production').problems(ClientPlatform.web),
      [contains('Unknown POS_ENV')],
    );
  });

  test('Android can use its own API key', () {
    const env = AppEnvironment(
      envName: 'dev',
      apiKey: 'web',
      androidApiKey: 'droid',
    );
    expect(env.apiKeyFor(ClientPlatform.android), 'droid');
    expect(env.apiKeyFor(ClientPlatform.web), 'web');
    expect(env.bannerLabel, 'DEV');
  });
}
