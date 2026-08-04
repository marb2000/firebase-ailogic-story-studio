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

You need [Node.js](https://nodejs.org) 20+ and a recent Firebase CLI:

```bash
npm install -g firebase-tools && firebase login
```

### 1. Create a project

```bash
firebase projects:create my-story-studio
```

Or make one in the [Firebase console](https://console.firebase.google.com).

### 2. Upgrade it to the Blaze plan

**This one is not optional.** The Vertex AI backend and *every* image-generation
model — Nano Banana included — require pay-as-you-go billing. On the free Spark
plan the story call fails and the illustration never appears.

Do it in the console: **⚙️ Project settings → Usage and billing → Modify plan →
Blaze**. It needs a billing account, and it can't be done from the CLI.

Generating a story plus an image costs a fraction of a cent, but set a budget
alert while you're in there if you're experimenting.

### 3. Point this checkout at the project

```bash
firebase use --add
```

### 4. Register a web app

```bash
firebase apps:create web "Story Studio"
```

Note the app ID it prints — you'll need it in step 7.

### 5. Turn on AI Logic

```bash
firebase init ailogic
```

Pick the web app you just created. This enables `firebasevertexai.googleapis.com`.

### 6. Enable the Vertex AI provider

AI Logic can talk to two providers, and this app uses the Vertex AI one (also
called the Agent Platform Gemini API). That provider is backed by a separate API:

```bash
gcloud services enable aiplatform.googleapis.com --project <your-project-id>
```

No `gcloud`? Open **AI Logic → Get started** in the Firebase console and choose
the **Vertex AI Gemini API**, which enables it for you.

> Newer CLIs have `firebase ailogic:providers:enable gemini-agent-platform-api`,
> which does the same thing. Try it first.

### 7. Set up App Check

App Check proves a request came from your real app. Firebase **enforces it on AI
Logic by default**, so nothing works until you've done this.

Enable the API and register a debug token for local development:

```bash
gcloud services enable firebaseappcheck.googleapis.com --project <your-project-id>

firebase appcheck:debugtokens:create --app <your-app-id> --display-name local-dev
```

Copy the token it prints. A browser on `localhost` can't produce a real
attestation, so a *debug token* stands in for one — see
[App Check](#app-check) below for what that means and what to do before you deploy.

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

To see enforcement actually working, call the API with just your API key and no
App Check token:

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
quietly pretending to attest. Before deploying anywhere real:

1. Firebase console → **App Check** → register the web app with **reCAPTCHA Enterprise**
2. Swap the `CustomProvider` in `src/firebase.ts` for
   `new ReCaptchaEnterpriseProvider("<your site key>")`

Handy while you work:

```bash
firebase appcheck:debugtokens:list --app <your-app-id>
```

Debug tokens are secrets — anyone holding one passes App Check as your app.
Delete them when you're done:

```bash
firebase appcheck:debugtokens:delete <debugTokenId> --app <your-app-id>
```

---

## Deploy

Hosting is configured, but do the reCAPTCHA step above first or the deployed app
can't attest and every AI call will 401.

```bash
npm run deploy
```

---

## Things that will trip you up

**`404 Publisher model ... was not found`** — the backend location. This app uses
`new AgentPlatformBackend("global")`. The newest Gemini models aren't in pinned
regions yet, so `"us-central1"` 404s on `gemini-3.6-flash`.

**`AI/api-not-enabled`** — `firebase init ailogic` enables AI Logic itself, but not
`aiplatform.googleapis.com`. That's step 6.

**`401 Firebase App Check token is invalid`** — no debug token, or it isn't
registered on the project. Check `.env.local`, and note the SDK logs the token it's
using to the browser console at startup.

**Everything works but no image appears** — almost always the Spark plan. Image
models need Blaze.

---

## Want the free tier instead?

Swap the backend in [`src/ai.ts`](src/ai.ts):

```ts
const ai = getAI(app, { backend: new GoogleAIBackend() });
```

That's the Gemini Developer API, which has a free tier and doesn't need Blaze —
but image generation still does, so the illustration won't work on Spark either way.

---

## Next: AI Logic Cloud Triggers

Not wired up yet. The Firebase CLI supports two AI Logic blocking events,
`beforeGenerateContent` and `afterGenerateContent`, deployed as Cloud Functions and
registered with `firebase deploy`. The two call sites in [`src/ai.ts`](src/ai.ts)
are what they'd intercept — for rewriting prompts, filtering output, or logging.

## License

MIT
