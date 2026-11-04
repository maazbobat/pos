import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  initializeTestEnvironment,
  type RulesTestEnvironment,
} from "@firebase/rules-unit-testing";
import type { Firestore } from "firebase/firestore";

// A demo- project ID makes the emulator refuse to talk to any real project.
export const PROJECT_ID = "demo-pos";

const rulesPath = fileURLToPath(new URL("../../../firestore.rules", import.meta.url));

export async function createEnv(): Promise<RulesTestEnvironment> {
  const [host, port] = (process.env.FIRESTORE_EMULATOR_HOST ?? "127.0.0.1:8080").split(":");
  return initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: {
      rules: readFileSync(rulesPath, "utf8"),
      host,
      port: Number(port),
    },
  });
}

/** Runs `fn` with a Firestore client that bypasses the rules. */
export async function asAdmin(
  env: RulesTestEnvironment,
  fn: (db: Firestore) => Promise<void>,
): Promise<void> {
  await env.withSecurityRulesDisabled(async (ctx) => {
    await fn(ctx.firestore() as unknown as Firestore);
  });
}

/** A Firestore client signed in as `uid`, or signed out when `uid` is null. */
export function dbFor(env: RulesTestEnvironment, uid: string | null): Firestore {
  const ctx = uid === null ? env.unauthenticatedContext() : env.authenticatedContext(uid);
  return ctx.firestore() as unknown as Firestore;
}
