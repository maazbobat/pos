#!/usr/bin/env node
/**
 * Per-environment settings: config/<env>.json is the one place each
 * environment's Firebase project, Hosting sites and public URLs live. This
 * script checks those files and builds what Firebase needs from them.
 *
 *   node scripts/env.mjs init <env> <project-id>   fill in what follows from the project ID
 *   node scripts/env.mjs sync                       rewrite .firebaserc from config/*.json
 *   node scripts/env.mjs check [--ready <env>]      check every file (and that <env> is fully set up)
 *   node scripts/env.mjs prepare <env>              check <env>, write functions/.env.<project-id>
 *   node scripts/env.mjs ready <env>                print true or false
 *   node scripts/env.mjs get <env> <KEY>            print one value
 *
 * The apps read the same files with `--dart-define-from-file=config/<env>.json`.
 * See docs/environments.md.
 */
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
export const ENVS = ["dev", "staging", "prod"];
export const PLACEHOLDER = "REPLACE_ME";
export const EMULATOR_PROJECT = "demo-pos";

/** Every key a config file has. Optional ones may be empty. */
export const KEYS = {
  POS_ENV: "required",
  FIREBASE_PROJECT_ID: "required",
  FIREBASE_API_KEY: "required",
  FIREBASE_AUTH_DOMAIN: "required",
  FIREBASE_STORAGE_BUCKET: "required",
  FIREBASE_MESSAGING_SENDER_ID: "required",
  FIREBASE_WEB_APP_ID: "required",
  FIREBASE_ANDROID_APP_ID: "required",
  FIREBASE_ANDROID_API_KEY: "optional",
  HOSTING_SITE_ONLINE: "required",
  HOSTING_SITE_MANAGER: "required",
  HOSTING_SITE_ADMIN: "required",
  ORDERING_SITE_URL: "required",
  MANAGER_APP_URL: "required",
  ANALYTICS_MEASUREMENT_ID: "optional",
};

/** Hosting targets in firebase.json, and the config key naming each one's site. */
export const HOSTING_TARGETS = {
  online: "HOSTING_SITE_ONLINE",
  manager: "HOSTING_SITE_MANAGER",
  admin: "HOSTING_SITE_ADMIN",
};

/** Values the Functions read with defineString(), written to functions/.env.<project-id>. */
export const FUNCTIONS_PARAMS = ["MANAGER_APP_URL", "ORDERING_SITE_URL"];

export function configPath(env, root = ROOT) {
  return join(root, "config", `${env}.json`);
}

export function loadConfig(env, root = ROOT) {
  return JSON.parse(readFileSync(configPath(env, root), "utf8"));
}

export function loadAll(root = ROOT) {
  return Object.fromEntries(ENVS.map((e) => [e, loadConfig(e, root)]));
}

const isSet = (v) => typeof v === "string" && v.length > 0 && !v.includes(PLACEHOLDER);

/** Problems with a file's shape. These fail CI even before any project exists. */
export function shapeProblems(env, config) {
  const out = [];
  for (const key of Object.keys(KEYS)) {
    if (!(key in config)) out.push(`${env}: missing ${key}`);
  }
  for (const [key, value] of Object.entries(config)) {
    if (!(key in KEYS)) out.push(`${env}: unknown key ${key}`);
    else if (typeof value !== "string") out.push(`${env}: ${key} must be a string`);
  }
  if (config.POS_ENV !== env) out.push(`${env}: POS_ENV must be "${env}"`);
  for (const key of ["ORDERING_SITE_URL", "MANAGER_APP_URL"]) {
    const v = config[key];
    if (isSet(v) && (!/^https:\/\/[^/]+/.test(v) || v.endsWith("/"))) {
      out.push(`${env}: ${key} must be an https:// address with no trailing slash`);
    }
  }
  const id = config.FIREBASE_PROJECT_ID;
  if (isSet(id) && (id.startsWith("demo-") || !/^[a-z][a-z0-9-]{4,28}[a-z0-9]$/.test(id))) {
    out.push(`${env}: FIREBASE_PROJECT_ID "${id}" isn't a real Firebase project ID`);
  }
  const ga = config.ANALYTICS_MEASUREMENT_ID;
  if (ga && !ga.startsWith("G-")) out.push(`${env}: ANALYTICS_MEASUREMENT_ID must start with G-`);
  return out;
}

/** Problems stopping a deploy to env: anything still a placeholder. */
export function readinessProblems(env, config) {
  const out = shapeProblems(env, config);
  for (const [key, need] of Object.entries(KEYS)) {
    if (need === "required" && !isSet(config[key])) out.push(`${env}: ${key} is not filled in`);
    if (need === "optional" && config[key]?.includes(PLACEHOLDER)) out.push(`${env}: ${key} is still a placeholder`);
  }
  return out;
}

/** Problems across environments: they must never share a project or a site. */
export function crossProblems(configs) {
  const out = [];
  const seen = new Map();
  for (const [env, c] of Object.entries(configs)) {
    for (const key of ["FIREBASE_PROJECT_ID", ...Object.values(HOSTING_TARGETS)]) {
      const v = c[key];
      if (!isSet(v)) continue;
      const tag = key === "FIREBASE_PROJECT_ID" ? `project ${v}` : `site ${v}`;
      if (seen.has(tag)) out.push(`${seen.get(tag)} and ${env} both use ${tag}`);
      else seen.set(tag, env);
    }
  }
  return out;
}

/** .firebaserc as config/*.json describe it. Unfinished environments get no alias. */
export function firebaserc(configs) {
  const projects = { default: EMULATOR_PROJECT };
  const targets = {};
  for (const env of ENVS) {
    const c = configs[env];
    const id = c?.FIREBASE_PROJECT_ID;
    if (!isSet(id)) continue;
    projects[env] = id;
    const hosting = {};
    for (const [target, key] of Object.entries(HOSTING_TARGETS)) {
      if (isSet(c[key])) hosting[target] = [c[key]];
    }
    if (Object.keys(hosting).length) targets[id] = { hosting };
  }
  const rc = { projects };
  if (Object.keys(targets).length) rc.targets = targets;
  return `${JSON.stringify(rc, null, 2)}\n`;
}

export function functionsEnv(config) {
  const lines = [
    "# Written by `node scripts/env.mjs prepare` from config/*.json. Don't edit; git-ignored.",
    ...FUNCTIONS_PARAMS.map((k) => `${k}=${config[k]}`),
  ];
  return `${lines.join("\n")}\n`;
}

/** What follows from a project ID with Firebase's default names. */
export function initConfig(config, projectId) {
  return {
    ...config,
    FIREBASE_PROJECT_ID: projectId,
    FIREBASE_AUTH_DOMAIN: `${projectId}.firebaseapp.com`,
    FIREBASE_STORAGE_BUCKET: `${projectId}.firebasestorage.app`,
    HOSTING_SITE_ONLINE: projectId,
    HOSTING_SITE_MANAGER: `${projectId}-manager`,
    HOSTING_SITE_ADMIN: `${projectId}-admin`,
    ORDERING_SITE_URL: `https://${projectId}.web.app`,
    MANAGER_APP_URL: `https://${projectId}-manager.web.app`,
  };
}

function writeConfig(env, config) {
  writeFileSync(configPath(env), `${JSON.stringify(config, null, 2)}\n`);
}

function fail(problems) {
  for (const p of problems) console.error(`  ✗ ${p}`);
  process.exit(1);
}

function needEnv(env) {
  if (!ENVS.includes(env)) {
    console.error(`Environment must be one of ${ENVS.join(", ")}.`);
    process.exit(2);
  }
}

function main([cmd, ...args]) {
  switch (cmd) {
    case "init": {
      const [env, projectId] = args;
      needEnv(env);
      const next = initConfig(loadConfig(env), projectId ?? "");
      const problems = shapeProblems(env, next);
      if (problems.length) fail(problems);
      writeConfig(env, next);
      const configs = loadAll();
      writeFileSync(join(ROOT, ".firebaserc"), firebaserc(configs));
      console.log(`Filled config/${env}.json for ${projectId} and updated .firebaserc.`);
      const left = readinessProblems(env, next);
      if (left.length) {
        console.log("Still to fill in from the Firebase console (Project settings → Your apps):");
        for (const p of left) console.log(`  - ${p.replace(`${env}: `, "")}`);
      }
      return;
    }
    case "sync": {
      writeFileSync(join(ROOT, ".firebaserc"), firebaserc(loadAll()));
      console.log("Wrote .firebaserc");
      return;
    }
    case "check": {
      const configs = loadAll();
      const problems = [...ENVS.flatMap((e) => shapeProblems(e, configs[e])), ...crossProblems(configs)];
      const rc = readFileSync(join(ROOT, ".firebaserc"), "utf8");
      if (rc !== firebaserc(configs)) {
        problems.push(".firebaserc is out of date with config/*.json. Run `node scripts/env.mjs sync`.");
      }
      const i = args.indexOf("--ready");
      if (i >= 0) {
        needEnv(args[i + 1]);
        problems.push(...readinessProblems(args[i + 1], configs[args[i + 1]]));
      }
      if (problems.length) fail(problems);
      for (const e of ENVS) {
        console.log(`  ${e}: ${readinessProblems(e, configs[e]).length ? "not set up yet" : "ready"}`);
      }
      return;
    }
    case "ready": {
      const [env] = args;
      needEnv(env);
      console.log(readinessProblems(env, loadConfig(env)).length ? "false" : "true");
      return;
    }
    case "prepare": {
      const [env] = args;
      needEnv(env);
      const configs = loadAll();
      const config = configs[env];
      const problems = [...readinessProblems(env, config), ...crossProblems(configs)];
      if (readFileSync(join(ROOT, ".firebaserc"), "utf8") !== firebaserc(configs)) {
        problems.push(".firebaserc is out of date with config/*.json. Run `node scripts/env.mjs sync`.");
      }
      if (problems.length) fail(problems);
      const file = join(ROOT, "functions", `.env.${config.FIREBASE_PROJECT_ID}`);
      writeFileSync(file, functionsEnv(config));
      console.log(`Ready to deploy ${env} (${config.FIREBASE_PROJECT_ID}). Wrote functions/.env.${config.FIREBASE_PROJECT_ID}`);
      return;
    }
    case "get": {
      const [env, key] = args;
      needEnv(env);
      const value = loadConfig(env)[key];
      if (value === undefined) {
        console.error(`No ${key} in config/${env}.json`);
        process.exit(2);
      }
      console.log(value);
      return;
    }
    default:
      console.error("Usage: node scripts/env.mjs init|sync|check|ready|prepare|get … (see the top of this file)");
      process.exit(2);
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main(process.argv.slice(2));
}
