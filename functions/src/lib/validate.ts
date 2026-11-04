import { fail } from "./errors.js";

/** Input from a client: never trusted, always checked field by field. */
export type Input = Record<string, unknown>;

export function asInput(data: unknown): Input {
  if (typeof data !== "object" || data === null || Array.isArray(data)) {
    throw fail.invalid("Expected an object.");
  }
  return data as Input;
}

export function str(input: Input, key: string, opts: { min?: number; max?: number } = {}): string {
  const value = input[key];
  const min = opts.min ?? 1;
  const max = opts.max ?? 200;
  if (typeof value !== "string") throw fail.invalid(`${key} must be a string.`);
  const trimmed = value.trim();
  if (trimmed.length < min || trimmed.length > max) {
    throw fail.invalid(`${key} must be ${min}-${max} characters.`);
  }
  return trimmed;
}

export function optStr(input: Input, key: string, opts: { max?: number } = {}): string | null {
  if (input[key] === undefined || input[key] === null || input[key] === "") return null;
  return str(input, key, { min: 1, max: opts.max });
}

export function oneOf<T extends string>(input: Input, key: string, allowed: readonly T[]): T {
  const value = input[key];
  if (typeof value !== "string" || !(allowed as readonly string[]).includes(value)) {
    throw fail.invalid(`${key} must be one of: ${allowed.join(", ")}.`);
  }
  return value as T;
}

/** A Firestore document ID: no slashes, no dots-only, bounded length. */
export function docId(input: Input, key: string): string {
  const value = str(input, key, { max: 128 });
  if (!/^[A-Za-z0-9_-]+$/.test(value)) throw fail.invalid(`${key} is not a valid ID.`);
  return value;
}

export function email(input: Input, key: string): string {
  const value = str(input, key, { min: 3, max: 254 }).toLowerCase();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value)) throw fail.invalid(`${key} is not a valid email.`);
  return value;
}
