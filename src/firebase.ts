import { initializeApp } from "firebase/app";
import { CustomProvider, initializeAppCheck } from "firebase/app-check";
import { firebaseConfig } from "./config";

/**
 * App Check debug token.
 *
 * App Check normally proves "this request came from my real app" with an
 * attestation the browser can't fake. A page on localhost can't produce one, so
 * for development we hand the SDK a *debug token* that is registered on the
 * project. App Check trades it for a real App Check token, which is what the AI
 * Logic API checks.
 *
 * Register one with:
 *   firebase appcheck:debugtokens:create --app <appId> --display-name local-dev
 * then put it in .env.local as VITE_APPCHECK_DEBUG_TOKEN.
 *
 * This has to run BEFORE initializeAppCheck() — that call reads the global once,
 * at startup. It is also guarded by import.meta.env.DEV so a production build
 * never contains it.
 */
if (import.meta.env.DEV) {
  // A string uses a token you already registered. `true` makes the SDK invent
  // one and log it to the console, so you can go register that one instead.
  (self as unknown as Record<string, unknown>).FIREBASE_APPCHECK_DEBUG_TOKEN =
    import.meta.env.VITE_APPCHECK_DEBUG_TOKEN || true;
}

export const app = initializeApp(firebaseConfig);

/**
 * initializeAppCheck() always wants a provider, but in debug mode the SDK never
 * calls it. We haven't set up reCAPTCHA Enterprise on this project yet, so this
 * placeholder just fails loudly if a non-debug build ever reaches it — better
 * than silently shipping an app that can't attest.
 *
 * To go to production: register the app under App Check in the Firebase console
 * with reCAPTCHA Enterprise, then replace this with
 *   new ReCaptchaEnterpriseProvider("<your site key>")
 * imported from "firebase/app-check".
 */
const provider = new CustomProvider({
  getToken: () =>
    Promise.reject(
      new Error(
        "No production App Check provider is configured yet. See src/firebase.ts.",
      ),
    ),
});

initializeAppCheck(app, {
  provider,
  // Keeps the App Check token fresh in the background so requests don't stall.
  isTokenAutoRefreshEnabled: true,
});
