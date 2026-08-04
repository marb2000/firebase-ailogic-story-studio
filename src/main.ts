import { generateIllustration, generateStory, parseStory, type StoryLength } from "./ai";

const form = document.querySelector<HTMLFormElement>("#story-form")!;
const topicInput = document.querySelector<HTMLInputElement>("#topic")!;
const lengthSelect = document.querySelector<HTMLSelectElement>("#length")!;
const generateButton = document.querySelector<HTMLButtonElement>("#generate")!;
const regenerateButton = document.querySelector<HTMLButtonElement>("#regenerate")!;

const errorBox = document.querySelector<HTMLParagraphElement>("#error")!;
const result = document.querySelector<HTMLElement>("#result")!;
const titleEl = document.querySelector<HTMLHeadingElement>("#title")!;
const storyEl = document.querySelector<HTMLElement>("#story")!;
const imageSlot = document.querySelector<HTMLDivElement>("#image-slot")!;

/** The story currently on screen, so "Regenerate image" knows what to draw. */
let current: { title: string; body: string } | null = null;
/** Bumped on every regenerate so each image takes a different angle. */
let imageAttempt = 0;

form.addEventListener("submit", async (event) => {
  event.preventDefault();

  const topic = topicInput.value.trim();
  if (!topic) return;

  showError(null);
  setBusy(true);
  result.hidden = false;
  titleEl.textContent = "Writing…";
  storyEl.textContent = "";
  setImagePlaceholder("The illustration comes after the story.");

  try {
    // 1. Write the story. One request, one response — see generateStory().
    const raw = await generateStory(topic, lengthSelect.value as StoryLength);

    current = parseStory(raw);
    titleEl.textContent = current.title;
    renderStory(current.body);

    // 2. Then illustrate it.
    imageAttempt = 0;
    await drawIllustration();
  } catch (error) {
    showError(error);
  } finally {
    setBusy(false);
  }
});

regenerateButton.addEventListener("click", async () => {
  if (!current) return;
  imageAttempt++;
  setBusy(true);
  try {
    await drawIllustration();
  } catch (error) {
    showError(error);
  } finally {
    setBusy(false);
  }
});

async function drawIllustration(): Promise<void> {
  if (!current) return;

  setImagePlaceholder("Illustrating…");
  const dataUrl = await generateIllustration(current.title, current.body, imageAttempt);

  const img = document.createElement("img");
  img.src = dataUrl;
  img.alt = `An illustration of the story "${current.title}"`;
  imageSlot.replaceChildren(img);
}

/** Renders the story as one <p> per blank-line-separated paragraph. */
function renderStory(body: string): void {
  const paragraphs = body.split(/\n{2,}/).filter((p) => p.trim());
  storyEl.replaceChildren(
    ...paragraphs.map((text) => {
      const p = document.createElement("p");
      p.textContent = text.trim();
      return p;
    }),
  );
}

function setImagePlaceholder(message: string): void {
  const span = document.createElement("span");
  span.className = "placeholder";
  span.textContent = message;
  imageSlot.replaceChildren(span);
}

function setBusy(busy: boolean): void {
  generateButton.disabled = busy;
  regenerateButton.disabled = busy || !current;
  document.body.classList.toggle("busy", busy);
}

function showError(error: unknown): void {
  if (!error) {
    errorBox.hidden = true;
    return;
  }
  console.error(error);
  errorBox.hidden = false;
  errorBox.textContent = error instanceof Error ? error.message : String(error);
}
