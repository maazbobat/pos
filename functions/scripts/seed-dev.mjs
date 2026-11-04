// Creates a platform admin in the local emulators so the apps can be tried
// end to end. Refuses to run unless both emulator hosts are set, so it can
// never touch a real project.
//
//   FIRESTORE_EMULATOR_HOST=127.0.0.1:8080 FIREBASE_AUTH_EMULATOR_HOST=127.0.0.1:9099 \
//     npm run seed:dev
import { initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { getFirestore, FieldValue } from "firebase-admin/firestore";

if (!process.env.FIRESTORE_EMULATOR_HOST || !process.env.FIREBASE_AUTH_EMULATOR_HOST) {
  console.error("Set FIRESTORE_EMULATOR_HOST and FIREBASE_AUTH_EMULATOR_HOST first.");
  process.exit(1);
}

initializeApp({ projectId: "demo-pos" });
const email = "admin@demo.test";
const password = "demo-admin";
const user = await getAuth()
  .getUserByEmail(email)
  .catch(() => getAuth().createUser({ email, password, emailVerified: true }));
await getFirestore().doc(`platformAdmins/${user.uid}`).set({ email, createdAt: FieldValue.serverTimestamp() });
console.log(`Platform admin ready: ${email} / ${password}`);
