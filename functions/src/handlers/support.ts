/**
 * Platform admin access to tenants.
 *
 * Being a platform admin grants no tenant access on its own (see
 * firestore.rules). To help a restaurant, the admin opens a time-boxed,
 * read-only support grant with a reason. The grant and its end are audited
 * in the org's own log, which the owner reads, and in platformAuditLog. The
 * owner can end a grant early.
 *
 * Suspending an org is also here: it's a platform decision (abuse, fraud,
 * an owner's request), separate from billing. A suspended org stays readable
 * by its owner.
 */
import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { auditPlatform, audit } from "../lib/audit.js";
import { fail } from "../lib/errors.js";
import { db } from "../lib/firebase.js";
import { syncPlatformOrg } from "../lib/platform.js";
import { type Caller, getMember, isPlatformAdmin, paths, requireUid } from "../lib/tenant.js";
import { asInput, docId, oneOf, str } from "../lib/validate.js";

export const MAX_SUPPORT_HOURS = 24;

export const supportGrantPath = (orgId: string, adminUid: string) => `orgs/${orgId}/supportGrants/${adminUid}`;

async function requirePlatformAdmin(caller: Caller): Promise<string> {
  const uid = requireUid(caller);
  if (!(await isPlatformAdmin(uid))) throw fail.denied();
  return uid;
}

export async function grantSupportAccess(
  caller: Caller,
  data: unknown,
  now = Date.now(),
): Promise<{ expiresAt: number }> {
  const uid = await requirePlatformAdmin(caller);
  const input = asInput(data);
  const orgId = docId(input, "orgId");
  const reason = str(input, "reason", { min: 5, max: 300 });
  const hours = input.hours ?? 2;
  if (typeof hours !== "number" || !Number.isInteger(hours) || hours < 1 || hours > MAX_SUPPORT_HOURS) {
    throw fail.invalid(`hours must be a whole number from 1 to ${MAX_SUPPORT_HOURS}.`);
  }
  const expiresAt = now + hours * 60 * 60 * 1000;

  await db().runTransaction(async (tx) => {
    const org = await tx.get(db().doc(paths.org(orgId)));
    if (!org.exists) throw fail.notFound("Organization not found.");
    tx.set(db().doc(supportGrantPath(orgId, uid)), {
      orgId,
      adminUid: uid,
      adminEmail: caller.email ?? null,
      reason,
      access: "read",
      grantedAt: FieldValue.serverTimestamp(),
      expiresAt: Timestamp.fromMillis(expiresAt),
    });
    auditPlatform(tx, orgId, {
      action: "support.access_granted",
      actorUid: uid,
      reason,
      target: { hours, expiresAt: Timestamp.fromMillis(expiresAt) },
    });
  });
  return { expiresAt };
}

/** Ends a grant. The admin who holds it, or the org's owner, can. */
export async function revokeSupportAccess(caller: Caller, data: unknown): Promise<{ ok: true }> {
  const uid = requireUid(caller);
  const input = asInput(data);
  const orgId = docId(input, "orgId");
  const adminUid = input.adminUid === undefined ? uid : docId(input, "adminUid");

  const [admin, member] = await Promise.all([isPlatformAdmin(uid), getMember(null, orgId, uid)]);
  const isOwner = member?.status === "active" && member.orgRole === "owner";
  const isHolder = admin && adminUid === uid;
  if (!isOwner && !isHolder) throw fail.denied();

  await db().runTransaction(async (tx) => {
    const ref = db().doc(supportGrantPath(orgId, adminUid));
    const grant = await tx.get(ref);
    if (!grant.exists) throw fail.notFound("There's no support access to end.");
    tx.delete(ref);
    const event = { action: "support.access_revoked", actorUid: uid, target: { adminUid } };
    if (isHolder) auditPlatform(tx, orgId, event);
    else audit(tx, orgId, event);
  });
  return { ok: true };
}

/** Suspends or reactivates an org. Always needs a reason. */
export async function setOrgStatus(caller: Caller, data: unknown): Promise<{ ok: true }> {
  const uid = await requirePlatformAdmin(caller);
  const input = asInput(data);
  const orgId = docId(input, "orgId");
  const status = oneOf(input, "status", ["active", "suspended"] as const);
  const reason = str(input, "reason", { min: 5, max: 300 });

  await db().runTransaction(async (tx) => {
    const ref = db().doc(paths.org(orgId));
    const org = await tx.get(ref);
    if (!org.exists) throw fail.notFound("Organization not found.");
    if (org.get("status") === status) return;
    tx.update(ref, { status, updatedAt: FieldValue.serverTimestamp() });
    syncPlatformOrg(tx, orgId, { status });
    auditPlatform(tx, orgId, {
      action: status === "suspended" ? "org.suspended" : "org.reactivated",
      actorUid: uid,
      reason,
    });
  });
  return { ok: true };
}
