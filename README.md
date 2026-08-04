# Story Studio

Gemini writes a story from your topic, Nano Banana illustrates it, and you can
regenerate the picture. A small Firebase AI Logic demo — Vite, vanilla
TypeScript, five files.

<!-- ![Story Studio](docs/screenshot.png) -->

## Setup

Needs [Node.js](https://nodejs.org) 20+ and `npm install -g firebase-tools && firebase login`.

```bash
firebase experiments:enable ailogic
firebase experiments:enable appcheckadmin
```
The AI Logic and App Check admin commands are in preview behind flags.

```bash
firebase projects:create my-story-studio && firebase use my-story-studio
```

**Now upgrade the project to Blaze** in the console: **⚙️ Project settings →
Usage and billing → Modify plan**. Billing has no CLI equivalent, and image
models don't run without it.

```bash
firebase apps:create web "Story Studio"
```
Registers the web app. Note the app ID it prints.

```bash
firebase init ailogic
```
Turns on AI Logic. Pick the app you just created.

```bash
firebase ailogic:providers:enable gemini-agent-platform-api
```
Enables the Vertex AI Gemini provider, which is the one this app calls.

```bash
firebase appcheck:services:get ailogic
```
Should say `Enforced` — Firebase enforces App Check on AI Logic by default. If
not: `firebase appcheck:services:set ailogic enforced`.

```bash
firebase appcheck:debugtokens:create --app <app-id> --display-name local-dev
```
`localhost` can't do a real attestation, so a debug token stands in. Copy it.

```bash
cp .env.example .env.local && firebase apps:sdkconfig WEB
```
Paste the config values and the debug token into `.env.local`. It's gitignored.

```bash
npm install && npm run dev
```
http://localhost:5173.

## The code

| File | Role |
| --- | --- |
| [`src/ai.ts`](src/ai.ts) | The only file that talks to AI Logic |
| [`src/firebase.ts`](src/firebase.ts) | Firebase + App Check startup |
| [`src/config.ts`](src/config.ts) | Config, read from `.env.local` |
| [`src/main.ts`](src/main.ts) | DOM wiring |

Both models go through the same `generateContent()` API — the image model just
asks for an `IMAGE` response modality. Story is `gemini-3.6-flash` (streamed),
illustration is `gemini-3.1-flash-image` (Nano Banana 2).

## Gotchas

- **`404 Publisher model not found`** — use `AgentPlatformBackend("global")`. New models aren't in pinned regions.
- **`AI/api-not-enabled`** — provider not on. Check `firebase ailogic:providers:list`.
- **`401 App Check token is invalid`** — debug token missing or unregistered. Check `firebase appcheck:debugtokens:list --app <app-id>`.
- **Story works, image never appears** — Spark plan. Image models need Blaze.

## Deploying

`src/firebase.ts` uses a `CustomProvider` that fails on purpose: a debug token
works on localhost and nowhere else. Before deploying, register the app with
reCAPTCHA Enterprise in the console and swap in
`new ReCaptchaEnterpriseProvider("<site key>")`. Then `npm run deploy`.

## Next

AI Logic Cloud Triggers — `beforeGenerateContent` and `afterGenerateContent`,
deployed as Cloud Functions. The two calls in [`src/ai.ts`](src/ai.ts) are what
they'd intercept.

## License

MIT
