/**
 * Cloud Functions entry point.
 *
 * Everything that changes who can do what is a Function, never a direct
 * client write (see firestore.rules). Each handler re-checks the caller's
 * membership from Firestore, never trusting an orgId or role in the request
 * beyond using it to look the membership up, and writes orgs/{orgId}/auditLog.
 *
 * Handlers live in handlers/ as plain async functions so the emulator tests
 * can call them directly; this file only wires them to callable endpoints.
 */
import { defineSecret } from "firebase-functions/params";
import { setGlobalOptions } from "firebase-functions/v2";
import { type CallableRequest, onCall } from "firebase-functions/v2/https";
import * as devices from "./handlers/devices.js";
import * as orgs from "./handlers/orgs.js";
import * as pins from "./handlers/pins.js";
import * as staff from "./handlers/staff.js";
import type { Caller } from "./lib/tenant.js";

// Montreal, so tenant data and compute stay in Canada.
setGlobalOptions({ region: "northamerica-northeast1", maxInstances: 20 });

const PIN_PEPPER = defineSecret("PIN_PEPPER");

function caller(req: CallableRequest): Caller {
  return { uid: req.auth?.uid ?? null, email: (req.auth?.token.email as string | undefined) ?? null };
}

type Handler<T> = (caller: Caller, data: unknown) => Promise<T>;
const callable = <T>(handler: Handler<T>) => onCall((req) => handler(caller(req), req.data));

// Onboarding
export const createOrganization = callable(orgs.createOrganization);
export const createLocation = callable(orgs.createLocation);
export const setLocationStatus = callable(orgs.setLocationStatus);

// Staff
export const inviteStaff = callable(staff.inviteStaff);
export const revokeInvite = callable(staff.revokeInvite);
export const acceptInvite = callable(staff.acceptInvite);
export const setMemberRole = callable(staff.setMemberRole);
export const setOwner = callable(staff.setOwner);

// Devices
export const createPairingCode = callable(devices.createPairingCode);
export const redeemPairingCode = callable(devices.redeemPairingCode);
export const revokeDevice = callable(devices.revokeDevice);

// Staff PINs on a paired device
export const setStaffPin = onCall({ secrets: [PIN_PEPPER] }, (req) =>
  pins.setStaffPin(caller(req), req.data, PIN_PEPPER.value()),
);
export const startStaffSession = onCall({ secrets: [PIN_PEPPER] }, (req) =>
  pins.startStaffSession(caller(req), req.data, PIN_PEPPER.value()),
);
