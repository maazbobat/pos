// npm run test:env
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import {
  crossProblems,
  ENVS,
  firebaserc,
  functionsEnv,
  HOSTING_TARGETS,
  initConfig,
  KEYS,
  loadAll,
  readinessProblems,
  ROOT,
  shapeProblems,
} from "./env.mjs";

const filled = (env, id) => ({
  ...initConfig(loadAll()[env], id),
  FIREBASE_API_KEY: "AIzaTest",
  FIREBASE_MESSAGING_SENDER_ID: "123",
  FIREBASE_WEB_APP_ID: "1:123:web:abc",
  FIREBASE_ANDROID_APP_ID: "1:123:android:def",
});

test("the committed config files have the right shape and .firebaserc matches them", () => {
  const configs = loadAll();
  for (const env of ENVS) assert.deepEqual(shapeProblems(env, configs[env]), []);
  assert.deepEqual(crossProblems(configs), []);
  assert.equal(readFileSync(join(ROOT, ".firebaserc"), "utf8"), firebaserc(configs));
});

test("every config key the apps read is a dart-define in AppEnvironment", () => {
  const dart = readFileSync(join(ROOT, "packages/shared/lib/src/app_environment.dart"), "utf8");
  const appKeys = Object.keys(KEYS).filter((k) => k.startsWith("FIREBASE_") || k === "POS_ENV");
  for (const key of appKeys) assert.ok(dart.includes(`'${key}'`), `${key} missing from app_environment.dart`);
});

test("firebase.json has a Hosting target for every site in the config", () => {
  const fb = JSON.parse(readFileSync(join(ROOT, "firebase.json"), "utf8"));
  assert.deepEqual(fb.hosting.map((h) => h.target).sort(), Object.keys(HOSTING_TARGETS).sort());
});

test("init fills what follows from the project ID, leaving console values to paste", () => {
  const c = initConfig(loadAll().staging, "acme-pos-staging");
  assert.equal(c.HOSTING_SITE_MANAGER, "acme-pos-staging-manager");
  assert.equal(c.ORDERING_SITE_URL, "https://acme-pos-staging.web.app");
  const left = readinessProblems("staging", c);
  assert.ok(left.some((p) => p.includes("FIREBASE_API_KEY")));
  assert.ok(!left.some((p) => p.includes("HOSTING_SITE")));
});

test("a filled-in environment is ready and gets an alias and Hosting targets", () => {
  const configs = { ...loadAll(), staging: filled("staging", "acme-pos-staging") };
  assert.deepEqual(readinessProblems("staging", configs.staging), []);
  const rc = JSON.parse(firebaserc(configs));
  assert.equal(rc.projects.default, "demo-pos");
  assert.equal(rc.projects.staging, "acme-pos-staging");
  assert.equal(rc.projects.prod, undefined);
  assert.deepEqual(rc.targets["acme-pos-staging"].hosting.admin, ["acme-pos-staging-admin"]);
  assert.match(functionsEnv(configs.staging), /^ORDERING_SITE_URL=https:\/\/acme-pos-staging\.web\.app$/m);
});

test("bad values are caught", () => {
  const c = { ...filled("prod", "acme-pos"), ORDERING_SITE_URL: "http://shop.example/" };
  assert.ok(shapeProblems("prod", c).some((p) => p.includes("ORDERING_SITE_URL")));
  assert.ok(shapeProblems("prod", { ...c, POS_ENV: "staging" }).some((p) => p.includes("POS_ENV")));
  assert.ok(shapeProblems("prod", { ...c, FIREBASE_PROJECT_ID: "demo-pos" }).some((p) => p.includes("real Firebase")));
  assert.ok(shapeProblems("prod", { ...c, EXTRA: "x" }).some((p) => p.includes("unknown key")));
});

test("two environments can't share a project or a site", () => {
  const configs = { dev: filled("dev", "acme-pos"), staging: filled("staging", "acme-pos"), prod: loadAll().prod };
  const problems = crossProblems(configs);
  assert.ok(problems.some((p) => p.includes("project acme-pos")));
  assert.ok(problems.some((p) => p.includes("site acme-pos-admin")));
});
