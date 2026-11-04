import { createHash, createHmac, randomBytes, randomInt } from "node:crypto";

// No 0/O, 1/I/L: codes are read off one screen and typed on another.
const CODE_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ";
export const PAIRING_CODE_LENGTH = 8;

/** An 8-character pairing code, ~3.9e11 possibilities. */
export function newPairingCode(): string {
  let code = "";
  for (let i = 0; i < PAIRING_CODE_LENGTH; i++) {
    code += CODE_ALPHABET[randomInt(CODE_ALPHABET.length)];
  }
  return code;
}

/** Uppercases and strips separators so "abcd-efgh" and "ABCDEFGH" match. */
export function normalizePairingCode(raw: string): string {
  return raw.toUpperCase().replace(/[\s-]/g, "");
}

export function formatPairingCode(code: string): string {
  return `${code.slice(0, 4)}-${code.slice(4)}`;
}

export function isPairingCode(code: string): boolean {
  return code.length === PAIRING_CODE_LENGTH && [...code].every((c) => CODE_ALPHABET.includes(c));
}

/** Codes and invite tokens are stored hashed, so a database read never reveals one. */
export function sha256(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

export function newToken(): string {
  return randomBytes(32).toString("base64url");
}

export function newDeviceId(): string {
  return `dev_${randomBytes(12).toString("hex")}`;
}

/**
 * PINs are keyed with a server-side secret (PIN_PEPPER) so they can be looked
 * up by value (a staff member types only their PIN) without the database
 * holding anything a leaked copy could brute-force offline.
 */
export function pinKey(pepper: string, orgId: string, pin: string): string {
  return createHmac("sha256", pepper).update(`${orgId}:${pin}`).digest("hex");
}
