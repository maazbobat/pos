import { HttpsError } from "firebase-functions/v2/https";

export const fail = {
  unauthenticated: (msg = "Sign in first.") => new HttpsError("unauthenticated", msg),
  denied: (msg = "You don't have permission to do that.") => new HttpsError("permission-denied", msg),
  invalid: (msg: string) => new HttpsError("invalid-argument", msg),
  notFound: (msg: string) => new HttpsError("not-found", msg),
  conflict: (msg: string) => new HttpsError("already-exists", msg),
  precondition: (msg: string) => new HttpsError("failed-precondition", msg),
  exhausted: (msg: string) => new HttpsError("resource-exhausted", msg),
};
