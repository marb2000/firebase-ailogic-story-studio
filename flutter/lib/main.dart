import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'ai_service.dart';
import 'firebase_setup.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeFirebase();
  runApp(const StoryStudioApp());
}

class StoryStudioApp extends StatelessWidget {
  const StoryStudioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Story Studio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFF0A35E),
          brightness: Brightness.dark,
        ),
      ),
      home: const StoryPage(),
    );
  }
}

class StoryPage extends StatefulWidget {
  const StoryPage({super.key});

  @override
  State<StoryPage> createState() => _StoryPageState();
}

class _StoryPageState extends State<StoryPage> {
  final _ai = AiService();
  final _topicController = TextEditingController();

  StoryLength _length = StoryLength.medium;
  Story? _story;
  Uint8List? _image;
  String? _error;
  bool _busy = false;
  bool _illustrating = false;

  /// Bumped on every regenerate so each image takes a different angle.
  int _imageAttempt = 0;

  @override
  void dispose() {
    _topicController.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    final topic = _topicController.text.trim();
    if (topic.isEmpty || _busy) return;

    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _story = null;
      _image = null;
      _imageAttempt = 0;
    });

    try {
      // 1. Write the story.
      final story = await _ai.generateStory(topic, _length);
      if (!mounted) return;
      setState(() => _story = story);

      // 2. Then illustrate it.
      await _illustrate();
    } catch (e) {
      if (mounted) setState(() => _error = _describe(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _illustrate() async {
    final story = _story;
    if (story == null) return;

    setState(() {
      _illustrating = true;
      _error = null;
    });
    try {
      final bytes =
          await _ai.generateIllustration(story, attempt: _imageAttempt);
      if (mounted) setState(() => _image = bytes);
    } catch (e) {
      if (mounted) setState(() => _error = _describe(e));
    } finally {
      if (mounted) setState(() => _illustrating = false);
    }
  }

  Future<void> _regenerate() async {
    if (_illustrating || _busy) return;
    _imageAttempt++;
    await _illustrate();
  }

  String _describe(Object e) => e.toString().replaceFirst('Exception: ', '');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('📖 Story Studio'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: Padding(
            padding: const EdgeInsets.only(left: 16, right: 16, bottom: 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Gemini writes it, Nano Banana draws it.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 48),
        children: [
          _buildForm(theme),
          if (_error != null) ...[
            const SizedBox(height: 16),
            _buildError(theme),
          ],
          if (_story != null) ...[
            const SizedBox(height: 28),
            Text(_story!.title, style: theme.textTheme.headlineSmall),
            const SizedBox(height: 16),
            _buildIllustration(theme),
            const SizedBox(height: 20),
            Text(_story!.body, style: theme.textTheme.bodyLarge?.copyWith(height: 1.6)),
          ],
        ],
      ),
    );
  }

  Widget _buildForm(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _topicController,
              decoration: const InputDecoration(
                labelText: 'What should the story be about?',
                hintText: 'A lighthouse keeper who befriends a storm',
                border: OutlineInputBorder(),
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _generate(),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<StoryLength>(
              initialValue: _length,
              decoration: const InputDecoration(
                labelText: 'How long?',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final l in StoryLength.values)
                  DropdownMenuItem(value: l, child: Text(l.label)),
              ],
              onChanged: (v) => setState(() => _length = v ?? _length),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _generate,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(_busy ? 'Writing…' : 'Tell me a story'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildError(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        _error!,
        style: TextStyle(color: theme.colorScheme.onErrorContainer),
      ),
    );
  }

  Widget _buildIllustration(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(
          aspectRatio: 4 / 3,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Container(
              color: theme.colorScheme.surfaceContainerHighest,
              child: _image != null
                  ? Image.memory(_image!, fit: BoxFit.cover)
                  : Center(
                      child: _illustrating
                          ? const CircularProgressIndicator()
                          : const Text('No illustration yet'),
                    ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: (_illustrating || _busy) ? null : _regenerate,
            icon: const Icon(Icons.casino_outlined, size: 18),
            label: const Text('Regenerate image'),
          ),
        ),
      ],
    );
  }
}
