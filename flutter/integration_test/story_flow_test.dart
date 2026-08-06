// End-to-end test against the real Firebase project.
//
// This talks to live AI Logic, so it needs App Check debug tokens:
//
//   flutter test integration_test/story_flow_test.dart \
//     -d <simulator-udid> \
//     --dart-define=APPCHECK_DEBUG_TOKEN_IOS=...
//
// The second test is the interesting one: it proves the project's AI Logic
// Cloud Triggers apply to this Flutter app without the app knowing anything
// about them.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:story_studio/firebase_setup.dart';
import 'package:story_studio/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async => initializeFirebase());

  /// Pumps repeatedly until [condition] holds or [timeout] elapses.
  /// `pumpAndSettle` is no good here — a network call in flight never settles.
  Future<void> pumpUntil(
    WidgetTester tester,
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (condition()) return;
      await tester.pump(const Duration(milliseconds: 500));
    }
    fail('Timed out after $timeout');
  }

  testWidgets('generates a story and an illustration', (tester) async {
    await tester.pumpWidget(const StoryStudioApp());
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField),
      'A lighthouse keeper who befriends a storm',
    );
    await tester.tap(find.text('Tell me a story'));
    await tester.pump();

    // The story lands first, then the illustration.
    await pumpUntil(tester, () => find.byType(Image).evaluate().isNotEmpty);

    expect(find.byType(Image), findsOneWidget);
    // A real story is far longer than the placeholder text.
    final body = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .reduce((a, b) => a.length > b.length ? a : b);
    expect(body.length, greaterThan(200));
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('the project Cloud Trigger blocks a disallowed topic',
      (tester) async {
    await tester.pumpWidget(const StoryStudioApp());
    await tester.pumpAndSettle();

    // "weapon" is on the blocklist inside guardStoryPrompts, a Cloud Function
    // deployed to this project. Nothing in this app knows about that list.
    await tester.enterText(
      find.byType(TextField),
      'A blacksmith forging a legendary weapon',
    );
    await tester.tap(find.text('Tell me a story'));
    await tester.pump();

    await pumpUntil(
      tester,
      () => find
          .textContaining(RegExp(r'error|Error|failed|blocked', caseSensitive: false))
          .evaluate()
          .isNotEmpty,
    );
  }, timeout: const Timeout(Duration(minutes: 3)));
}
