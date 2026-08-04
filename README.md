# Story Studio

A deliberately small web app for learning **Firebase AI Logic**. Give it a topic
and a length: Gemini writes the story, Nano Banana illustrates it, and you can
regenerate the illustration as many times as you like.

No framework, no backend, five short files. It's built to be read end to end in
about ten minutes.

<!-- Add a screenshot here if you like: ![Story Studio](docs/screenshot.png) -->

---

## What it's made of

| File | Role |
| --- | --- |
| [`src/config.ts`](src/config.ts) | Firebase config, read from `.env.local` |
| [`src/firebase.ts`](src/firebase.ts) | Starts Firebase and App Check |
| [`src/ai.ts`](src/ai.ts) | The only file that talks to AI Logic |
| [`src/main.ts`](src/main.ts) | DOM wiring — read the form, stream the story, show the picture |
| [`index.html`](index.html) | The page |

Two models, reached through the **same** `getGenerativeModel()` / `generateContent()`
API. The image model differs only in asking for an `IMAGE` response modality —
that symmetry is the main thing worth noticing.

| | Model | Called with |
| --- | --- | --- |
| Story | `gemini-3.6-flash` | `generateContentStream()`, so text appears as it's written |
| Illustration | `gemini-3.1-flash-image` (Nano Banana 2) | `generateContent()`, image comes back as base64 in an inline data part |

The browser never holds a Gemini API key. Requests go to Firebase, which checks
the App Check token and calls Vertex AI on your behalf.

---

## Setup, from a brand new Firebase project

Everything below is the Firebase CLI. The only thing you can't do from the
terminal is turn on billing.

You need [Node.js](https://nodejs.org) 20+ and a recent Firebase CLI:

```bash
npm install -g firebase-tools && firebase login
```

### 0. Turn on the preview command groups

The AI Logic and App Check admin commands are in preview behind experiment flags:

```bash
firebase experiments:enable ailogic
firebase experiments:enable appcheckadmin
```

> `appcheck:debugtokens` is generally available and doesn't need a flag. The rest
> of the App Check surface is still in review and may change.

### 1. Create a project

```bash
firebase projects:create my-story-studio
firebase use my-story-studio
```

### 2. Upgrade it to the Blaze plan

**The one manual step, and it isn't optional.** The Vertex AI backend and *every*
image-generation model — Nano Banana included — require pay-as-you-go billing. On
the free Spark plan the story call fails and the illustration never appears.

Console: **⚙️ Project settings → Usage and billing → Modify plan → Blaze**. It
needs a billing account, so there's no CLI equivalent.

Generating a story plus an image costs a fraction of a cent, but set a budget
alert while you're in there if you're experimenting.

### 3. Register a web app

```bash
firebase apps:create web "Story Studio"
```

Note the app ID it prints — the App Check commands take it as `--app`.

### 4. Turn on AI Logic

```bash
firebase init ailogic
```

Pick the web app you just created.

### 5. Enable the Vertex AI provider

AI Logic can talk to two Gemini providers, and this app uses the Vertex AI one
(also called the Agent Platform Gemini API):

```bash
firebase ailogic:providers:enable gemini-agent-platform-api
```

Check where you stand at any point:

```bash
$ firebase ailogic:providers:list
┌───────────────────────────┬─────────┐
│ Provider                  │ Status  │
├───────────────────────────┼─────────┤
│ gemini-developer-api      │ Enabled │
├───────────────────────────┼─────────┤
│ gemini-agent-platform-api │ Enabled │
└───────────────────────────┴─────────┘
```

### 6. Check App Check enforcement

Firebase **enforces App Check on AI Logic by default**, so this is usually a
read, not a write:

```bash
$ firebase appcheck:services:get ailogic
Service:            ailogic (Firebase AI Logic)
Enforcement:        Enforced
Replay protection:  Off
Last updated:       2026-08-04T22:48:46.551039Z
```

If it says anything other than `Enforced`, fix it:

```bash
firebase appcheck:services:set ailogic enforced
```

`firebase appcheck:services:list` shows the same for every service at once.

### 7. Register a debug token

App Check proves a request came from your real app. A browser on `localhost`
can't produce a real attestation, so a **debug token** stands in for one:

```bash
firebase appcheck:debugtokens:create --app <your-app-id> --display-name local-dev
```

Copy the token it prints. See [App Check](#app-check) for what to do before you
deploy anywhere real.

### 8. Fill in `.env.local`

```bash
cp .env.example .env.local
firebase apps:sdkconfig WEB
```

Paste the config values and the debug token into `.env.local`. It's gitignored.

### 9. Run it

```bash
npm install
npm run dev
```

Open http://localhost:5173 and ask for a story.

---

## App Check

`src/firebase.ts` sets `FIREBASE_APPCHECK_DEBUG_TOKEN` before calling
`initializeAppCheck()` — order matters, the SDK reads that global once at
startup. It's guarded by `import.meta.env.DEV`, so the token can never reach a
production build.

To watch enforcement actually reject something, call the API with just your API
key and no App Check token:

```bash
curl -s -X POST -H "Content-Type: application/json" \
  "https://firebasevertexai.googleapis.com/v1beta/projects/<project-id>/locations/global/publishers/google/models/gemini-3.6-flash:generateContent?key=<api-key>" \
  -d '{"contents":[{"role":"user","parts":[{"text":"hi"}]}]}'
```

```
401 Firebase App Check token is invalid.
```

**There is no reCAPTCHA provider here.** That's fine on localhost and nowhere
else. `src/firebase.ts` uses a `CustomProvider` that fails loudly rather than
quietly pretending to attest.

Managing debug tokens:

```bash
firebase appcheck:debugtokens:list --app <your-app-id>
firebase appcheck:debugtokens:delete <tokenId> --app <your-app-id>
```

They're secrets — anyone holding one passes App Check as your app. Delete them
when you're done.

---

## Deploy

Before deploying anywhere real, the app needs a way to attest that isn't a debug
token. Today that means the console: **App Check → register the web app →
reCAPTCHA Enterprise**, then swap the `CustomProvider` in `src/firebase.ts` for:

```ts
new ReCaptchaEnterpriseProvider("<your site key>")
```

Then:

```bash
npm run deploy
```

> **Proposed:** `firebase appcheck:providers:set recaptcha-enterprise --app <id> --site-key <key>`
> would make the backend half of this a one-liner, and `firebase appcheck:providers:list --app <id>`
> would show which providers an app has configured. Not built yet — the
> `appcheckadmin` experiment currently ships `appcheck:services:*` only.

---

## Things that will trip you up

**`404 Publisher model ... was not found`** — the backend location. This app uses
`new AgentPlatformBackend("global")`. The newest Gemini models aren't in pinned
regions yet, so `"us-central1"` 404s on `gemini-3.6-flash`.

**`AI/api-not-enabled`** — `firebase init ailogic` turns on AI Logic itself, but
not the provider behind it. That's step 5. `firebase ailogic:providers:list` tells
you in one line.

**`401 Firebase App Check token is invalid`** — no debug token, or it isn't
registered on the project. Check `.env.local` and
`firebase appcheck:debugtokens:list --app <your-app-id>`. The SDK also logs the
token it's using to the browser console at startup.

**Everything works but no image appears** — almost always the Spark plan. Image
models need Blaze.

---

## What the preview commands replaced

Same setup, before these command groups existed:

| Step | Before | Now |
| --- | --- | --- |
| Enable the Vertex provider | `gcloud services enable aiplatform.googleapis.com`, or hunt for **Get started** in the console | `firebase ailogic:providers:enable gemini-agent-platform-api` |
| See which provider is on | Read the enabled-services list and know that `aiplatform` means the Vertex provider | `firebase ailogic:providers:list` |
| Enable the App Check API | `gcloud services enable firebaseappcheck.googleapis.com` | implied by the `appcheck:*` commands |
| Read enforcement state | `curl` a `GET` and interpret a missing `enforcementMode` field | `firebase appcheck:services:get ailogic` |
| Set enforcement | `curl -X PATCH ...?updateMask=enforcementMode` with a hand-written body | `firebase appcheck:services:set ailogic enforced` |

Two things stand out. First, `gcloud` disappears — the old flow needed a second
CLI, a second auth session, and knowledge of which raw API backs which Firebase
feature. Second, `enforcementMode` is omitted from the REST response when it's
`OFF`, so reading enforcement by hand means knowing that an absent field means
off; `services:get` just prints `Off`.

The service id is the sharpest example of what the alias table buys you. App
Check calls AI Logic `firebaseml.googleapis.com` — a different product's name —
while AI Logic itself answers on `firebasevertexai.googleapis.com`. Passing the
latter to the App Check API returns `Service not supported`. You type `ailogic`
and never find out.

---

## Next: AI Logic Cloud Triggers

Not wired up yet. The Firebase CLI supports two AI Logic blocking events,
`beforeGenerateContent` and `afterGenerateContent`, deployed as Cloud Functions and
registered with `firebase deploy`. The two call sites in [`src/ai.ts`](src/ai.ts)
are what they'd intercept — for rewriting prompts, filtering output, or logging.

## License

MIT
