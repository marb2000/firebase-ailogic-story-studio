/**
 * Firebase config, read from `.env.local`.
 *
 * None of these values are secret — a web app has to ship its project
 * identifiers to the browser, and you can read them in any Firebase site's
 * bundle. They live in `.env.local` rather than in this file so the repo isn't
 * tied to one project: copy `.env.example`, drop in your own, and the app is
 * yours.
 *
 * Get your values with:
 *   firebase apps:sdkconfig WEB
 */
export const firebaseConfig = {
  apiKey: import.meta.env.VITE_FIREBASE_API_KEY,
  authDomain: import.meta.env.VITE_FIREBASE_AUTH_DOMAIN,
  projectId: import.meta.env.VITE_FIREBASE_PROJECT_ID,
  storageBucket: import.meta.env.VITE_FIREBASE_STORAGE_BUCKET,
  messagingSenderId: import.meta.env.VITE_FIREBASE_MESSAGING_SENDER_ID,
  appId: import.meta.env.VITE_FIREBASE_APP_ID,
};

// Fail with something readable instead of a confusing Firebase error later on.
if (!firebaseConfig.apiKey || !firebaseConfig.projectId) {
  throw new Error(
    "Firebase config is missing. Copy .env.example to .env.local and fill it in — see the README.",
  );
}
