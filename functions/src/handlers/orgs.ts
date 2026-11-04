/**
 * Organization and location setup.
 *
 * A platform admin creates an organization and invites its first owner (the
 * admin portal will call this). From then on the owner runs it: creating,
 * closing and reopening locations. Self-serve sign-up can reuse
 * createOrgDocs once billing exists (roadmap step 3).
 */
import { FieldValue, type Transaction } from "firebase-admin/firestore";
import { audit } from "../lib/audit.js";
import { fail } from "../lib/errors.js";
import { db } from "../lib/firebase.js";
import {
  type Caller,
  isPlatformAdmin,
  paths,
  requireActiveMember,
  requireUid,
  requireWritableOrg,
} from "../lib/tenant.js";
import { asInput, docId, email as emailField, oneOf, optStr, str } from "../lib/validate.js";
import { type InviteResult, writeInvite } from "./staff.js";

export const ORG_TYPES = ["independent", "franchise", "chain"] as const;

export const PROVINCES = [
  "AB", "BC", "MB", "NB", "NL", "NS", "NT", "NU", "ON", "PE", "QC", "SK", "YT",
] as const;
export type Province = (typeof PROVINCES)[number];

/**
 * Starting GST/HST rate for a new location, as data the manager can edit.
 * Provincial sales taxes (PST, QST, RST) and their restaurant-meal rules vary,
 * so they're left for the owner to add, and `reviewed: false` flags the tax
 * settings until someone confirms them. Rates need accountant review before launch.
 */
export function defaultTaxSettings(province: Province) {
  const hst: Partial<Record<Province, number>> = { ON: 0.13, NB: 0.15, NL: 0.15, NS: 0.14, PE: 0.15 };
  const rate = hst[province];
  return {
    province,
    rates: [rate === undefined
      ? { id: "gst", name: "GST", rate: 0.05 }
      : { id: "hst", name: "HST", rate }],
    reviewed: false,
  };
}

export interface CreateOrganizationResult {
  orgId: string;
  ownerInvite: InviteResult;
}

export async function createOrganization(caller: Caller, data: unknown): Promise<CreateOrganizationResult> {
  const uid = requireUid(caller);
  const input = asInput(data);
  const name = str(input, "name", { max: 100 });
  const type = oneOf(input, "type", ORG_TYPES);
  const ownerEmail = emailField(input, "ownerEmail");
  const ownerName = optStr(input, "ownerName", { max: 80 });
  if (!(await isPlatformAdmin(uid))) throw fail.denied();

  const orgRef = db().collection("orgs").doc();
  const orgId = orgRef.id;
  const ownerInvite = await db().runTransaction(async (tx) => {
    const now = FieldValue.serverTimestamp();
    tx.create(orgRef, { name, type, status: "active", accessLevel: "full", plan: "trial", createdBy: uid, createdAt: now });
    tx.create(db().doc(`${paths.org(orgId)}/billing/subscription`), { orgId, status: "trialing", plan: "trial", createdAt: now });
    tx.create(db().doc(`${paths.org(orgId)}/config/brand`), { orgId, name, createdAt: now, createdBy: uid });
    audit(tx, orgId, { action: "org.created", actorUid: uid, target: { name, type, platformAdmin: true } });
    return writeInvite(tx, orgId, {
      email: ownerEmail,
      displayName: ownerName,
      role: "owner",
      locationId: null,
      invitedBy: uid,
    });
  });
  return { orgId, ownerInvite };
}

async function requireOwner(tx: Transaction, orgId: string, uid: string) {
  const member = await requireActiveMember(tx, orgId, uid);
  if (member.orgRole !== "owner") throw fail.denied("Only an owner can do that.");
  return member;
}

export async function createLocation(caller: Caller, data: unknown): Promise<{ locationId: string }> {
  const uid = requireUid(caller);
  const input = asInput(data);
  const orgId = docId(input, "orgId");
  const name = str(input, "name", { max: 100 });
  const province = oneOf(input, "province", PROVINCES);
  const timezone = str(input, "timezone", { max: 60 });
  if (!Intl.supportedValuesOf("timeZone").includes(timezone)) throw fail.invalid("Unknown timezone.");
  const address = optStr(input, "address", { max: 300 });

  const locRef = db().collection(`${paths.org(orgId)}/locations`).doc();
  const locationId = locRef.id;
  await db().runTransaction(async (tx) => {
    await requireOwner(tx, orgId, uid);
    await requireWritableOrg(tx, orgId);
    const ids = { orgId, locationId };
    const now = FieldValue.serverTimestamp();
    tx.create(locRef, { ...ids, name, province, timezone, address, status: "active", createdBy: uid, createdAt: now });
    tx.create(db().doc(`${locRef.path}/settings/tax`), { ...ids, ...defaultTaxSettings(province), createdAt: now });
    audit(tx, orgId, { action: "location.created", actorUid: uid, locationId, target: { name, province } });
  });
  return { locationId };
}

export async function setLocationStatus(caller: Caller, data: unknown): Promise<{ ok: true }> {
  const uid = requireUid(caller);
  const input = asInput(data);
  const orgId = docId(input, "orgId");
  const locationId = docId(input, "locationId");
  const status = oneOf(input, "status", ["active", "closed"] as const);

  await db().runTransaction(async (tx) => {
    await requireOwner(tx, orgId, uid);
    await requireWritableOrg(tx, orgId);
    const ref = db().doc(paths.location(orgId, locationId));
    const loc = await tx.get(ref);
    if (!loc.exists) throw fail.notFound("Location not found.");
    tx.update(ref, { status, updatedAt: FieldValue.serverTimestamp() });
    audit(tx, orgId, {
      action: status === "closed" ? "location.closed" : "location.reopened",
      actorUid: uid,
      locationId,
    });
  });
  return { ok: true };
}
