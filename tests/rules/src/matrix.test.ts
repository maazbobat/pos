import { assertFails, assertSucceeds, type RulesTestEnvironment } from "@firebase/rules-unit-testing";
import { afterAll, beforeAll, describe, test } from "vitest";
import { asAdmin, createEnv, dbFor } from "./env.js";
import {
  LOCATION_ROLES,
  memberUid,
  ownerUid,
  PLATFORM_ADMIN,
  seed,
  type OrgId,
  type Role,
} from "./fixtures.js";
import { OPERATIONS, TARGET_LOC, TARGET_ORG, type Operation } from "./matrix.js";

interface Subject {
  label: string;
  uid: string | null;
  org: OrgId | null;
  role: Role | null;
  loc: string | null;
}

const subjects: Subject[] = [
  { label: "Org A owner", uid: ownerUid("org-a"), org: "org-a", role: "owner", loc: null },
  ...LOCATION_ROLES.flatMap((role) =>
    (["cambridge", "toronto"] as const).map((loc) => ({
      label: `Org A ${loc} ${role}`,
      uid: memberUid("org-a", loc, role),
      org: "org-a" as const,
      role,
      loc,
    })),
  ),
  { label: "Org B owner", uid: ownerUid("org-b"), org: "org-b", role: "owner", loc: null },
  ...LOCATION_ROLES.map((role) => ({
    label: `Org B halifax ${role}`,
    uid: memberUid("org-b", "halifax", role),
    org: "org-b" as const,
    role,
    loc: "halifax",
  })),
  { label: "platform admin without a grant", uid: PLATFORM_ADMIN, org: null, role: null, loc: null },
  { label: "signed-out caller", uid: null, org: null, role: null, loc: null },
];

function expected(op: Operation, s: Subject): boolean {
  if (s.org !== TARGET_ORG || s.role === null) return false;
  if (!op.allowed.includes(s.role)) return false;
  if (s.role === "owner" || op.scope === "org") return true;
  return s.loc === TARGET_LOC;
}

let env: RulesTestEnvironment;
let caseNo = 0;

beforeAll(async () => {
  env = await createEnv();
  await env.clearFirestore();
  await asAdmin(env, seed);
});

afterAll(async () => {
  await env?.cleanup();
});

describe.each(OPERATIONS)("$name", (op) => {
  test.each(subjects)("$label", async (s) => {
    const ctx = { uid: s.uid ?? "anonymous", id: `case-${++caseNo}` };
    if (op.setup) await asAdmin(env, (admin) => op.setup!(admin, ctx));
    const attempt = op.run(dbFor(env, s.uid), ctx);
    if (expected(op, s)) {
      await assertSucceeds(attempt);
    } else {
      await assertFails(attempt);
    }
  });
});
