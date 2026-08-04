import {
  AgentPlatformBackend,
  ResponseModality,
  getAI,
  getGenerativeModel,
} from "firebase/ai";
import { app } from "./firebase";

/**
 * Firebase AI Logic, pointed at the Vertex AI (Agent Platform) Gemini API.
 *
 * The browser never holds a Gemini API key: requests go to Firebase, which
 * checks the App Check token and then calls Vertex AI on our behalf.
 *
 * "global" routes to whichever region has capacity, and is where the newest
 * Gemini models land first — a pinned region like "us-central1" 404s on them.
 */
const ai = getAI(app, { backend: new AgentPlatformBackend("global") });

/** Writes the story. Text out. */
const storyModel = getGenerativeModel(ai, {
  model: "gemini-3.6-flash",
  systemInstruction: [
    "You are a vivid, warm short-story writer.",
    "Reply with the title on the first line as '# Title', then a blank line,",
    "then the story as plain prose paragraphs.",
    "No headings inside the story, no bullet lists, no commentary about the task.",
  ].join(" "),
});

/**
 * Draws the illustration. Exactly the same generateContent() call as above —
 * the only difference is asking for an IMAGE response modality instead of text.
 * "gemini-3.1-flash-image" is Nano Banana 2.
 */
const imageModel = getGenerativeModel(ai, {
  model: "gemini-3.1-flash-image",
  generationConfig: { responseModalities: [ResponseModality.IMAGE] },
});

export type StoryLength = "short" | "medium" | "long";

const LENGTH_HINT: Record<StoryLength, string> = {
  short: "about 150 words",
  medium: "about 400 words",
  long: "about 900 words",
};

/**
 * Generates a story about `topic`, streaming it as it is written.
 *
 * `onProgress` receives the full text so far on every chunk, so the caller can
 * just drop it into the DOM without stitching anything together.
 */
export async function generateStory(
  topic: string,
  length: StoryLength,
  onProgress: (textSoFar: string) => void,
): Promise<string> {
  const prompt = `Write a story about: ${topic}\n\nLength: ${LENGTH_HINT[length]}.`;

  const { stream } = await storyModel.generateContentStream(prompt);

  let text = "";
  for await (const chunk of stream) {
    text += chunk.text();
    onProgress(text);
  }
  return text;
}

/**
 * Different angles for the illustration, so "Regenerate" gives you a genuinely
 * different picture instead of the same one twice.
 */
const ILLUSTRATION_ANGLES = [
  "a wide establishing shot of the setting",
  "an intimate close-up of the main character mid-moment",
  "the story's turning point, caught in action",
  "a quiet detail from the story, rendered large and symbolic",
];

/**
 * Generates one illustration for a story and returns it as a `data:` URL you can
 * put straight into an <img src>.
 *
 * `attempt` counts up each time the user hits Regenerate; it picks a different
 * angle and style so the results actually differ.
 */
export async function generateIllustration(
  title: string,
  story: string,
  attempt = 0,
): Promise<string> {
  const angle = ILLUSTRATION_ANGLES[attempt % ILLUSTRATION_ANGLES.length];

  const prompt = [
    `Illustrate this short story, titled "${title}".`,
    `Compose it as ${angle}.`,
    "Style: rich, painterly children's-book illustration. No text or lettering in the image.",
    "",
    "The story:",
    // The opening is plenty of context, and keeps the request small.
    story.slice(0, 1500),
  ].join("\n");

  const result = await imageModel.generateContent(prompt);

  // The response is a list of parts; inlineDataParts() pulls out the binary ones.
  const image = result.response.inlineDataParts()?.[0];
  if (!image) {
    throw new Error("The model replied without an image. Try regenerating.");
  }

  return `data:${image.inlineData.mimeType};base64,${image.inlineData.data}`;
}

/** Splits the model's "# Title\n\nbody..." reply into its two parts. */
export function parseStory(raw: string): { title: string; body: string } {
  const match = raw.match(/^\s*#\s*(.+?)\n([\s\S]*)$/);
  if (!match) {
    return { title: "Untitled", body: raw.trim() };
  }
  return { title: match[1].trim(), body: match[2].trim() };
}
