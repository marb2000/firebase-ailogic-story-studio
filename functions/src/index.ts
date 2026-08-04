/**
 * AI Logic Cloud Triggers for Story Studio.
 *
 * These run inside AI Logic, not in the app. Every `generateContent()` call the
 * project makes passes through them — the browser can't skip them, which is the
 * whole point: rules you can't enforce in client code you can enforce here.
 *
 * Two events:
 *   beforeGenerateContent — runs before the model. Can rewrite the request, or
 *                           reject the call outright by throwing.
 *   afterGenerateContent  — runs after the model. Can rewrite the response, or
 *                           just look at it.
 *
 * Both are registered globally, so there is at most **one of each per project**
 * and the CLI defaults them to `us-east1`. Pass `{ regionalWebhook: true }` if
 * you'd rather have one per region.
 */
import { logger } from "firebase-functions";
import {
  afterGenerateContent,
  beforeGenerateContent,
  HttpsError,
  vertexV1Beta1,
  type VertexV1Beta1GenerateContentRequest,
  type VertexV1Beta1GenerateContentResponse,
} from "firebase-functions/v2/ai";

/** Story topics this app won't write about, however they're phrased. */
const BLOCKED_TOPICS = ["weapon", "explosive", "self-harm"];

/** A ceiling on story length, so no client can talk us into an expensive run. */
const MAX_STORY_TOKENS = 4000;

/** Flattens every bit of text in a request into one lowercase string. */
function promptText(request: VertexV1Beta1GenerateContentRequest): string {
  return (request.contents ?? [])
    .flatMap((content) => content.parts ?? [])
    .map((part) => ("text" in part ? part.text : "") ?? "")
    .join(" ")
    .toLowerCase();
}

/**
 * Guards every request before it reaches a model.
 *
 * Throwing here fails the client's `generateContent()` call — in the app that
 * surfaces as the red error bar.
 */
export const guardStoryPrompts = beforeGenerateContent((event) => {
  // Story Studio always calls through the Vertex AI backend, so the request is
  // always that flavour. AI Logic also speaks the Gemini Developer API, whose
  // types differ slightly — branch here if you use both.
  if (event.data.api !== vertexV1Beta1) {
    return;
  }
  const request = event.data.request as VertexV1Beta1GenerateContentRequest;

  const prompt = promptText(request);
  const blocked = BLOCKED_TOPICS.find((topic) => prompt.includes(topic));

  if (blocked) {
    logger.warn("Blocked a prompt", { topic: blocked, model: event.data.model });
    throw new HttpsError("invalid-argument", `Story Studio doesn't write about ${blocked}.`);
  }

  logger.info("Allowing generation", {
    model: event.data.model,
    // "app_user" when Firebase Auth is in play, "unauthenticated" otherwise.
    authType: event.authType,
    // The caller's uid, when there is one.
    authId: event.authId,
    appId: event.appId,
  });

  // The illustration model returns its picture as tokens too, so a text-sized
  // cap would truncate the image. Only the story model gets capped.
  if (event.data.model.includes("image")) {
    return;
  }

  // Return the *whole* request, edited — not just the fields you changed.
  // Returning nothing at all leaves it untouched.
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

/**
 * Records what each generation actually cost.
 *
 * Returning nothing leaves the response untouched — this one only observes.
 * Read it back with `firebase functions:log --only recordGenerationUsage`.
 */
export const recordGenerationUsage = afterGenerateContent((event) => {
  if (event.data.api !== vertexV1Beta1) {
    return;
  }
  const response = event.data.response as VertexV1Beta1GenerateContentResponse;
  const usage = response.usageMetadata;

  logger.info("Generation finished", {
    model: event.data.model,
    authType: event.authType,
    promptTokens: usage?.promptTokenCount,
    totalTokens: usage?.totalTokenCount,
    finishReason: response.candidates?.[0]?.finishReason,
  });
});
