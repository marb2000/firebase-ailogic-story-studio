# Story Studio — Flutter

The same app as the web sample in the repo root, in Flutter. Give it a topic and
a length: Gemini writes the story, Nano Banana illustrates it, and you can
regenerate the picture.

It talks to the **same Firebase project** as the web version, which means it is
already subject to the project's AI Logic Cloud Triggers — without a single line
of trigger-aware code. See [the workshop](../docs/) for why.

## Setup

```bash
flutter pub get
flutterfire configure --project=YOUR_PROJECT_ID --platforms=ios,android
```

`flutterfire configure` registers the iOS and Android apps and writes
`lib/firebase_options.dart` plus the native config files. Those are gitignored,
so every clone points at its own project.

> **iOS deployment target.** Firebase requires iOS 15.0+, and Flutter's template
> still ships 13.0. If the build fails with *"requires minimum platform version
> 15.0"*, bump `IPHONEOS_DEPLOYMENT_TARGET` in
> `ios/Runner.xcodeproj/project.pbxproj`.

### App Check debug tokens

App Check is enforced on AI Logic, and a simulator can't produce a real
attestation. Create a debug token per app:

```bash
firebase appcheck:debugtokens:create --app YOUR_IOS_APP_ID --display-name local-dev
firebase appcheck:debugtokens:create --app YOUR_ANDROID_APP_ID --display-name local-dev
```

Then pass them at build time — they never go in source control:

```bash
flutter run \
  --dart-define=APPCHECK_DEBUG_TOKEN_IOS=... \
  --dart-define=APPCHECK_DEBUG_TOKEN_ANDROID=...
```

[`lib/firebase_setup.dart`](lib/firebase_setup.dart) hands each token to the
platform's debug provider:

```dart
providerApple: kDebugMode
    ? const AppleDebugProvider(debugToken: _iosDebugToken)
    : const AppleAppAttestProvider(),
providerAndroid: kDebugMode
    ? const AndroidDebugProvider(debugToken: _androidDebugToken)
    : const AndroidPlayIntegrityProvider(),
```

Passing the token explicitly beats letting the SDK invent one and print it to
the console: a fresh simulator works on the first run, with no copy-paste step.
Release builds get the real attestation providers and never see a token.

> Use `providerApple` / `providerAndroid`. The older `appleProvider` /
> `androidProvider` parameters are deprecated and take enums instead of these
> provider classes.

## The code

| File | Role |
| --- | --- |
| [`lib/ai_service.dart`](lib/ai_service.dart) | The only file that talks to AI Logic |
| [`lib/firebase_setup.dart`](lib/firebase_setup.dart) | Firebase + App Check startup |
| [`lib/main.dart`](lib/main.dart) | UI |

Both models go through the same `generateContent` call — the image model just
asks for an image response modality:

```dart
final _ai = FirebaseAI.agentPlatform();          // defaults to location "global"

_ai.generativeModel(model: 'gemini-3.6-flash');  // story

_ai.generativeModel(                             // illustration
  model: 'gemini-3.1-flash-image',
  generationConfig: GenerationConfig(
    responseModalities: [ResponseModalities.image],
  ),
);
```

`FirebaseAI.agentPlatform()` is the Agent Platform Gemini API (formerly Vertex
AI). Use it rather than the deprecated `FirebaseAI.vertexAI()` — besides the
rename, `agentPlatform` defaults to the `global` location, which is where the
newest Gemini models are available. A pinned region like `us-central1` returns
404 for them.

Calls are **unary, never streamed**. Cloud Triggers don't fire on
`generateContentStream`, so streaming would quietly bypass them.

## Tests

```bash
flutter test                       # unit tests, no Firebase needed
flutter test integration_test/ -d <simulator-udid> \
  --dart-define=APPCHECK_DEBUG_TOKEN_IOS=...
```

The integration tests run against live AI Logic. The second one asks for a story
about a *weapon* and expects it to fail — the blocklist lives in a Cloud
Function deployed to the project, not in this app.
