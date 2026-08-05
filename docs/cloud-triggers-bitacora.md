# Bitácora: adding AI Logic Cloud Triggers to Story Studio

A running log of everything it took to get two AI Logic blocking functions from
nothing to deployed, written as it happened. Commands, code, the reasoning, and
what broke.

---

## Checklist: how to not lose an afternoon

Ordered by when it bites you. Everything here is something that actually
happened in this log.

### Before you write any code

1. **Blaze plan.** Cloud Functions and image models both require it.
2. **Grant the build service account role — *before* the first deploy.**

   ```bash
   gcloud projects add-iam-policy-binding PROJECT_ID \
     --member=serviceAccount:PROJECT_NUMBER-compute@developer.gserviceaccount.com \
     --role=roles/cloudbuild.builds.builder
   ```

   On a project that has never built a Cloud Function, this is missing and the
   build fails with a message that sounds like an org-policy problem. It is the
   single most likely thing to stop you. Issue 1.
3. **Deploy as a project Owner.** The AI Logic IAM step is *fail-soft* — if it
   cannot set the policy it prints a warning and continues, and you find out
   later when calls fail.

### While writing the handler

4. **Open the `.d.ts` for the version you installed:**
   `node_modules/firebase-functions/lib/v2/providers/ai/index.d.ts`. There is no
   public documentation for this feature. The provider changed shape between
   7.2.x and 7.3.x — `event.auth.uid` → `event.authId`,
   `event.data.template.id` → `.templateName` — and stale code compiles fine and
   reads `undefined`.
5. **Narrow on `event.data.api` first.** `request` and `response` are unions of
   the Gemini and Vertex types; the union will not spread.
6. **`event.data.model` is a full resource path**, not `"gemini-3.6-flash"`.
   Use `.includes()`, never `===`.
7. **Return the whole request, not a partial.** Merge semantics are undocumented;
   returning the complete object is correct either way.
8. **Your trigger sees every model in the project**, image models included. A
   token cap written for text will truncate an image response.
9. **Do not write rejection messages for end users.** A thrown `HttpsError`
   reaches the client as a generic 500; the message stays in the logs.

### On the client

10. **Unary `generateContent()` only.** Triggers do not fire on
    `generateContentStream()`. Streaming works perfectly and your hooks silently
    never run — no error, no warning.

### Deploying

11. **Expect the first deploy to be slow.** It enables ~6 APIs.
12. **Do not trust `firebase functions:list`.** After a failed build it happily
    lists both functions with correct triggers and runtime. Confirm with:

    ```bash
    gcloud functions describe FUNCTION --region REGION --format='value(state)'
    ```

    Anything other than `ACTIVE` means it is not really there.
13. **Confirm the triggers actually registered**, which is a separate step from
    the functions existing:

    ```bash
    curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
      -H "x-goog-user-project: PROJECT_ID" \
      "https://firebasevertexai.googleapis.com/v1beta/projects/PROJECT_ID/locations/global/triggers"
    ```

    An empty `{}` means the functions exist but AI Logic is not calling them.
14. **Pass `--force`** (or run `firebase functions:artifacts:setpolicy`) to set an
    artifact cleanup policy, or container images accumulate and bill you.
15. **Ignore the trailing "Functions successfully deployed but could not set up
    cleanup policy" error** when the deploy above it failed. The wording is
    hardcoded and wrong. Issue 2.

### Testing

16. Test **all three** paths: a normal request, a blocked request, and an image
    request. The image path is the one that silently breaks.
17. Read the logs to confirm the hooks ran, not just that the app worked. An app
    that works is not evidence the trigger fired — that is exactly the streaming
    failure mode.

### Region

18. Global AI Logic triggers deploy to **`us-east1`**, not `us-central1`, and
    there is **one per event type per project**. Use
    `{ regionalWebhook: true }` if you need one per region.

---

## 0. A note on sources

**AI Logic Cloud Triggers have no public documentation yet.** I checked:
`firebase.google.com/docs/ai-logic` has no page on triggers, blocking functions,
`beforeGenerateContent`, or `afterGenerateContent`, and a site-scoped search
turns up nothing.

So the authority for this feature is, in order:

1. **The `firebase-functions` type definitions** —
   `node_modules/firebase-functions/lib/v2/providers/ai/index.d.ts`. This is
   generated from the SDK source and is the contract.
2. **The Firebase CLI source** — `src/deploy/functions/services/ailogic.ts` and
   `src/gcp/ailogic.ts` describe exactly what deployment does.

Official docs that *are* published and do apply:

| Topic | URL |
| --- | --- |
| Firebase AI Logic | https://firebase.google.com/docs/ai-logic |
| App Check with AI Logic | https://firebase.google.com/docs/ai-logic/app-check |
| AI Logic locations | https://firebase.google.com/docs/ai-logic/locations |
| Model list | https://firebase.google.com/docs/ai-logic/models |
| FAQ / troubleshooting | https://firebase.google.com/docs/ai-logic/faq-and-troubleshooting |
| Cloud Functions for Firebase | https://firebase.google.com/docs/functions |

Where this doc states a behaviour with no public source, it says so and points
at the file that proves it.

---

## 1. Prerequisites

- Blaze billing. Not optional — Cloud Functions and image models both require it.
- Firebase AI Logic already working in the app (see the main README).
- Node 20+ locally. The deployed runtime is pinned separately, below.

---

## 2. The library

Cloud Triggers live in `firebase-functions`, not in a separate package.

```bash
cd functions
npm install firebase-functions
```

Installed: **7.3.2**, the current stable.

The AI provider is reachable at two import paths that resolve to the same
module:

```ts
import { beforeGenerateContent } from "firebase-functions/v2/ai";  // used here
import { beforeGenerateContent } from "firebase-functions/ai";      // also valid
```

> **Version warning.** The AI provider changed shape between 7.2.x and 7.3.x.
> `event.auth.uid` became `event.authId`, and `event.data.template.id` became
> `event.data.template.templateName`. Code written against the preview compiles
> fine and silently reads `undefined`. Verify against
> `lib/v2/providers/ai/index.d.ts` in whatever version you actually installed.

`firebase-admin` is **not** needed unless a handler touches Firestore, Storage,
or Auth. Ours don't.

---

## 3. Scaffold

`functions/package.json` — the important field is `engines.node`, which picks
the deployed runtime:

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

`main` points at compiled JS, so `tsc` must run before deploy. That is wired up
in the next step.

`functions/tsconfig.json` uses `"module": "NodeNext"` and emits to `lib/`.

---

## 4. Tell the CLI the functions exist

`firebase.json`:

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

`predeploy` runs the TypeScript build automatically on every deploy, so
`lib/` is never stale. `lib/` is gitignored.

---

## 5. The code

Full file: [`functions/src/index.ts`](../functions/src/index.ts). Explained in
pieces.

### 5.1 Imports

```ts
import { logger } from "firebase-functions";
import {
  afterGenerateContent,
  beforeGenerateContent,
  HttpsError,
  vertexV1Beta1,
  type VertexV1Beta1GenerateContentRequest,
  type VertexV1Beta1GenerateContentResponse,
} from "firebase-functions/v2/ai";
```

`vertexV1Beta1` is the constant `"google.cloud.aiplatform.v1beta1"`. It matters
because of the next point.

### 5.2 Why every handler narrows on `event.data.api`

AI Logic speaks two API flavours: the Gemini Developer API
(`geminiV1Beta`) and Vertex AI (`vertexV1Beta1`). `event.data.request` is a
**union** of their two request types.

Those types are structurally similar but not identical — their `SchemaType`
enums are separate declarations — so TypeScript refuses to spread the union:

```
Type 'SchemaType.STRING' is not assignable to type 'SchemaType | undefined'
```

Narrowing first makes the whole handler concrete:

```ts
if (event.data.api !== vertexV1Beta1) {
  return;
}
const request = event.data.request as VertexV1Beta1GenerateContentRequest;
```

Story Studio always uses the Vertex backend, so the early return never fires in
practice. It is the place to add a branch if you ever add the Developer API.

### 5.3 Reading the prompt

```ts
function promptText(request: VertexV1Beta1GenerateContentRequest): string {
  return (request.contents ?? [])
    .flatMap((content) => content.parts ?? [])
    .map((part) => ("text" in part ? part.text : "") ?? "")
    .join(" ")
    .toLowerCase();
}
```

A request is `contents[] → parts[]`, and a part may be text, inline data, a
function call, and so on. `"text" in part` skips the non-text ones.

### 5.4 `beforeGenerateContent` — the guard

```ts
export const guardStoryPrompts = beforeGenerateContent((event) => {
  // ...narrowing from 5.2...

  const blocked = BLOCKED_TOPICS.find((topic) => promptText(request).includes(topic));
  if (blocked) {
    throw new HttpsError("invalid-argument", `Story Studio doesn't write about ${blocked}.`);
  }
```

**Throwing rejects the call.** The client's `generateContent()` promise
rejects and the app shows its error bar. This is the part you cannot do in
client code — a modified client would just skip it.

```ts
  if (event.data.model.includes("image")) {
    return;
  }

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

Three things worth calling out.

**Return the whole request, not a partial.** The SDK posts whatever you return
straight back to AI Logic
(`lib/v2/providers/ai/index.js`, `const responseBody = result || {}`), and the
merge happens server-side where the semantics are not documented. Returning the
complete edited request is correct whether the merge is shallow or deep.
Returning nothing leaves the request untouched.

**The image model is exempt from the token cap.** This is the subtle one. A
global trigger sees *every* `generateContent()` in the project, and
`gemini-3.1-flash-image` returns its picture as output tokens. A 4000-token
text ceiling would truncate the image. Hence the `model.includes("image")` bail.

**The cap is a cost control that the client cannot raise.** `Math.min` means a
client asking for 50,000 tokens still gets 4,000.

### 5.5 `afterGenerateContent` — the observer

```ts
export const recordGenerationUsage = afterGenerateContent((event) => {
  const response = event.data.response as VertexV1Beta1GenerateContentResponse;
  const usage = response.usageMetadata;

  logger.info("Generation finished", {
    model: event.data.model,
    promptTokens: usage?.promptTokenCount,
    totalTokens: usage?.totalTokenCount,
    finishReason: response.candidates?.[0]?.finishReason,
  });
});
```

Returning nothing leaves the response untouched. This one only watches. It could
rewrite the response by returning a partial, same as the before hook.

### 5.6 The event object

From `index.d.ts`, `AIBlockingEvent` carries, alongside `data`:

| Field | Meaning |
| --- | --- |
| `authType` | `"app_user"` \| `"unauthenticated"` \| `"unknown"` |
| `authId` | the caller's uid, when there is one |
| `authClaims` | custom claims |
| `appId`, `displayName` | which Firebase app called |
| `androidPackageName`, `iosBundleId` | mobile callers |

`event.data` carries `model`, `api`, `request`, `template` (for server prompt
templates), and on the after event, `response`.

---

## 6. The client has to stop streaming

**Cloud Triggers do not fire on `generateContentStream()`.**

This is the single most important constraint and it is invisible: streaming
works perfectly, the triggers just never run. Every guarantee the before hook
provides silently disappears.

So the story call changed from streaming to unary:

```ts
// Before — nice typewriter effect, hooks never fire
const { stream } = await storyModel.generateContentStream(prompt);
for await (const chunk of stream) { /* ... */ }

// After
const result = await storyModel.generateContent(prompt);
return result.response.text();
```

The cost is the progressive reveal. The gain is that the rules actually apply.

---

## 7. Deploy

```bash
firebase deploy --only functions
```

No IAM or API setup beforehand — the CLI does it. See section 8 for what it
actually did.

### Attempt 1 — failed at the build step

```
i  functions: ensuring required API cloudfunctions.googleapis.com is enabled...
⚠  functions: missing required API cloudfunctions.googleapis.com. Enabling now...
⚠  functions: missing required API cloudbuild.googleapis.com. Enabling now...
⚠  artifactregistry: missing required API artifactregistry.googleapis.com. Enabling now...
⚠  extensions: missing required API firebaseextensions.googleapis.com. Enabling now...
⚠  functions: missing required API eventarc.googleapis.com. Enabling now...
⚠  functions: missing required API run.googleapis.com. Enabling now...
i  functions: generating the service identity for pubsub.googleapis.com...
i  functions: generating the service identity for eventarc.googleapis.com...
✔  functions: functions source uploaded successfully
i  functions: creating Node.js 22 (2nd Gen) function guardStoryPrompts(us-east1)...
i  functions: creating Node.js 22 (2nd Gen) function recordGenerationUsage(us-east1)...
Build failed with status: FAILURE. Could not build the function due to a missing
permission on the build service account.
⚠  functions: Deploys failed. Skipping deletes.
```

Three things this confirms even though it failed:

1. **Six APIs were enabled automatically**, as section 8 predicted. No manual
   `gcloud services enable` was needed.
2. **The functions targeted `us-east1`**, confirming `getDefaultRegion` returns
   `us-east1` for global AI Logic triggers rather than `us-central1`.
3. **The AI Logic IAM binding was applied.** Checked after the failure:

   ```
   roles/run.invoker  serviceAccount:service-11147573823@gcp-sa-firebasevertexai.iam.gserviceaccount.com
   ```

   That is `requiredProjectBindings` from `services/ailogic.ts` working. The
   AI Logic-specific half of the deploy succeeded; a generic Cloud Functions
   prerequisite is what stopped it. See issue 1 below.

---

## 8. What the deploy does behind the scenes

None of this is publicly documented; it is read from the CLI source.

**Enables APIs.** `cloudfunctions`, `cloudbuild`, `artifactregistry`, `run`,
`eventarc`, `firebaseextensions`. On a project that has only ever used AI Logic,
none of these exist yet, so the first deploy is slow.

**Grants the invoker role.** `src/deploy/functions/services/ailogic.ts` declares:

```ts
requiredProjectBindings = async (projectNumber: string) => [{
  role: "roles/run.invoker",
  members: [`serviceAccount:service-${projectNumber}@gcp-sa-firebasevertexai.iam.gserviceaccount.com`],
}];
```

That service agent is the AI Logic proxy. Without this binding the trigger
registers but AI Logic cannot call the function.

`ensureServiceAgentRoles` in `src/deploy/functions/checkIam.ts` applies it. Note
it is **fail-soft**: if it cannot set the IAM policy it prints manual
instructions and continues, so the deploy looks fine and calls fail later. Deploy
as a project Owner.

**Registers the triggers.** `upsertBlockingFunction` in `src/gcp/ailogic.ts`
POSTs to
`firebasevertexai.googleapis.com/v1beta/projects/{p}/locations/global/triggers/{id}`
where `{id}` is `before-generate-content` or `after-generate-content`.

**Region.** `getDefaultRegion` returns `us-east1` for global AI Logic triggers,
not the usual `us-central1`.

**One per project.** `validateTrigger` rejects a second global trigger for the
same event with `Can only create at most one global AI Logic Trigger for ...`.
Use `{ regionalWebhook: true }` for one per region instead.

**No experiment flag.** The AI Logic service is wired unconditionally into the
deploy path (`src/deploy/functions/services/index.ts`). The `ailogic` experiment
only gates the `firebase ailogic:*` commands.

---

## 9. Issues encountered

### Issue 1 — Build failed: missing permission on the build service account

**Symptom**

```
Build failed with status: FAILURE. Could not build the function due to a missing
permission on the build service account. If you didn't revoke that permission
explicitly, this could be caused by a change in the organization policies.
```

**Official source**

https://docs.cloud.google.com/functions/docs/troubleshooting — section
"Build service account".
(The link the CLI prints, `cloud.google.com/functions/docs/troubleshooting#build-service-account`,
301-redirects to `docs.cloud.google.com`.)

**Cause**

Cloud Functions v2 builds run as the **default compute service account**,
`PROJECT_NUMBER-compute@developer.gserviceaccount.com`. Cloud Build changed its
default service account behaviour, and on newer projects that account is no
longer granted the builder role automatically. Without it, the build cannot read
the source bucket or write to Artifact Registry.

Confirmed by reading the project IAM policy after the failure. The compute
account had only:

```
roles/eventarc.eventReceiver   11147573823-compute@developer.gserviceaccount.com
roles/run.invoker              11147573823-compute@developer.gserviceaccount.com
```

No `roles/cloudbuild.builds.builder`. Note the *legacy* Cloud Build account
`11147573823@cloudbuild.gserviceaccount.com` does hold that role — which is
exactly why this is confusing: the role looks present in the policy, just on the
account that is no longer used for the build.

**Fix**

```bash
gcloud projects add-iam-policy-binding ailogic-cloud-triggers-test \
  --member=serviceAccount:11147573823-compute@developer.gserviceaccount.com \
  --role=roles/cloudbuild.builds.builder
```

The troubleshooting page shows an `iam service-accounts add-iam-policy-binding`
variant, which grants the role *on the service account resource*. The builder
role needs project scope to reach GCS, Artifact Registry, and Cloud Logging, so
the project-level binding above is the one to use.

**Nothing to do with AI Logic.** This is a generic Cloud Functions v2 first-deploy
prerequisite on a project that has never built a function.

**No config-level workaround.** The legacy Cloud Build account
`PROJECT_NUMBER@cloudbuild.gserviceaccount.com` already holds the builder role,
so pointing the build at it would also have worked — but the Firebase CLI has no
setting for that. `buildServiceAccount` exists only under App Hosting
(`src/apphosting/secrets/dialogs.ts`), not for Cloud Functions. The IAM grant is
the only path.

**Resolved.** After the grant, the compute account reads:

```
roles/cloudbuild.builds.builder
roles/eventarc.eventReceiver
roles/run.invoker
```

### Issue 1a — the failed deploy left broken function shells

`firebase functions:list` after the failure looked **successful**:

```
guardStoryPrompts      v2  google.firebase.ailogic.v1.beforeGenerate  us-east1  ---  nodejs22
recordGenerationUsage  v2  google.firebase.ailogic.v1.afterGenerate   us-east1  ---  nodejs22
```

It was not. `gcloud functions describe` told the truth:

```
[ERROR] Cloud Run service .../services/guardstoryprompts for the function was
not found. The function will not work correctly. Please redeploy.
```

The function metadata was created, the build failed, so no Cloud Run service
exists behind it. The `---` in the Memory column is the only hint in the Firebase
listing. **Do not trust `functions:list` alone to confirm a deploy** — check
`gcloud functions describe <name> --region <region>`.

**The app was never affected.** The AI Logic triggers endpoint returned `{}` —
registration happens in the release phase, after the functions are healthy, so
AI Logic was never pointed at the broken shells. Verified by generating a story
while they sat there: it worked normally. A redeploy repairs the shells in
place (the second attempt logged `updating` rather than `creating`).

### Issue 2 — a misleading final error line

After the failures the CLI printed:

```
Error: Functions successfully deployed but could not set up cleanup policy in
location us-east1.
```

Nothing was successfully deployed. The cleanup-policy check runs regardless of
outcome and its message hardcodes the success wording. Ignore it when the deploy
above it failed.

Separately, the warning it refers to is real and worth acting on eventually:

```
⚠  functions: No cleanup policy detected for repositories in us-east1. This may
   result in a small monthly bill as container images accumulate over time.
```

Fix with `firebase functions:artifacts:setpolicy`, or pass `--force` on a deploy.

---

### Attempt 2 — deployed

After the IAM grant, `firebase deploy --only functions --force`:

```
i  functions: updating Node.js 22 (2nd Gen) function guardStoryPrompts(us-east1)...
i  functions: updating Node.js 22 (2nd Gen) function recordGenerationUsage(us-east1)...
✔  functions[guardStoryPrompts(us-east1)] Successful update operation.
✔  functions[recordGenerationUsage(us-east1)] Successful update operation.
i  functions: Configured cleanup policy for repository in us-east1.
✔  Deploy complete!
```

`--force` was used to accept the artifact cleanup policy (1-day image
retention) rather than leaving the warning from attempt 1 outstanding.

Note it says **updating**, not creating: the broken shells from attempt 1 were
repaired in place. No cleanup was needed.

## 10. Status: deployed and verified

```
$ gcloud functions describe guardStoryPrompts --region us-east1 --format='value(state)'
ACTIVE
$ gcloud functions describe recordGenerationUsage --region us-east1 --format='value(state)'
ACTIVE
```

Triggers registered with AI Logic:

```json
{"triggers": [
  {"name": ".../locations/global/triggers/before-generate-content",
   "cloudFunction": {"id": "guardStoryPrompts", "locationId": "us-east1"}},
  {"name": ".../locations/global/triggers/after-generate-content",
   "cloudFunction": {"id": "recordGenerationUsage", "locationId": "us-east1"}}
]}
```

End-to-end results:

| Test | Result |
| --- | --- |
| Normal story | Works. 911 chars, plus a 2.88 MB illustration |
| Before hook fires | `Allowing generation` logged for both models |
| After hook fires | `Generation finished`, `promptTokens: 73, totalTokens: 1121` |
| Blocked topic ("weapon") | Request rejected, `Blocked a prompt` logged |
| Image not truncated | `finishReason: STOP` at 1366 tokens, image renders fully |

## 11. Runtime findings

Two things that only showed up once the triggers were live.

### `event.data.model` is a full resource path, not a model id

The logs show:

```
"model":"projects/ailogic-cloud-triggers-test/locations/global/publishers/google/models/gemini-3.6-flash"
```

Not `"gemini-3.6-flash"`. So this would silently never match:

```ts
if (event.data.model === "gemini-3.1-flash-image") { /* never true */ }
```

The `.includes("image")` check in section 5.4 works because it is a substring
test. Anything comparing model names must account for the full path.

### A rejected prompt reaches the client as a generic 500

`guardStoryPrompts` threw
`HttpsError("invalid-argument", "Story Studio doesn't write about weapon.")`.
The function logged exactly that, with `code: 'invalid-argument'` and
`httpErrorCode: { canonicalName: 'INVALID_ARGUMENT', status: 400 }`.

What the browser received:

```
[500 ] Internal error encountered. (AI/fetch-error)
```

**The message does not propagate.** The block works — the model never ran — but
you cannot tell the user *why*. The reason is only in the function logs.

Practical consequence: do not write rejection messages for end users. If the app
needs to explain itself, it has to pre-validate on the client too (for the
message) while the trigger does the actual enforcement (for the guarantee).

Also note the function log labels the throw:

```
Unhandled error: HttpsError: Story Studio doesn't write about weapon.
```

"Unhandled" is the SDK's own wording in its catch block
(`lib/v2/providers/ai/index.js`), not a sign anything is wrong. A deliberate
`HttpsError` throw looks identical to a crash in the logs.

### Confirmed: the image model really does hit the hook

Both models appear in the before-hook logs:

```
{"message":"Allowing generation","model":".../gemini-3.6-flash"}
{"message":"Allowing generation","model":".../gemini-3.1-flash-image"}
```

This validates the exemption in section 5.4. Without it, the 4000-token cap
would have applied to an image response that used 1366 tokens for a small test
image — a larger one would have been truncated.

## 12. Verification commands

1. **The functions exist, in the right region**

   ```bash
   firebase functions:list
   ```

   Expect `guardStoryPrompts` and `recordGenerationUsage` in `us-east1`.

2. **The triggers are registered with AI Logic** — this is the AI Logic-specific
   check, and the one that proves the blocking hook is wired rather than just a
   function sitting there:

   ```bash
   curl -s -H "Authorization: Bearer $(gcloud auth print-access-token)" \
     -H "x-goog-user-project: ailogic-cloud-triggers-test" \
     "https://firebasevertexai.googleapis.com/v1beta/projects/ailogic-cloud-triggers-test/locations/global/triggers"
   ```

   Expect `before-generate-content` and `after-generate-content`, each pointing
   at its `cloudFunction`.

3. **A normal story still works.** Run the app, generate one. It should behave
   exactly as before.

4. **The after hook logged it**

   ```bash
   firebase functions:log --only recordGenerationUsage
   ```

   Expect `Generation finished` with `promptTokens` and `totalTokens`.

5. **The guard actually blocks.** Ask for a story about a **weapon**. The request
   should fail and the app should show its error bar;
   `firebase functions:log --only guardStoryPrompts` should show
   `Blocked a prompt`.

6. **The illustration is not truncated.** Generate a story and let the image
   render. If it comes back broken or half-drawn, the `model.includes("image")`
   exemption in section 5.4 is not working and the token cap is clipping it.
