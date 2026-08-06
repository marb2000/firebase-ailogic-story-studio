import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import 'firebase_options.dart';

/// App Check debug tokens, supplied at build time.
///
/// Pass them with `--dart-define` so they never live in source control:
///
///   flutter run \
///     --dart-define=APPCHECK_DEBUG_TOKEN_IOS=... \
///     --dart-define=APPCHECK_DEBUG_TOKEN_ANDROID=...
///
/// Create one per app with:
///
///   firebase appcheck:debugtokens:create --app APP_ID --display-name local-dev
const _iosDebugToken = String.fromEnvironment('APPCHECK_DEBUG_TOKEN_IOS');
const _androidDebugToken = String.fromEnvironment('APPCHECK_DEBUG_TOKEN_ANDROID');

/// Starts Firebase and App Check.
///
/// App Check proves a request came from your real app. Firebase enforces it on
/// AI Logic by default, so without this every `generateContent` call is
/// rejected with a 401.
///
/// ## Why debug providers
///
/// A simulator or an emulator cannot produce a real attestation — App Attest
/// and Play Integrity both require a genuine, signed app. So debug builds use
/// the *debug provider* for each platform, handing it a token you registered on
/// the project ahead of time.
///
/// Passing the token explicitly (rather than letting the SDK invent one and
/// print it to the console) means a fresh simulator works on the first run,
/// with no copy-paste step.
///
/// Release builds get the real attestation providers and never see a token.
Future<void> initializeFirebase() async {
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  await FirebaseAppCheck.instance.activate(
    providerApple: kDebugMode
        ? const AppleDebugProvider(debugToken: _iosDebugToken)
        : const AppleAppAttestProvider(),
    providerAndroid: kDebugMode
        ? const AndroidDebugProvider(debugToken: _androidDebugToken)
        : const AndroidPlayIntegrityProvider(),
  );
}
