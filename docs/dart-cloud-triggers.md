# AI Logic Cloud Triggers in Dart

For Flutter teams who don't want a TypeScript file in their repo.

Everything here was built and run against a live project. Where something is
unverified, it says so.

---

## The short version

**The Dart Functions SDK has no AI Logic trigger API.** There is no
`beforeGenerateContent` in Dart, and it is not on the published support table.

**You can still write the trigger in Dart**, because of one line in the Node
SDK's type definitions:

```typescript
export type BlockingFunction = HttpsFunction;
```

An AI Logic trigger *is* an HTTPS function. The Node helper only parses the
request body, calls your callback, and writes JSON back. And **HTTPS is the one
trigger type that is production-ready in Dart** — everything else is
emulator-only or experimental.

So you implement the wire contract with `onRequest`, and register the trigger
yourself.

| | Node | Dart |
| --- | --- | --- |
| Trigger helper | `beforeGenerateContent()` | none — use `https.onRequest` |
| Typed event | `AIBlockingEvent` | raw JSON maps |
| Registration | automatic on deploy | one REST call, by hand |
| Invoker IAM | automatic on deploy | already project-wide if you've deployed a Node trigger |

---

## The wire contract

Read from `firebase-functions/lib/v2/providers/ai/index.js`.

**Request** — POST, JSON body is the event:

```json
{
  "appId": "1:...:ios:...",
  "authType": "unauthenticated",
  "data": {
    "model": "projects/P/locations/global/publishers/google/models/gemini-3.6-flash",
    "api": "google.cloud.aiplatform.v1beta1",
    "request": { "contents": [ ... ], "generationConfig": { ... } }
  }
}
```

**Responses:**

| Intent | Status | Body |
| --- | --- | --- |
| Allow unchanged | 200 | `{}` |
| Modify | 200 | the **whole** modified object, plus an `@type` field |
| Reject | 500 | `{"code": <rpc code>, "message": "..."}` |

The `@type` values:

| Hook | API | `@type` |
| --- | --- | --- |
| before | Vertex | `type.googleapis.com/google.cloud.aiplatform.v1beta1.GenerateContentRequest` |
| before | Gemini Developer | `type.googleapis.com/google.ai.generativelanguage.v1beta.GenerateContentRequest` |
| after | Vertex | `type.googleapis.com/google.cloud.aiplatform.v1beta1.GenerateContentResponse` |
| after | Gemini Developer | `type.googleapis.com/google.ai.generativelanguage.v1beta.GenerateContentResponse` |

Common rpc codes: `3` = invalid-argument, `7` = permission-denied,
`9` = failed-precondition, `13` = internal.

---

## Step 1 — Enable the experiment

Dart Functions are experimental and hidden by default.

```bash
firebase experiments:enable dartfunctions
```

## Step 2 — Create the Dart codebase

You can run `firebase init functions` and pick Dart, or write the three files
directly. `functions-dart/pubspec.yaml`:

```yaml
name: ailogic_triggers
description: AI Logic Cloud Triggers written in Dart
version: 0.0.1
publish_to: none

environment:
  sdk: ^3.9.0

dependencies:
  firebase_functions: ^0.6.0

dev_dependencies:
  build_runner: ^2.4.0
  lints: ^6.0.0
```

> **`build_runner` is required, not optional.** The deploy runs it to generate
> the function manifest. Leave it out and the deploy fails with
> `build_runner failed with exit code 255`, which does not tell you that.

## Step 3 — Register the codebase

Multiple codebases live side by side in `firebase.json`, so a Dart trigger can
sit next to Node functions. Note `functions` becomes an **array**:

```json
{
  "functions": [
    { "source": "functions", "codebase": "default" },
    { "source": "functions-dart", "codebase": "dart" }
  ]
}
```

Deploy just one with `firebase deploy --only functions:dart`.

## Step 4 — Write the handler

`functions-dart/bin/server.dart`. Full version:
[`../functions-dart/bin/server.dart`](../functions-dart/bin/server.dart).

```dart
import 'dart:convert';
import 'package:firebase_functions/firebase_functions.dart';

const _vertexV1Beta1 = 'google.cloud.aiplatform.v1beta1';
const _vertexRequestType =
    'type.googleapis.com/google.cloud.aiplatform.v1beta1.GenerateContentRequest';

void main() {
  runFunctions((firebase) {
    firebase.https.onRequest(
      name: 'dartGuardStoryPrompts',
      (request) async {
        final event =
            jsonDecode(await request.readAsString()) as Map<String, dynamic>;
        final data = (event['data'] as Map?)?.cast<String, dynamic>() ?? {};

        if (data['api'] != _vertexV1Beta1) return _allow();

        final aiRequest =
            (data['request'] as Map?)?.cast<String, dynamic>() ?? {};

        final prompt = ((aiRequest['contents'] as List?) ?? [])
            .expand((c) => ((c as Map?)?['parts'] as List?) ?? [])
            .map((p) => ((p as Map?)?['text'] as String?) ?? '')
            .join(' ')
            .toLowerCase();

        if (prompt.contains('weapon')) {
          return Response(500,
              body: jsonEncode({'code': 3, 'message': 'Not allowed.'}),
              headers: {'content-type': 'application/json'});
        }

        // Image models return the picture as output tokens; a text cap
        // would truncate it.
        if ((data['model'] as String? ?? '').contains('image')) return _allow();

        return Response.ok(
          jsonEncode({
            ...aiRequest,
            'generationConfig': {
              ...?(aiRequest['generationConfig'] as Map?)?.cast<String, dynamic>(),
              'maxOutputTokens': 4000,
            },
            '@type': _vertexRequestType,
          }),
          headers: {'content-type': 'application/json'},
        );
      },
    );
  });
}

Response _allow() =>
    Response.ok('{}', headers: {'content-type': 'application/json'});
```

`Request` and `Response` are re-exported from
[`shelf`](https://pub.dev/packages/shelf), so `request.readAsString()` and
`Response.ok(...)` are the shelf APIs.

## Step 5 — Deploy

```bash
firebase deploy --only functions:dart
```

The CLI runs `build_runner`, compiles Dart to a linux-x64 executable, and
deploys it as a **Cloud Run** function:

```
i  functions: running build_runner...
i  functions: compiling Dart to linux-x64 executable...
✔  functions[dart:dart-guard-story-prompts(us-central1)] Successful create operation.
Function URL: https://dart-guard-story-prompts-....run.app
```

> **The deployed name is kebab-case.** `dartGuardStoryPrompts` in Dart becomes
> `dart-guard-story-prompts` as the function id. Use the kebab-case form when
> you register the trigger.

## Step 6 — Register the trigger yourself

This is the step the CLI does for you in Node and does not do in Dart: it has no
way to know your `onRequest` is meant to be an AI Logic trigger.

```bash
curl -X POST \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "x-goog-user-project: PROJECT_ID" \
  -H "Content-Type: application/json" \
  "https://firebasevertexai.googleapis.com/v1beta/projects/PROJECT_ID/locations/global/triggers?triggerId=before-generate-content" \
  -d '{"cloudFunction": {"id": "dart-guard-story-prompts", "locationId": "us-central1"}}'
```

Trigger ids are fixed: `before-generate-content` and `after-generate-content`.
If one already exists, `PATCH` it with `?updateMask=cloudFunction` instead of
POSTing.

Confirm:

```bash
curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "x-goog-user-project: PROJECT_ID" \
  "https://firebasevertexai.googleapis.com/v1beta/projects/PROJECT_ID/locations/global/triggers"
```

**IAM:** AI Logic invokes your function as
`service-PROJECT_NUMBER@gcp-sa-firebasevertexai.iam.gserviceaccount.com`. If
you have ever deployed a Node AI Logic trigger, the CLI already granted that
account `roles/run.invoker` at **project** level, which covers your Dart
function too. Starting from Dart only, grant it yourself:

```bash
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="serviceAccount:service-PROJECT_NUMBER@gcp-sa-firebasevertexai.iam.gserviceaccount.com" \
  --role="roles/run.invoker"
```

## Step 7 — Test it

You don't have to reroute live traffic to check your handler. POST a synthetic
event straight at the function:

```bash
URL="https://dart-guard-story-prompts-....run.app"
TOKEN=$(gcloud auth print-identity-token)

curl -s -X POST "$URL" -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -d '{
  "data": {
    "model": "projects/p/locations/global/publishers/google/models/gemini-3.6-flash",
    "api": "google.cloud.aiplatform.v1beta1",
    "request": {"contents":[{"role":"user","parts":[{"text":"A kind dragon"}]}],
                "generationConfig":{"temperature":0.9}}}}'
```

Verified results from the implementation above:

| Case | Result |
| --- | --- |
| Normal prompt | `200` — whole request returned, `temperature: 0.9` preserved, `maxOutputTokens: 4000` added, correct `@type` |
| `"forging a legendary weapon"` | `500 {"code":3,"message":"..."}` |
| Image model | `200 {}` |

This is a better first test than a live call: deterministic, instant, and it
can't break your app.

---

## Can you have more than one trigger per project?

**Yes — one global plus one per region, for each event type.** Verified.

The CLI's `validateTrigger` checks global and regional triggers in *separate*
groups, so they never conflict with each other. Deploying a global
`beforeGenerateContent` alongside a regional one succeeds:

```
✔  functions[guardStoryPrompts(us-east1)] Successful update operation.
✔  functions[regionalGuardExperiment(us-central1)] Successful create operation.
```

They register as distinct resources under different locations, with the *same*
trigger id:

```
locations/global/triggers/before-generate-content      -> guardStoryPrompts
locations/us-central1/triggers/before-generate-content -> regionalGuardExperiment
```

So the real limit is **one trigger per (event type, location)**.

## Which one goes first?

**Neither — they don't chain, and they don't race.** Only the trigger whose
location matches the AI Logic request fires.

Tested by deploying both, then making a real call from the Flutter app, which
uses `FirebaseAI.agentPlatform()` — location `global`:

| Trigger | Location | Invocations |
| --- | --- | --- |
| `guardStoryPrompts` | global | fired, twice (story + image) |
| `regionalGuardExperiment` | us-central1 | **0** |

The regional function's logs contained only deployment and startup lines — not
a single invocation. There is no ordering question because exactly one runs.

> **Practical warning.** A regional trigger is dead weight unless your models
> are actually served from that region. On the test project, every current
> Gemini 3.x model returns **404 at `us-central1`** and is only available at
> `global` — so the regional trigger could never fire, no matter what the app
> did. Check model availability for your region before deploying a regional
> trigger.

So: to intercept everything, use a **global** trigger. Reach for regional only
when you deliberately pin a client to a region and want region-specific logic.

---

## Should you use Dart for this?

Honest trade-offs.

**For:** one language across the stack; HTTPS is production-supported in Dart,
so this isn't riding an experimental trigger type.

**Against:**

- **No types.** Node gives you `VertexV1Beta1GenerateContentRequest`. In Dart
  you hand-walk JSON maps, and a typo in `'generationConfig'` fails silently.
- **You own registration.** No `firebase deploy` magic — and if you delete the
  function without unregistering the trigger, every Gemini call in the project
  fails.
- **Dart Functions are experimental** as a whole, behind a flag.
- **You still need the contract.** It is not documented anywhere public; the
  source of truth is the Node SDK's compiled JS.

**A reasonable middle ground:** your Flutter app is Dart, and your triggers are
two small server files. Triggers are per project, not per app — you write them
once and every client is covered. Keeping those two files in TypeScript buys
type safety and automatic registration for a very small amount of non-Dart code.

Use Dart when a single-language stack matters more than that. Both work.

---

## Reference

| Topic | URL |
| --- | --- |
| Dart Functions getting started | https://firebase.google.com/docs/functions/start-dart |
| Dart Functions announcement | https://firebase.blog/posts/2026/05/dart-functions-exp/ |
| `firebase_functions` package | https://pub.dev/packages/firebase_functions |
| Dart trigger support table | https://github.com/firebase/firebase-functions-dart/blob/main/doc/triggers.md |
| `shelf` (Request/Response) | https://pub.dev/packages/shelf |

Working code: [`../functions-dart/bin/server.dart`](../functions-dart/bin/server.dart).
The TypeScript equivalents are in [`../functions/src/index.ts`](../functions/src/index.ts).
