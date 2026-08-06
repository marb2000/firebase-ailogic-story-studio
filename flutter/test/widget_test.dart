// Basic smoke test for the story parser, which needs no Firebase.
import 'package:flutter_test/flutter_test.dart';
import 'package:story_studio/ai_service.dart';

void main() {
  test('parses a titled story', () {
    final story = Story.parse('# The Lighthouse\n\nIt was a dark night.');
    expect(story.title, 'The Lighthouse');
    expect(story.body, 'It was a dark night.');
  });

  test('falls back when there is no title line', () {
    final story = Story.parse('Just prose, no heading.');
    expect(story.title, 'Untitled');
    expect(story.body, 'Just prose, no heading.');
  });
}
