import type { DocumentData, Transaction } from "firebase-admin/firestore";
import { db } from "./firebase.js";
import { fail } from "./errors.js";
import type { Role, StaffRole } from "./roles.js";

/** Who is calling, from the verified auth token. Never from request data. */
export interface Caller {
  uid: string | null;
  email?: string | null;
}

export function requireUid(caller: Caller): string {
  if (!caller.uid) throw fail.unauthenticated();
  return caller.uid;
}

export interface Member {
  uid: string;
  orgId: string;
  kind: "user" | "device";
  status: "active" | "suspended";
  orgRole: "owner" | null;
  locationRoles: Record<string, Role>;
  roles: Role[];
  displayName?: string | null;
  email?: string | null;
}

export function roleAt(member: Member, locationId: string): Role | null {
  if (member.status !== "active") return null;
  if (member.orgRole === "owner") return "owner";
  return member.locationRoles[locationId] ?? null;
}

/** Distinct roles, kept on the membership for the rules' org-wide checks. */
export function distinctRoles(orgRole: "owner" | null, locationRoles: Record<string, Role>): Role[] {
  const set = new Set<Role>(Object.values(locationRoles));
  if (orgRole === "owner") set.add("owner");
  return [...set].sort();
}

export const paths = {
  org: (orgId: string) => `orgs/${orgId}`,
  member: (orgId: string, uid: string) => `orgs/${orgId}/members/${uid}`,
  location: (orgId: string, locId: string) => `orgs/${orgId}/locations/${locId}`,
  staff: (orgId: string, locId: string, uid: string) => `orgs/${orgId}/locations/${locId}/staff/${uid}`,
  device: (orgId: string, locId: string, deviceId: string) =>
    `orgs/${orgId}/locations/${locId}/devices/${deviceId}`,
  pinGuard: (orgId: string, locId: string, deviceId: string) =>
    `orgs/${orgId}/locations/${locId}/devices/${deviceId}/private/pinGuard`,
  invite: (orgId: string, inviteId: string) => `orgs/${orgId}/invites/${inviteId}`,
  pinIndex: (orgId: string, key: string) => `orgs/${orgId}/pinIndex/${key}`,
  memberSecret: (orgId: string, uid: string) => `orgs/${orgId}/memberSecrets/${uid}`,
  pairingCode: (hash: string) => `pairingCodes/${hash}`,
  user: (uid: string) => `users/${uid}`,
  platformAdmin: (uid: string) => `platformAdmins/${uid}`,
};

async function read(tx: Transaction | null, path: string): Promise<DocumentData | null> {
  const ref = db().doc(path);
  const snap = tx ? await tx.get(ref) : await ref.get();
  return snap.exists ? (snap.data() as DocumentData) : null;
}

/** The org must exist, be active and have full (not read-only) access. */
export async function requireWritableOrg(tx: Transaction | null, orgId: string): Promise<DocumentData> {
  const org = await read(tx, paths.org(orgId));
  if (!org) throw fail.notFound("Organization not found.");
  if (org.status !== "active") throw fail.precondition("This organization is suspended.");
  if (org.accessLevel !== "full") throw fail.precondition("This organization is read-only.");
  return org;
}

export async function requireActiveLocation(
  tx: Transaction | null,
  orgId: string,
  locId: string,
): Promise<DocumentData> {
  const loc = await read(tx, paths.location(orgId, locId));
  if (!loc) throw fail.notFound("Location not found.");
  if (loc.status !== "active") throw fail.precondition("This location is closed.");
  return loc;
}

export async function getMember(tx: Transaction | null, orgId: string, uid: string): Promise<Member | null> {
  const data = await read(tx, paths.member(orgId, uid));
  if (!data) return null;
  return {
    uid,
    orgId,
    kind: data.kind === "device" ? "device" : "user",
    status: data.status === "active" ? "active" : "suspended",
    orgRole: data.orgRole === "owner" ? "owner" : null,
    locationRoles: (data.locationRoles ?? {}) as Record<string, Role>,
    roles: (data.roles ?? []) as Role[],
    displayName: data.displayName ?? null,
    email: data.email ?? null,
  };
}

/** The caller's active membership, or permission-denied. */
export async function requireActiveMember(tx: Transaction | null, orgId: string, uid: string): Promise<Member> {
  const member = await getMember(tx, orgId, uid);
  if (!member || member.status !== "active") throw fail.denied();
  return member;
}

export async function isPlatformAdmin(uid: string): Promise<boolean> {
  return (await db().doc(paths.platformAdmin(uid)).get()).exists;
}

export function membershipData(
  orgId: string,
  uid: string,
  fields: {
    kind: "user" | "device";
    orgRole: "owner" | null;
    locationRoles: Record<string, Role>;
    displayName?: string | null;
    email?: string | null;
  },
) {
  return {
    uid,
    orgId,
    kind: fields.kind,
    status: "active",
    orgRole: fields.orgRole,
    locationRoles: fields.locationRoles,
    roles: distinctRoles(fields.orgRole, fields.locationRoles),
    displayName: fields.displayName ?? null,
    email: fields.email ?? null,
  };
}

export type { StaffRole };
