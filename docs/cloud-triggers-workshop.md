# Workshop: AI Logic Cloud Triggers

Add two server-side hooks to a Firebase AI Logic app — one that runs **before**
every model call and can rewrite or reject it, one that runs **after** and can
inspect or rewrite the response. They live in AI Logic, so a modified client
cannot skip them.

Every step below was run for real against a live project. The errors in the
second half are the ones that actually happened, in the order they happened.

**Time:** ~30 minutes, most of it waiting for the first deploy.

> **No public docs yet.** `firebase.google.com/docs/ai-logic` has no page on
> Cloud Triggers. The authority is the type definitions in
> `node_modules/firebase-functions/lib/v2/providers/ai/index.d.ts` and the
> Firebase CLI source. Where this guide states behaviour, it names the file that
> proves it.

---

## Step 1 — Check your prerequisites

- A Firebase project on the **Blaze** plan. Cloud Functions and image models both
  require billing.
- Firebase AI Logic already working in your app.
- Node.js 20+ and a current `firebase-tools`.

```bash
firebase --version
firebase use YOUR_PROJECT_ID
```

## Step 2 — Grant the build service account role

**Do this before anything else.** If your project has never built a Cloud
Function, this permission is missing and your first deploy fails with a message
that blames organization policies. See error 1.

```bash
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member=serviceAccount:PROJECT_NUMBER-compute@developer.gserviceaccount.com \
  --role=roles/cloudbuild.builds.builder
```

Check it landed:

```bash
gcloud projects get-iam-policy PROJECT_ID \
  --flatten="bindings[].members" \
  --filter="bindings.members:PROJECT_NUMBER-compute@developer.gserviceaccount.com" \
  --format="value(bindings.role)"
```

You want `roles/cloudbuild.builds.builder` in the output.

Also: **deploy as a project Owner.** The AI Logic IAM step is fail-soft — if it
can't set the policy it warns and continues, and you find out later.

## Step 3 — Create the functions codebase

```bash
mkdir -p functions/src && cd functions
npm init -y
npm install firebase-functions
npm install -D typescript
```

`firebase-admin` is only needed if a handler touches Firestore, Storage, or Auth.

Edit `functions/package.json` — `engines.node` picks the deployed runtime, and
`main` must point at compiled output:

```json
{
  "name": "story-studio-triggers",
  "private": true,
  "main": "lib/index.js",
  "engines": { "node": "22" },
  "scripts": { "build": "tsc" },
  "dependencies": { "firebase-functions": "^7.3.2" },
  "devDependencies": { "typescript": "^5.9.3" }
}
```

`functions/tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "outDir": "lib",
    "rootDir": "src",
    "strict": true,
    "skipLibCheck": true
  },
  "include": ["src"]
}
```

## Step 4 — Register the codebase in `firebase.json`

```json
{
  "functions": {
    "source": "functions",
    "codebase": "default",
    "ignore": ["node_modules", ".git", "firebase-debug.log", "*.local"],
    "predeploy": ["npm --prefix \"$RESOURCE_DIR\" run build"]
  }
}
```

`predeploy` runs `tsc` on every deploy so `lib/` is never stale. Add
`functions/lib/` to `.gitignore`.

## Step 5 — Write the "before" trigger

`functions/src/index.ts`:

```ts
import { logger } from "firebase-functions";
import {
  beforeGenerateContent,
  HttpsError,
  vertexV1Beta1,
  type VertexV1Beta1GenerateContentRequest,
} from "firebase-functions/v2/ai";

const BLOCKED_TOPICS = ["weapon", "explosive", "self-harm"];
const MAX_STORY_TOKENS = 4000;

export const guardStoryPrompts = beforeGenerateContent((event) => {
  // 1. Narrow to one API flavour before touching the request.
  if (event.data.api !== vertexV1Beta1) return;
  const request = event.data.request as VertexV1Beta1GenerateContentRequest;

  // 2. Read the prompt: contents[] -> parts[] -> text
  const prompt = (request.contents ?? [])
    .flatMap((c) => c.parts ?? [])
    .map((p) => ("text" in p ? p.text : "") ?? "")
    .join(" ")
    .toLowerCase();

  // 3. Throwing rejects the call. The model never runs.
  const blocked = BLOCKED_TOPICS.find((t) => prompt.includes(t));
  if (blocked) {
    logger.warn("Blocked a prompt", { topic: blocked });
    throw new HttpsError("invalid-argument", `We don't write about ${blocked}.`);
  }

  logger.info("Allowing generation", {
    model: event.data.model,
    authType: event.authType,
    authId: event.authId,
    appId: event.appId,
  });

  // 4. Image models return the picture as tokens — a text cap truncates it.
  if (event.data.model.includes("image")) return;

  // 5. Return the WHOLE request, edited. Returning nothing leaves it untouched.
  return {
    ...request,
    generationConfig: {
      ...request.generationConfig,
      maxOutputTokens: Math.min(
        request.generationConfig?.maxOutputTokens ?? MAX_STORY_TOKENS,
        MAX_STORY_TOKENS,
      ),
    },
  };
});
```

Five things to understand, matching the numbered comments:

1. **Narrow on `event.data.api`.** AI Logic speaks two API flavours (Gemini
   Developer API and Vertex AI). `event.data.request` is a union of their types,
   and TypeScript refuses to spread it. See error 8.
2. A request is `contents[] → parts[]`, and a part may be text, inline data, or a
   function call. `"text" in p` skips the non-text ones.
3. **Throwing rejects the call** — this is the part a modified client cannot skip.
4. **Your trigger sees every model in the project.** See error 5.
5. **Return the whole request.** See error 6.

## Step 6 — Write the "after" trigger

```ts
import {
  afterGenerateContent,
  type VertexV1Beta1GenerateContentResponse,
} from "firebase-functions/v2/ai";

export const recordGenerationUsage = afterGenerateContent((event) => {
  if (event.data.api !== vertexV1Beta1) return;
  const response = event.data.response as VertexV1Beta1GenerateContentResponse;

  logger.info("Generation finished", {
    model: event.data.model,
    promptTokens: response.usageMetadata?.promptTokenCount,
    totalTokens: response.usageMetadata?.totalTokenCount,
    finishReason: response.candidates?.[0]?.finishReason,
  });
});
```

Returning nothing leaves the response untouched. To rewrite it, return a
response object the same way the before hook returns a request.

**What's on the event** (from `index.d.ts`):

| Field | Meaning |
| --- | --- |
| `event.authType` | `"app_user"` \| `"unauthenticated"` \| `"unknown"` |
| `event.authId` | caller's uid, when there is one |
| `event.appId` | which Firebase app called |
| `event.data.model` | full resource path — see error 4 |
| `event.data.api` | which API flavour |
| `event.data.template` | server prompt template info, if used |

Build it:

```bash
npm --prefix functions run build
```

## Step 7 — Make the client use unary calls

**Cloud Triggers do not fire on `generateContentStream()`.**

This is the most important line in this guide. Streaming works perfectly and your
hooks silently never run.

```ts
// ❌ Hooks never fire
const { stream } = await model.generateContentStream(prompt);
for await (const chunk of stream) { /* ... */ }

// ✅
const result = await model.generateContent(prompt);
const text = result.response.text();
```

You lose the typewriter effect. You gain rules that actually apply.

## Step 8 — Deploy

```bash
firebase deploy --only functions --force
```

`--force` accepts an artifact cleanup policy so container images don't
accumulate and bill you.

The first deploy enables about six APIs (`cloudfunctions`, `cloudbuild`,
`artifactregistry`, `run`, `eventarc`, `firebaseextensions`) and takes several
minutes. You do **not** need to enable them yourself.

You also don't need to grant the AI Logic invoker role — the CLI does it, from
`requiredProjectBindings` in `src/deploy/functions/services/ailogic.ts`. It
grants `roles/run.invoker` to
`service-PROJECT_NUMBER@gcp-sa-firebasevertexai.iam.gserviceaccount.com`, the
AI Logic proxy that calls your function.

Expect:

```
✔  functions[guardStoryPrompts(us-east1)] Successful update operation.
✔  functions[recordGenerationUsage(us-east1)] Successful update operation.
✔  Deploy complete!
```

**Note the region.** Global AI Logic triggers deploy to `us-east1`, not
`us-central1`.

## Step 9 — Verify the deploy

Two separate checks. Do both — the functions existing and the triggers being
registered are different things.

**A. The functions are really running.** Don't use `firebase functions:list` for
this; see error 2.

```bash
gcloud functions describe guardStoryPrompts --region=us-east1 --format='value(state)'
gcloud functions describe recordGenerationUsage --region=us-east1 --format='value(state)'
```

Both must print `ACTIVE`.

**B. AI Logic is actually calling them.**

```bash
curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  -H "x-goog-user-project: PROJECT_ID" \
  "https://firebasevertexai.googleapis.com/v1beta/projects/PROJECT_ID/locations/global/triggers"
```

Expect both triggers, each naming its function:

```json
{"triggers": [
  {"name": ".../triggers/before-generate-content",
   "cloudFunction": {"id": "guardStoryPrompts", "locationId": "us-east1"}},
  {"name": ".../triggers/after-generate-content",
   "cloudFunction": {"id": "recordGenerationUsage", "locationId": "us-east1"}}
]}
```

An empty `{}` means the functions exist but nothing is calling them.

## Step 10 — Test all three paths

An app that works is **not** evidence your trigger fired. Read the logs.

**1. A normal request.** Use your app, then:

```bash
firebase functions:log --only recordGenerationUsage
```

```
{"message":"Generation finished","promptTokens":73,"totalTokens":1121,"finishReason":"STOP"}
```

**2. A blocked request.** Send a prompt containing one of your blocked topics.
The request should fail, and:

```bash
firebase functions:log --only guardStoryPrompts
```

```
{"message":"Blocked a prompt","topic":"weapon"}
```

**3. An image request**, if your app generates images. Confirm the picture
renders fully and `finishReason` is `STOP`, not `MAX_TOKENS`. This is the path
that breaks quietly.

---

# Common errors and workarounds

## 1. `Build failed ... missing permission on the build service account`

```
Build failed with status: FAILURE. Could not build the function due to a missing
permission on the build service account. If you didn't revoke that permission
explicitly, this could be caused by a change in the organization policies.
```

**Cause.** Cloud Functions v2 builds run as the **default compute** service
account, `PROJECT_NUMBER-compute@developer.gserviceaccount.com`. Cloud Build
changed its default service account behaviour, and on newer projects that account
no longer receives the builder role automatically.

The confusing part: `roles/cloudbuild.builds.builder` probably *is* in your IAM
policy — on `PROJECT_NUMBER@cloudbuild.gserviceaccount.com`, the legacy account
that is no longer used for the build.

**Fix.** Step 2.

There is no config workaround — the Firebase CLI has no setting to point a
functions build at a different service account. `buildServiceAccount` exists only
for App Hosting.

**Source.** https://docs.cloud.google.com/functions/docs/troubleshooting,
"Build service account". (The link the CLI prints, `cloud.google.com/...`,
301-redirects there.)

## 2. `functions:list` shows your functions, but they don't work

After a failed build, this looks like success:

```
guardStoryPrompts      v2  google.firebase.ailogic.v1.beforeGenerate  us-east1  ---  nodejs22
```

It isn't. The function metadata was created; the build failed; there's no Cloud
Run service behind it. The only hint is `---` in the Memory column.

```
[ERROR] Cloud Run service .../services/guardstoryprompts for the function was
not found. The function will not work correctly. Please redeploy.
```

**Workaround.** Verify with `gcloud functions describe`, not `functions:list`
(step 9A). A redeploy repairs the shells in place — no cleanup needed; the log
will say `updating` rather than `creating`.

**Good news:** trigger registration happens only after the functions are healthy,
so broken shells are never wired to AI Logic. Your app keeps working.

## 3. The triggers never fire, and nothing errors

Everything deploys, the app works, the logs stay empty.

**Cause.** The client is using `generateContentStream()`. Triggers only fire on
unary `generateContent()`.

**Fix.** Step 7. There is no warning for this — you have to know.

## 4. A model comparison never matches

```ts
if (event.data.model === "gemini-3.1-flash-image") { /* never true */ }
```

**Cause.** `event.data.model` is a full resource path:

```
projects/PROJECT_ID/locations/global/publishers/google/models/gemini-3.6-flash
```

**Fix.** Use `.includes()`, or parse the last path segment.

## 5. The generated image is truncated or missing

**Cause.** A global trigger intercepts **every** model call in the project,
including image generation. Image models return the picture as output tokens, so
a `maxOutputTokens` cap written for text truncates it.

Confirmed in the logs — both models hit the same hook:

```
{"message":"Allowing generation","model":".../gemini-3.6-flash"}
{"message":"Allowing generation","model":".../gemini-3.1-flash-image"}
```

**Fix.** Exempt image models before applying any text-shaped limit:

```ts
if (event.data.model.includes("image")) return;
```

## 6. Your request edits get lost, or overwrite settings

**Cause.** Returning a partial request. The SDK posts whatever you return
straight to AI Logic (`lib/v2/providers/ai/index.js`), and the merge happens
server-side with undocumented semantics.

**Fix.** Return the whole request, edited, and spread nested objects you're
modifying:

```ts
return {
  ...request,
  generationConfig: { ...request.generationConfig, maxOutputTokens: 4000 },
};
```

Return nothing at all to leave the request untouched.

## 7. The user sees `500 Internal error`, not your message

You throw:

```ts
throw new HttpsError("invalid-argument", "We don't write about weapons.");
```

The function logs exactly that, with `code: 'invalid-argument'`. The client gets:

```
[500 ] Internal error encountered. (AI/fetch-error)
```

**Cause.** The message does not propagate through AI Logic to the client. The
block works — the model never ran — but the reason stays in your logs.

**Workaround.** Don't write rejection text for end users. If the app must
explain itself, pre-validate on the client for the *message* and let the trigger
provide the *guarantee*.

Related: your deliberate throw is logged as `Unhandled error: HttpsError: ...`.
That's the SDK's own catch-block wording, not a bug — but it means an intentional
block looks identical to a crash.

## 8. TypeScript won't let you spread the request

```
Type 'SchemaType.STRING' is not assignable to type 'SchemaType | undefined'
```

**Cause.** `event.data.request` is a union of the Gemini and Vertex request
types. They're structurally similar but their `SchemaType` enums are separate
declarations, so the union won't spread.

**Fix.** Narrow on `event.data.api` first, then cast once:

```ts
if (event.data.api !== vertexV1Beta1) return;
const request = event.data.request as VertexV1Beta1GenerateContentRequest;
```

## 9. `event.auth` is undefined

**Cause.** SDK version drift. In `firebase-functions` 7.2.x the event had
`event.auth.uid` and `event.data.template.id`. In 7.3.x these are
`event.authId` and `event.data.template.templateName`.

Old code compiles fine and reads `undefined` forever — so a permission check
written against `event.auth?.uid` silently never fires.

**Fix.** Open the type definitions for the version you actually installed:
`node_modules/firebase-functions/lib/v2/providers/ai/index.d.ts`. With no public
docs, that file is the spec.

## 10. `Error: Functions successfully deployed but could not set up cleanup policy`

Printed after a deploy where nothing deployed successfully. The cleanup-policy
check runs regardless of outcome and hardcodes the success wording.

**Workaround.** Ignore it when the deploy above it failed. Read the
`functions[...]` lines instead.

The underlying warning is real, though — set a policy with `--force` on deploy or
`firebase functions:artifacts:setpolicy`, or container images accumulate.

## 11. `Can only create at most one global AI Logic Trigger for <event>`

**Cause.** There is one global trigger per event type per project. A second
function claiming `beforeGenerateContent` is rejected.

**Fix.** Put your logic in the one function, or switch to regional webhooks:

```ts
beforeGenerateContent({ regionalWebhook: true }, (event) => { /* ... */ });
```

---

## Reference

| Topic | URL |
| --- | --- |
| Firebase AI Logic | https://firebase.google.com/docs/ai-logic |
| App Check with AI Logic | https://firebase.google.com/docs/ai-logic/app-check |
| AI Logic locations | https://firebase.google.com/docs/ai-logic/locations |
| Model list | https://firebase.google.com/docs/ai-logic/models |
| AI Logic FAQ | https://firebase.google.com/docs/ai-logic/faq-and-troubleshooting |
| Cloud Functions | https://firebase.google.com/docs/functions |
| Cloud Functions troubleshooting | https://docs.cloud.google.com/functions/docs/troubleshooting |

Working code: [`functions/src/index.ts`](../functions/src/index.ts).
