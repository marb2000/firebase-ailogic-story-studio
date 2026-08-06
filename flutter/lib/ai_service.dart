import 'dart:typed_data';

import 'package:firebase_ai/firebase_ai.dart';

/// How long a story should be.
enum StoryLength {
  short('Short — a few paragraphs', 'about 150 words'),
  medium('Medium — a page or so', 'about 400 words'),
  long('Long — settle in', 'about 900 words');

  const StoryLength(this.label, this.hint);

  final String label;
  final String hint;
}

/// A generated story, split into its title and body.
class Story {
  const Story(this.title, this.body);

  final String title;
  final String body;

  /// Splits the model's "# Title\n\nbody..." reply into its two parts.
  factory Story.parse(String raw) {
    final match = RegExp(r'^\s*#\s*(.+?)\n([\s\S]*)$').firstMatch(raw);
    if (match == null) {
      return Story('Untitled', raw.trim());
    }
    return Story(match.group(1)!.trim(), match.group(2)!.trim());
  }
}

/// Everything this app asks of Firebase AI Logic.
///
/// The app never holds a Gemini API key. Requests go to Firebase, which checks
/// the App Check token and calls the model on our behalf.
class AiService {
  /// The Agent Platform Gemini API (formerly Vertex AI).
  ///
  /// The default location is `global`, which is where the newest Gemini models
  /// land first — a pinned region like `us-central1` returns 404 for them.
  final _ai = FirebaseAI.agentPlatform();

  /// Writes the story. Text out.
  late final _storyModel = _ai.generativeModel(
    model: 'gemini-3.6-flash',
    systemInstruction: Content.system(
      'You are a vivid, warm short-story writer. '
      "Reply with the title on the first line as '# Title', then a blank line, "
      'then the story as plain prose paragraphs. '
      'No headings inside the story, no bullet lists, no commentary about the task.',
    ),
  );

  /// Draws the illustration. The same generativeModel API as above — the only
  /// difference is asking for an image response modality instead of text.
  /// "gemini-3.1-flash-image" is Nano Banana 2.
  late final _imageModel = _ai.generativeModel(
    model: 'gemini-3.1-flash-image',
    generationConfig: GenerationConfig(
      responseModalities: [ResponseModalities.image],
    ),
  );

  /// Generates a story about [topic].
  ///
  /// This is the unary `generateContent`, not `generateContentStream`, on
  /// purpose: **AI Logic Cloud Triggers don't fire on streamed calls.**
  /// Streaming would give a nicer typewriter effect and silently skip the
  /// before/after hooks, which is exactly the sort of bypass they exist to
  /// prevent.
  Future<Story> generateStory(String topic, StoryLength length) async {
    final prompt = 'Write a story about: $topic\n\nLength: ${length.hint}.';
    final response = await _storyModel.generateContent([Content.text(prompt)]);
    return Story.parse(response.text ?? '');
  }

  /// Different angles for the illustration, so "Regenerate" gives a genuinely
  /// different picture instead of the same one twice.
  static const _angles = [
    'a wide establishing shot of the setting',
    'an intimate close-up of the main character mid-moment',
    "the story's turning point, caught in action",
    'a quiet detail from the story, rendered large and symbolic',
  ];

  /// Generates one illustration for a story and returns the raw image bytes.
  ///
  /// [attempt] counts up each time the user taps Regenerate; it picks a
  /// different angle so the results actually differ.
  Future<Uint8List> generateIllustration(Story story, {int attempt = 0}) async {
    final angle = _angles[attempt % _angles.length];
    final excerpt =
        story.body.length > 1500 ? story.body.substring(0, 1500) : story.body;

    final prompt = [
      'Illustrate this short story, titled "${story.title}".',
      'Compose it as $angle.',
      'Style: rich, painterly children\'s-book illustration. '
          'No text or lettering in the image.',
      '',
      'The story:',
      excerpt,
    ].join('\n');

    final response = await _imageModel.generateContent([Content.text(prompt)]);

    // The response is a list of parts; inlineDataParts pulls out the binary ones.
    final image = response.inlineDataParts.firstOrNull;
    if (image == null) {
      throw Exception("The model replied without an image. Try regenerating.");
    }
    return image.bytes;
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
