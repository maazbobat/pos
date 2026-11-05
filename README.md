# Restaurant POS platform

Multi-tenant restaurant POS and operations platform: Flutter apps on Firebase
(Auth, Firestore, Cloud Functions, Storage, Messaging).

**Status:** roadmap step 3, commercial operations. Done before it: tenant
schema and rules, onboarding Functions, menu setup, and the first app screens.
Step 3 adds Stripe Billing with a grace period then read-only, the
PaymentProvider abstraction with refunds and voids, audited platform support
access, and monitoring ([docs/commercial.md](docs/commercial.md)).

## Layout

| Path | What |
| --- | --- |
| `apps/pos` | Flutter POS and kitchen display |
| `apps/manager` | Flutter manager dashboard |
| `apps/admin` | Platform admin portal (Flutter web) |
| `packages/shared` | Dart models, Firestore paths, `Role` enum, backend interfaces, test fakes |
| `packages/firebase_backend` | Firebase implementation of those interfaces |
| `functions/` | Cloud Functions (TypeScript, Node 22) |
| `firestore.rules` | Tenant isolation and role permissions |
| `tests/rules/` | Emulator tests for the rules, including the permission matrix as data |
| `docs/` | Schema, permissions, onboarding, billing and payments, monitoring |

## Running checks

Needs Flutter (stable), Node 22 and Java 21.

```sh
flutter pub get && flutter analyze      # Dart workspace
(cd packages/shared && dart test)       # shared models
(cd apps/pos && flutter test)           # widget tests (also apps/manager, apps/admin)
npm ci
npm run test:rules                      # Firestore emulator + rules tests
npm run test:functions                  # Cloud Functions against the emulators
```

## Trying the apps locally

Everything runs against the emulators under the `demo-pos` project ID.

```sh
echo "PIN_PEPPER=local-dev-only" > functions/.secret.local   # git-ignored
npm run build:functions
npx firebase emulators:start --only auth,firestore,functions --project demo-pos
# in another terminal
FIRESTORE_EMULATOR_HOST=127.0.0.1:8080 FIREBASE_AUTH_EMULATOR_HOST=127.0.0.1:9099 npm run seed:dev
(cd apps/admin && flutter run -d chrome)     # sign in as admin@demo.test / demo-admin
(cd apps/manager && flutter run -d chrome)   # the owner accepts the invite link here
(cd apps/pos && flutter run)                 # add --dart-define=EMULATOR_HOST=10.0.2.2 on an Android emulator
```

Flow: create a restaurant in admin, accept the owner link in manager, add a
location and menu, set your PIN, pair the tablet with a code from Devices,
then unlock it with the PIN.

The Firebase config points only at the `demo-pos` project ID, which the
emulator treats as offline. No real Firebase project is configured yet; dev,
staging and prod projects come later.
