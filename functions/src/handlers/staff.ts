/**
 * Staff invites and role changes.
 *
 * Memberships are only ever written here, never by clients. Who can hand out
 * which role is in lib/roles.ts (canAssign). An invite is accepted by a
 * signed-in user whose account email matches it and who holds the token from
 * the invite link, so a forwarded link alone isn't enough.
 */
import { FieldValue, Timestamp, type Transaction } from "firebase-admin/firestore";
import { audit } from "../lib/audit.js";
import { fail } from "../lib/errors.js";
import { db } from "../lib/firebase.js";
import { newToken, sha256 } from "../lib/ids.js";
import { canAssign, STAFF_ROLES, type Role, type StaffRole } from "../lib/roles.js";
import {
  type Caller,
  distinctRoles,
  getMember,
  type Member,
  membershipData,
  paths,
  requireActiveLocation,
  requireActiveMember,
  requireUid,
  requireWritableOrg,
  roleAt,
} from "../lib/tenant.js";
import { asInput, docId, email as emailField, oneOf, optStr, str } from "../lib/validate.js";

export const INVITE_TTL_MS = 7 * 24 * 60 * 60 * 1000;

/** "owner" invites are org-wide; every other role is for one location. */
export const INVITABLE_ROLES = ["owner", ...STAFF_ROLES] as const;
export type InvitableRole = (typeof INVITABLE_ROLES)[number];

export interface InviteResult {
  inviteId: string;
  /** Goes in the invite link. Only its hash is stored. */
  token: string;
  expiresAt: string;
}

/** Writes a pending invite. Callers have already checked permission. */
export function writeInvite(
  tx: Transaction,
  orgId: string,
  fields: { email: string; displayName: string | null; role: InvitableRole; locationId: string | null; invitedBy: string },
): InviteResult {
  const ref = db().collection(`orgs/${orgId}/invites`).doc();
  const token = newToken();
  const expiresAt = Timestamp.fromMillis(Date.now() + INVITE_TTL_MS);
  tx.create(ref, {
    orgId,
    locationId: fields.locationId,
    email: fields.email,
    displayName: fields.displayName,
    role: fields.role,
    status: "pending",
    tokenHash: sha256(token),
    invitedBy: fields.invitedBy,
    createdAt: FieldValue.serverTimestamp(),
    expiresAt,
  });
  audit(tx, orgId, {
    action: "staff.invited",
    actorUid: fields.invitedBy,
    locationId: fields.locationId,
    target: { inviteId: ref.id, email: fields.email, role: fields.role },
  });
  return { inviteId: ref.id, token, expiresAt: expiresAt.toDate().toISOString() };
}

function requireCanGrant(actor: Member, role: InvitableRole, locationId: string | null): void {
  if (role === "owner") {
    if (actor.orgRole !== "owner") throw fail.denied("Only an owner can add another owner.");
    return;
  }
  if (!locationId) throw fail.invalid("locationId is required for this role.");
  if (!canAssign(roleAt(actor, locationId), role)) {
    throw fail.denied("You can't give that role at this location.");
  }
}

export async function inviteStaff(caller: Caller, data: unknown): Promise<InviteResult> {
  const uid = requireUid(caller);
  const input = asInput(data);
  const orgId = docId(input, "orgId");
  const role = oneOf(input, "role", INVITABLE_ROLES);
  const locationId = role === "owner" ? null : docId(input, "locationId");
  const email = emailField(input, "email");
  const displayName = optStr(input, "displayName", { max: 80 });

  return db().runTransaction(async (tx) => {
    const actor = await requireActiveMember(tx, orgId, uid);
    await requireWritableOrg(tx, orgId);
    if (locationId) await requireActiveLocation(tx, orgId, locationId);
    requireCanGrant(actor, role, locationId);
    return writeInvite(tx, orgId, { email, displayName, role, locationId, invitedBy: uid });
  });
}

export async function revokeInvite(caller: Caller, data: unknown): Promise<{ revoked: true }> {
  const uid = requireUid(caller);
  const input = asInput(data);
  const orgId = docId(input, "orgId");
  const inviteId = docId(input, "inviteId");

  await db().runTransaction(async (tx) => {
    const actor = await requireActiveMember(tx, orgId, uid);
    const ref = db().doc(paths.invite(orgId, inviteId));
    const invite = (await tx.get(ref)).data();
    if (!invite || invite.status !== "pending") throw fail.notFound("Invite not found.");
    requireCanGrant(actor, invite.role, invite.locationId);
    tx.update(ref, { status: "revoked", revokedBy: uid, revokedAt: FieldValue.serverTimestamp() });
    audit(tx, orgId, {
      action: "staff.invite_revoked",
      actorUid: uid,
      locationId: invite.locationId,
      target: { inviteId, email: invite.email, role: invite.role },
    });
  });
  return { revoked: true };
}

export interface AcceptInviteResult {
  orgId: string;
  locationId: string | null;
  role: InvitableRole;
}

export async function acceptInvite(caller: Caller, data: unknown): Promise<AcceptInviteResult> {
  const uid = requireUid(caller);
  const callerEmail = caller.email?.toLowerCase() ?? null;
  const input = asInput(data);
  const orgId = docId(input, "orgId");
  const inviteId = docId(input, "inviteId");
  const token = str(input, "token", { max: 100 });

  return db().runTransaction(async (tx) => {
    const ref = db().doc(paths.invite(orgId, inviteId));
    const invite = (await tx.get(ref)).data();
    // Same answer for every mismatch, so the endpoint can't confirm guesses.
    if (!invite || invite.status !== "pending" || invite.tokenHash !== sha256(token)) {
      throw fail.notFound("This invite isn't valid.");
    }
    if ((invite.expiresAt as Timestamp).toMillis() < Date.now()) {
      throw fail.precondition("This invite has expired. Ask for a new one.");
    }
    if (!callerEmail || callerEmail !== invite.email) {
      throw fail.denied(`Sign in as ${invite.email} to accept this invite.`);
    }
    await requireWritableOrg(tx, orgId);
    const locationId = invite.locationId as string | null;
    if (locationId) await requireActiveLocation(tx, orgId, locationId);

    const existing = await getMember(tx, orgId, uid);
    if (existing?.kind === "device") throw fail.precondition("Devices can't accept invites.");
    if (existing && existing.status !== "active") {
      throw fail.precondition("Your access to this organization is suspended.");
    }
    const displayName = existing?.displayName ?? invite.displayName ?? null;
    const role = invite.role as InvitableRole;
    const orgRole = role === "owner" ? "owner" : (existing?.orgRole ?? null);
    const locationRoles: Record<string, Role> = { ...(existing?.locationRoles ?? {}) };
    if (locationId) locationRoles[locationId] = role as StaffRole;

    const now = FieldValue.serverTimestamp();
    tx.set(db().doc(paths.member(orgId, uid)), {
      ...membershipData(orgId, uid, { kind: "user", orgRole, locationRoles, displayName, email: callerEmail }),
      updatedAt: now,
    });
    if (locationId) {
      tx.set(db().doc(paths.staff(orgId, locationId, uid)), {
        orgId, locationId, uid, role, displayName, email: callerEmail, updatedAt: now,
      });
    }
    tx.set(db().doc(paths.user(uid)), { orgIds: FieldValue.arrayUnion(orgId) }, { merge: true });
    tx.update(ref, { status: "accepted", acceptedBy: uid, acceptedAt: now });
    audit(tx, orgId, {
      action: "staff.joined",
      actorUid: uid,
      locationId,
      target: { inviteId, role, invitedBy: invite.invitedBy },
    });
    return { orgId, locationId, role };
  });
}

/**
 * Changes or removes a member's role at one location (role: null removes).
 * The caller must be able to grant both the current and the new role, and
 * can't change their own access. Owner status is changed with setOwner.
 */
export async function setMemberRole(caller: Caller, data: unknown): Promise<{ ok: true }> {
  const uid = requireUid(caller);
  const input = asInput(data);
  const orgId = docId(input, "orgId");
  const locationId = docId(input, "locationId");
  const targetUid = docId(input, "uid");
  const newRole = input.role === null ? null : oneOf(input, "role", STAFF_ROLES);
  if (targetUid === uid) throw fail.denied("You can't change your own access.");

  await db().runTransaction(async (tx) => {
    const actor = await requireActiveMember(tx, orgId, uid);
    // Removing access works even on a read-only org; granting needs full access.
    if (newRole) await requireWritableOrg(tx, orgId);
    const target = await getMember(tx, orgId, targetUid);
    if (!target || target.kind !== "user") throw fail.notFound("Staff member not found.");
    if (target.orgRole === "owner") throw fail.denied("Owners are managed with setOwner.");

    const actorRole = roleAt(actor, locationId);
    const current = target.locationRoles[locationId] as StaffRole | undefined;
    if (current && !canAssign(actorRole, current)) throw fail.denied();
    if (newRole && !canAssign(actorRole, newRole)) throw fail.denied("You can't give that role here.");
    if (newRole) await requireActiveLocation(tx, orgId, locationId);

    const locationRoles: Record<string, Role> = { ...target.locationRoles };
    if (newRole) locationRoles[locationId] = newRole;
    else delete locationRoles[locationId];

    const now = FieldValue.serverTimestamp();
    const memberRef = db().doc(paths.member(orgId, targetUid));
    const staffRef = db().doc(paths.staff(orgId, locationId, targetUid));
    if (Object.keys(locationRoles).length === 0) {
      // No roles left anywhere: the person leaves the org.
      tx.delete(memberRef);
      tx.set(db().doc(paths.user(targetUid)), { orgIds: FieldValue.arrayRemove(orgId) }, { merge: true });
    } else {
      tx.update(memberRef, { locationRoles, roles: distinctRoles(null, locationRoles), updatedAt: now });
    }
    if (newRole) {
      tx.set(staffRef, {
        orgId, locationId, uid: targetUid, role: newRole,
        displayName: target.displayName ?? null, email: target.email ?? null, updatedAt: now,
      });
    } else {
      tx.delete(staffRef);
    }
    audit(tx, orgId, {
      action: newRole ? "staff.role_changed" : "staff.removed",
      actorUid: uid,
      locationId,
      target: { uid: targetUid, from: current ?? null, to: newRole },
    });
  });
  return { ok: true };
}

/** Grants or removes org ownership. Owners only; never on yourself. */
export async function setOwner(caller: Caller, data: unknown): Promise<{ ok: true }> {
  const uid = requireUid(caller);
  const input = asInput(data);
  const orgId = docId(input, "orgId");
  const targetUid = docId(input, "uid");
  if (typeof input.owner !== "boolean") throw fail.invalid("owner must be true or false.");
  const owner = input.owner;
  if (targetUid === uid) throw fail.denied("You can't change your own access.");

  await db().runTransaction(async (tx) => {
    const actor = await requireActiveMember(tx, orgId, uid);
    if (actor.orgRole !== "owner") throw fail.denied();
    if (owner) await requireWritableOrg(tx, orgId);
    const target = await getMember(tx, orgId, targetUid);
    if (!target || target.kind !== "user") throw fail.notFound("Member not found.");
    const orgRole = owner ? "owner" : null;
    const memberRef = db().doc(paths.member(orgId, targetUid));
    if (!owner && Object.keys(target.locationRoles).length === 0) {
      tx.delete(memberRef);
      tx.set(db().doc(paths.user(targetUid)), { orgIds: FieldValue.arrayRemove(orgId) }, { merge: true });
    } else {
      tx.update(memberRef, {
        orgRole,
        roles: distinctRoles(orgRole, target.locationRoles),
        updatedAt: FieldValue.serverTimestamp(),
      });
    }
    audit(tx, orgId, {
      action: owner ? "staff.owner_granted" : "staff.owner_removed",
      actorUid: uid,
      target: { uid: targetUid },
    });
  });
  return { ok: true };
}
