<!--
DRAFT — written in the style of firebase.google.com/docs/ai-logic, for review
before publishing. Modeled on the structure of "Extend Firebase Authentication
using Cloud Functions" (docs/auth/extend-with-blocking-functions), the closest
existing analog: a before/after blocking-function pair.

Suggested location: docs/ai-logic/extend-with-cloud-triggers, under
"Get ready for production", alongside App Check and the production checklist.

Everything in this draft was verified against a live deployment, not just the
SDK types — see /docs/cloud-triggers-workshop.md in this repo for the raw log.
-->

# Extend Firebase AI Logic using Cloud Triggers

Cloud Triggers let you run your own code before and after every Gemini API
call your app makes through Firebase AI Logic — without changing your client
code. You can use a trigger to moderate prompts, cap token usage, log
generations for analytics, or redact response content, all enforced on the
server, where a modified or compromised client can't bypass it.

Two events are available:

* **`beforeGenerateContent`** runs before a request reaches the model. It can
  modify the request, or block the call entirely by throwing an error.
* **`afterGenerateContent`** runs after the model responds. It can modify the
  response, or simply observe it — for logging, analytics, or auditing.

Both are implemented as callback-style Cloud Functions (2nd gen) and deployed
the same way as any other Cloud Function.

**Note:** Cloud Triggers run for every Gemini API call in your project that
goes through Firebase AI Logic, including calls made with
[server prompt templates](/docs/ai-logic/server-prompt-templates/get-started).
They do not run for calls made directly against the Gemini Developer API or
Vertex AI outside of Firebase AI Logic.

## Before you begin

1. Upgrade your project to the **Blaze (pay-as-you-go)** plan. Cloud Functions
   requires billing to be enabled.
2. Set up Firebase AI Logic in your app if you haven't already — see
   [Get started](/docs/ai-logic/get-started).
3. If this is the first Cloud Function you're deploying in this project, grant
   the default compute service account the Cloud Build role it needs to build
   your function:

   ```bash
   gcloud projects add-iam-policy-binding PROJECT_ID \
     --member="serviceAccount:PROJECT_NUMBER-compute@developer.gserviceaccount.com" \
     --role="roles/cloudbuild.builds.builder"
   ```

   **Caution:** Skipping this step is the most common reason a first deploy
   fails, with an error that mentions organization policies. The cause is
   unrelated to policy — see
   [Deploy your Cloud Triggers](#deploy-your-cloud-triggers) below.

4. If you haven't used Cloud Functions in this project before, initialize it:

   ```bash
   firebase init functions
   ```

   Choose **TypeScript**, and make sure `firebase-functions` is version
   **7.3.0 or later** — the AI Logic trigger types were introduced in 7.3, and
   change shape from earlier previews. Check your version:

   ```bash
   npm --prefix functions list firebase-functions
   ```

## Understand Cloud Triggers

A Cloud Trigger is a **global** trigger by default: there can be at most one
`beforeGenerateContent` function and one `afterGenerateContent` function per
project, and Firebase deploys them to `us-east1` regardless of where your other
functions run. If you need per-region logic instead, pass
`regionalWebhook: true` when you declare the function — see
[Deploy triggers per region](#deploy-triggers-per-region).

**Key Point:** Cloud Triggers only run for **unary** `generateContent()` calls.
They do not run for `generateContentStream()`. If your app streams responses,
switch the calls you want intercepted to the non-streaming method — there's no
error or warning if you don't; the trigger simply never runs.

## Event data reference

Both events receive an object with the following fields.

| Field | Description |
| --- | --- |
| `authType` | How the caller authenticated: `"app_user"`, `"unauthenticated"`, or `"unknown"`. |
| `authId` | The caller's Firebase Authentication UID, if signed in. |
| `authClaims` | The caller's custom claims, if any. |
| `appId` | The Firebase App ID that made the request. |
| `displayName` | The display name of the calling app, if set. |
| `androidPackageName` / `iosBundleId` | Set when the caller is a mobile app on that platform. |
| `data.model` | The full model resource path, for example `projects/PROJECT_ID/locations/global/publishers/google/models/gemini-3.6-flash`. Use `includes()` rather than an exact match. |
| `data.api` | Which Gemini API the app is using: `geminiV1Beta` (Gemini Developer API) or `vertexV1Beta1` (Agent Platform Gemini API). |
| `data.request` | The outgoing request. Present on `beforeGenerateContent` only. |
| `data.response` | The model's response. Present on `afterGenerateContent` only. |
| `data.template` | Server prompt template info, if the call used one. |

**Note:** `data.request` and `data.response` are typed as a union of the
Gemini Developer API and Agent Platform Gemini API shapes. Narrow on
`data.api` before reading fields specific to one provider.

## Write a `beforeGenerateContent` function

This example rejects prompts about a list of blocked topics, and caps the
number of output tokens a text request can ask for.

```typescript
import { logger } from "firebase-functions";
import {
  beforeGenerateContent,
  HttpsError,
  vertexV1Beta1,
  type VertexV1Beta1GenerateContentRequest,
} from "firebase-functions/v2/ai";

const BLOCKED_TOPICS = ["weapon", "explosive", "self-harm"];
const MAX_OUTPUT_TOKENS = 4000;

export const moderateGenerateContent = beforeGenerateContent((event) => {
  // The Gemini Developer API and Agent Platform Gemini API have distinct
  // request shapes. Narrow to the one your app uses before reading it.
  if (event.data.api !== vertexV1Beta1) {
    return;
  }
  const request = event.data.request as VertexV1Beta1GenerateContentRequest;

  const prompt = (request.contents ?? [])
    .flatMap((content) => content.parts ?? [])
    .map((part) => ("text" in part ? part.text : "") ?? "")
    .join(" ")
    .toLowerCase();

  const blockedTopic = BLOCKED_TOPICS.find((topic) => prompt.includes(topic));
  if (blockedTopic) {
    logger.warn("Blocked a prompt", { topic: blockedTopic });
    // Throwing rejects the call before it reaches the model. The client's
    // generateContent() call fails; it does not receive this message — see
    // Limitations below.
    throw new HttpsError("invalid-argument", `Prompts about ${blockedTopic} aren't allowed.`);
  }

  // A model that returns images encodes the image itself as output tokens.
  // Skip any per-request limit meant for text-only responses.
  if (event.data.model.includes("image")) {
    return;
  }

  // Return the entire request, modified — not just the fields you changed.
  // Returning nothing leaves the request unchanged.
  return {
    ...request,
    generationConfig: {
      ...request.generationConfig,
      maxOutputTokens: Math.min(
        request.generationConfig?.maxOutputTokens ?? MAX_OUTPUT_TOKENS,
        MAX_OUTPUT_TOKENS,
      ),
    },
  };
});
```

## Write an `afterGenerateContent` function

This example logs token usage for every generation, without modifying the
response.

```typescript
import { logger } from "firebase-functions";
import {
  afterGenerateContent,
  vertexV1Beta1,
  type VertexV1Beta1GenerateContentResponse,
} from "firebase-functions/v2/ai";

export const logGenerateContentUsage = afterGenerateContent((event) => {
  if (event.data.api !== vertexV1Beta1) {
    return;
  }
  const response = event.data.response as VertexV1Beta1GenerateContentResponse;

  logger.info("Generation finished", {
    model: event.data.model,
    promptTokens: response.usageMetadata?.promptTokenCount,
    totalTokens: response.usageMetadata?.totalTokenCount,
    finishReason: response.candidates?.[0]?.finishReason,
  });

  // Returning nothing leaves the response as the model produced it. To
  // rewrite it — for example, to redact part of the output — return the
  // full response object with your changes applied.
});
```

## Deploy your Cloud Triggers

```bash
firebase deploy --only functions
```

Deploying grants the Firebase AI Logic service agent permission to invoke your
functions, and registers each one as a trigger with Firebase AI Logic. You
don't need to configure either of these yourself.

**Caution:** If this project has never deployed a Cloud Function before, the
build can fail with:

```
Build failed with status: FAILURE. Could not build the function due to a
missing permission on the build service account.
```

This means the [prerequisite step](#before-you-begin) above wasn't completed.
It is a general Cloud Functions (2nd gen) requirement, unrelated to Firebase AI
Logic — see
[Cloud Functions troubleshooting](https://cloud.google.com/functions/docs/troubleshooting#build-service-account).
A retry after granting the role repairs the deploy in place.

After deploying, confirm both functions are running:

```bash
firebase functions:list
```

**Note:** A function whose build failed can still appear in this list with its
trigger and region shown correctly. Confirm the function is actually healthy
with `gcloud functions describe FUNCTION_NAME --region us-east1`, which reports
its state as `ACTIVE` only once it's truly serving.

## Deploy triggers per region

By default, a Cloud Trigger is global: it intercepts every Gemini API call in
the project, from every region. To scope a trigger to one region instead, pass
`regionalWebhook: true`:

```typescript
export const moderateGenerateContent = beforeGenerateContent(
  { regionalWebhook: true },
  (event) => {
    // ...
  },
);
```

You can deploy at most one global trigger, or one regional trigger per region,
for each event type.

## Common scenarios

### Enforce a token budget

Cap `maxOutputTokens` in `beforeGenerateContent`, as shown above. Because the
trigger runs for every call in the project, remember to exempt any model whose
response modality isn't text — an image model encodes its output as tokens
too, and a text-sized cap will truncate the image.

### Moderate prompts or responses

Reject disallowed input in `beforeGenerateContent` by throwing `HttpsError`, or
inspect and redact model output in `afterGenerateContent` by returning a
modified response.

### Log usage for analytics

Read `usageMetadata` in `afterGenerateContent` and write it to Cloud Logging,
BigQuery, or Firestore for downstream analysis.

### Restrict access by authentication state

Use `event.authType` and `event.authId` in `beforeGenerateContent` to require
sign-in, or to apply different rules to signed-in users.

## Limitations

* **At most one global trigger per event type**, or one per region if you use
  `regionalWebhook: true`. Deploying a second global trigger for the same event
  fails with
  `Can only create at most one global AI Logic Trigger for <event>`.
* **`afterGenerateContent` does not run for streamed responses.** Use
  `generateContent()`, not `generateContentStream()`, for any call you want a
  trigger to observe or guard.
* **A thrown `HttpsError` message isn't shown to the end user.** The client's
  `generateContent()` call fails, but the message you throw stays in your
  function's logs — it is not returned to the client. If your app needs to
  explain a rejection to the user, validate on the client for the message and
  rely on the trigger only for enforcement.
* **`event.data.model` is a full resource path**, not a short model name. Use
  `includes()` or parse the path rather than comparing for exact equality.
* If you delete a Cloud Trigger function, redeploy so Firebase AI Logic
  unregisters the trigger. A trigger left registered against a deleted function
  will cause every matching Gemini API call to fail.

## What's next

* [Set up App Check](/docs/ai-logic/app-check) to verify that requests come
  from your genuine app before they ever reach a trigger.
* Review the [production checklist](/docs/ai-logic/solutions/overview) before
  you launch.
* See the [Cloud Functions documentation](/docs/functions) for background on
  deploying, monitoring, and scaling functions in general.
