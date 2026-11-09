# Environments and deploys

Three Firebase projects, one per environment, plus the local emulators.

| Environment | What it's for | Deployed by | Stripe |
| --- | --- | --- | --- |
| local | `flutter run` and the tests, under the offline `demo-pos` project ID | nobody | fake providers |
| dev | trying a branch on real Firebase | a manual run of **Deploy** from any branch | test mode |
| staging | what's on `main`, for a last look before customers get it | every push to `main`, after CI passes | test mode |
| prod | real restaurants | a version tag (`v1.2.0`) on `main`, or a manual run from `main`, after a reviewer approves it in GitHub | live mode |

Each deploy ships everything together: Firestore rules and indexes, Storage
rules, Functions, and the three Hosting sites (ordering site, manager app,
admin portal). The POS and kitchen display are built as an Android APK and
attached to the workflow run, for installing on the counter tablets.

Until an environment's settings are filled in, nothing deploys there. A push
to `main` just leaves a notice saying staging isn't set up yet, so CI stays
green.

## Where the settings live

`config/<env>.json` holds everything that differs between environments. None
of it is secret: Firebase web config is public by design, and the data is
protected by the rules.

| Key | What |
| --- | --- |
| `POS_ENV` | `dev`, `staging` or `prod`. Dev and staging builds show a corner ribbon |
| `FIREBASE_PROJECT_ID`, `FIREBASE_API_KEY`, `FIREBASE_AUTH_DOMAIN`, `FIREBASE_STORAGE_BUCKET`, `FIREBASE_MESSAGING_SENDER_ID` | The project's config, from the Firebase console |
| `FIREBASE_WEB_APP_ID` | The web app's ID (ordering site, manager, admin) |
| `FIREBASE_ANDROID_APP_ID` | The Android app's ID (POS tablet) |
| `FIREBASE_ANDROID_API_KEY` | Optional. Only if you give Android its own restricted key |
| `HOSTING_SITE_ONLINE`, `HOSTING_SITE_MANAGER`, `HOSTING_SITE_ADMIN` | The Hosting site for each web app |
| `ORDERING_SITE_URL`, `MANAGER_APP_URL` | Public addresses, no trailing slash. Stripe sends people back here, and the manager app links to the ordering site |
| `ANALYTICS_MEASUREMENT_ID` | Optional `G-…` ID. Empty means no analytics and no cookie banner |

The apps read the file at build time with
`--dart-define-from-file=config/<env>.json`. The Functions get
`ORDERING_SITE_URL` and `MANAGER_APP_URL` from `functions/.env.<project-id>`,
which `node scripts/env.mjs prepare <env>` writes from the same file. The
project aliases and Hosting targets in `.firebaserc` are generated from these
files too (`node scripts/env.mjs sync`), and CI fails if they drift.

Secrets (`PIN_PEPPER` and the Stripe keys) never go in these files. They live
in each project's Secret Manager.

## One-time setup for each environment

Do these for dev, staging and prod, in that order, so prod is the last one
you touch. Where a command says `<id>`, use that environment's project ID.

### 1. Create the Firebase project

1. In the [Firebase console](https://console.firebase.google.com/), add a
   project. Suggested IDs: `<name>-pos-dev`, `<name>-pos-staging`,
   `<name>-pos` (IDs are global, so pick a prefix that's yours). Turn Google
   Analytics off unless you've decided to use it.
2. Upgrade it to the **Blaze** plan. Functions need it. Set a budget alert in
   Google Cloud Billing while you're there.
3. **Firestore:** create the database in `northamerica-northeast1` (Montreal),
   production mode. The location can't be changed later. For prod, turn on
   point-in-time recovery and a daily backup schedule.
4. **Storage:** create the default bucket in `northamerica-northeast1`.
5. **Authentication:** enable the Email/Password provider.

### 2. Register the apps and fill in the config

1. In Project settings → Your apps, add a **Web** app (one is enough for the
   three sites) and an **Android** app with package name
   `dev.pos.pos_terminal`.
2. Fill in what follows from the project ID:

   ```sh
   node scripts/env.mjs init staging <id>
   ```

   That sets the auth domain, bucket, Hosting site names and the default
   `*.web.app` addresses, updates `.firebaserc`, and lists what's left.
3. Paste the rest from the console, or from
   `npx firebase apps:sdkconfig web --project <id>` (apiKey,
   messagingSenderId, appId) and the Android app's `google-services.json`
   (`mobilesdk_app_id`) into `config/<env>.json`.
4. `node scripts/env.mjs check --ready <env>` should say the environment is
   ready. Commit the file in a pull request.

### 3. Create the extra Hosting sites

The ordering site uses the project's default site. The manager app and admin
portal each need their own:

```sh
npx firebase hosting:sites:create <id>-manager --project <id>
npx firebase hosting:sites:create <id>-admin --project <id>
```

A custom domain (for example `order.yourbrand.ca`) is added later in Hosting.
When you add one, update `ORDERING_SITE_URL` or `MANAGER_APP_URL` to match.

### 4. Set the secrets

```sh
openssl rand -base64 32 | npx firebase functions:secrets:set PIN_PEPPER --project <id> --data-file -
npx firebase functions:secrets:set STRIPE_SECRET_KEY --project <id>
npx firebase functions:secrets:set STRIPE_WEBHOOK_SECRET --project <id>
npx firebase functions:secrets:set STRIPE_CONNECT_WEBHOOK_SECRET --project <id>
```

- Use a different `PIN_PEPPER` in each environment, and never change prod's
  once staff have set PINs: every PIN stops working if it changes.
- Dev and staging get Stripe **test-mode** keys; only prod gets live keys.
- The webhook secrets come from step 7. Until then, set a placeholder so the
  first deploy goes through, and replace it after.

### 5. Let GitHub deploy without a key file

GitHub Actions signs in to Google Cloud with Workload Identity Federation, so
there's no long-lived key to leak. Run this once per project in
[Cloud Shell](https://shell.cloud.google.com/), with `PROJECT` and `ENV`
set (`ENV` is `dev`, `staging` or `prod`):

```sh
PROJECT=<id>; ENV=staging; REPO=maazbobat/pos
NUMBER=$(gcloud projects describe $PROJECT --format='value(projectNumber)')
gcloud services enable iamcredentials.googleapis.com sts.googleapis.com --project $PROJECT

# The account deploys run as.
gcloud iam service-accounts create github-deploy --project $PROJECT --display-name "GitHub deploys"
SA=github-deploy@$PROJECT.iam.gserviceaccount.com
for role in roles/firebase.admin roles/cloudfunctions.admin roles/run.admin \
  roles/iam.serviceAccountUser roles/secretmanager.admin roles/cloudscheduler.admin \
  roles/artifactregistry.admin roles/serviceusage.serviceUsageConsumer; do
  gcloud projects add-iam-policy-binding $PROJECT --member "serviceAccount:$SA" --role $role --condition None
done

# Trust GitHub's sign-in for this repository only.
gcloud iam workload-identity-pools create github --project $PROJECT --location global
gcloud iam workload-identity-pools providers create-oidc github --project $PROJECT \
  --location global --workload-identity-pool github \
  --issuer-uri https://token.actions.githubusercontent.com \
  --attribute-mapping google.subject=assertion.sub,attribute.repository=assertion.repository \
  --attribute-condition "assertion.repository == '$REPO'"

# Only jobs running in this GitHub environment may use the account.
gcloud iam service-accounts add-iam-policy-binding $SA --project $PROJECT \
  --role roles/iam.workloadIdentityUser \
  --member "principal://iam.googleapis.com/projects/$NUMBER/locations/global/workloadIdentityPools/github/subject/repo:$REPO:environment:$ENV"

echo "GCP_WORKLOAD_IDENTITY_PROVIDER=projects/$NUMBER/locations/global/workloadIdentityPools/github/providers/github"
echo "GCP_DEPLOY_SERVICE_ACCOUNT=$SA"
```

The role list is a starting point that covers everything this repo deploys.
If a first deploy fails on a missing permission, the error names the role to
add.

### 6. Set up the GitHub environment

In the repository's Settings → Environments, create `dev`, `staging` and
`prod`. In each, add two **variables** (not secrets) with the values the
script printed: `GCP_WORKLOAD_IDENTITY_PROVIDER` and
`GCP_DEPLOY_SERVICE_ACCOUNT`.

For `prod`, also:

- Add yourself under **Required reviewers**, so every prod deploy waits for
  your approval.
- Under **Deployment branches and tags**, allow only `main` and tags matching
  `v*`.

For `staging`, allow only `main`.

### 7. After the first deploy

- **Stripe webhooks:** point Billing's webhook at the deployed
  `stripeWebhook` URL and Connect's at `onlineCheckoutWebhook` (both listed in
  the Functions console), then set the real webhook secrets from step 4 and
  run the deploy again. See [commercial.md](commercial.md).
- **First platform admin:** sign in with
  `gcloud auth application-default login`, then
  `node functions/scripts/add-platform-admin.mjs --project <id> --email you@example.com`.
- **Restrict the API key:** in Google Cloud → APIs & Services → Credentials,
  limit the browser key to the three sites' addresses (and any custom
  domains).
- **Alerts:** create the alert policies in [monitoring.md](monitoring.md).

## Day to day

- **Staging:** merge to `main`. Watch the **Deploy** run in GitHub Actions;
  its summary links to the ordering site.
- **Prod:** tag the commit on `main` you want to ship and push the tag:
  `git tag v1.0.0 && git push origin v1.0.0`. Approve the run in GitHub.
  Or run **Deploy** by hand from `main` and pick `prod`.
- **Dev:** Actions → Deploy → Run workflow, pick the branch and `dev`.
- **POS tablets:** each run attaches `pos-<env>-<commit>` with the APK. It's
  signed with the debug key for now, which is fine for installing on your own
  tablets but not for Google Play. A release signing key comes before Play.
- **From your own machine:** `npm run deploy:dev` or `npm run deploy:staging`
  (after `npx firebase login`). Prod only deploys from GitHub, so it always
  has a reviewer and a record.

## Rolling back

Hosting keeps earlier releases: Hosting → the site → Release history → Roll
back. For Functions and rules, revert the change on `main` and let staging
redeploy, then tag a new version for prod.
