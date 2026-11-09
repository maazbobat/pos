// Makes someone a platform admin in a real Firebase project, so they can sign
// in to the admin portal. Run it once per environment for the first admin.
// It uses your own Google sign-in (`gcloud auth application-default login`).
//
//   node functions/scripts/add-platform-admin.mjs --project <project-id> --email you@example.com
//
// If there's no account for that email yet, it creates one with a random
// password and prints it once. Keep it in a password manager; you can reset
// it from the Firebase console (Authentication → Users).
import { randomBytes } from "node:crypto";
import { parseArgs } from "node:util";
import { initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { FieldValue, getFirestore } from "firebase-admin/firestore";

const { values } = parseArgs({ options: { project: { type: "string" }, email: { type: "string" } } });
const projectId = values.project;
const email = values.email?.trim().toLowerCase();
if (!projectId || !email || !email.includes("@")) {
  console.error("Usage: node functions/scripts/add-platform-admin.mjs --project <project-id> --email <email>");
  process.exit(2);
}
if (projectId.startsWith("demo-")) {
  console.error("For the local emulators use `npm run seed:dev` instead.");
  process.exit(2);
}
if (process.env.FIRESTORE_EMULATOR_HOST || process.env.FIREBASE_AUTH_EMULATOR_HOST) {
  console.error("Unset FIRESTORE_EMULATOR_HOST and FIREBASE_AUTH_EMULATOR_HOST to reach a real project.");
  process.exit(2);
}

initializeApp({ projectId });
let password = null;
const user = await getAuth()
  .getUserByEmail(email)
  .catch(async (e) => {
    if (e.code !== "auth/user-not-found") throw e;
    password = randomBytes(12).toString("base64url");
    return getAuth().createUser({ email, password, emailVerified: true });
  });
await getFirestore()
  .doc(`platformAdmins/${user.uid}`)
  .set({ email, createdAt: FieldValue.serverTimestamp() }, { merge: true });
console.log(`${email} is a platform admin in ${projectId}.`);
if (password) console.log(`New account. Temporary password (shown once): ${password}`);
