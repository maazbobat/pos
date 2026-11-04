# Restaurant POS platform

Multi-tenant restaurant POS and operations platform: Flutter apps on Firebase
(Auth, Firestore, Cloud Functions, Storage, Messaging).

**Status:** milestone 1, the multi-tenant foundation. Tenant schema, Firestore
rules and emulator tests. No features yet.

## Layout

| Path | What |
| --- | --- |
| `apps/pos` | Flutter POS and kitchen display |
| `apps/manager` | Flutter manager dashboard |
| `apps/admin` | Platform admin portal (Flutter web) |
| `packages/shared` | Dart models, Firestore paths, `Role` enum |
| `functions/` | Cloud Functions (TypeScript, Node 22) |
| `firestore.rules` | Tenant isolation and role permissions |
| `tests/rules/` | Emulator tests for the rules, including the permission matrix as data |
| `docs/` | Schema and permission model |

## Running checks

Needs Flutter (stable), Node 22 and Java 21.

```sh
flutter pub get && flutter analyze      # Dart workspace
(cd packages/shared && dart test)       # shared models
npm ci
npm run test:rules                      # Firestore emulator + rules tests
```

The Firebase config points only at the `demo-pos` project ID, which the
emulator treats as offline. No real Firebase project is configured yet; dev,
staging and prod projects come later.
