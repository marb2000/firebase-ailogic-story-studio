/// AI Logic Cloud Triggers, written in Dart.
///
/// The Dart Functions SDK has no `beforeGenerateContent` helper — the AI Logic
/// trigger types only exist in the Node SDK. But it doesn't need one:
///
///   In firebase-functions (Node), `BlockingFunction = HttpsFunction`.
///
/// An AI Logic trigger *is* an HTTPS function. The Node helper only parses the
/// request body, calls your callback, and writes JSON back. HTTPS functions are
/// the one trigger type that is production-ready in Dart, so we implement that
/// contract by hand.
///
/// The wire contract, read from the Node SDK
/// (`firebase-functions/lib/v2/providers/ai/index.js`):
///
///   Request   POST, JSON body = the event
///   Allow     200 with `{}`
///   Modify    200 with the full modified object plus an `@type` field
///   Reject    500 with `{"code": <rpc code>, "message": "..."}`
///
/// Deploying this is only half the job — the Firebase CLI won't recognise a
/// plain `onRequest` as an AI Logic trigger, so you register it yourself.
/// See ../docs/dart-cloud-triggers.md.
library;

import 'dart:convert';

import 'package:firebase_functions/firebase_functions.dart';

/// `event.data.api` value for the Agent Platform (Vertex AI) Gemini API.
const _vertexV1Beta1 = 'google.cloud.aiplatform.v1beta1';

/// The `@type` tag a modified Vertex request must carry.
const _vertexRequestType =
    'type.googleapis.com/google.cloud.aiplatform.v1beta1.GenerateContentRequest';

/// gRPC status codes, from the Node SDK's `rpcCodeMap`.
const _invalidArgument = 3;

/// Story topics this app won't write about.
const _blockedTopics = ['weapon', 'explosive', 'self-harm'];

/// A ceiling on story length, so no client can request an expensive run.
const _maxOutputTokens = 4000;

void main() {
  runFunctions((firebase) {
    firebase.https.onRequest(
      name: 'dartGuardStoryPrompts',
      (request) async {
        final event =
            jsonDecode(await request.readAsString()) as Map<String, dynamic>;
        final data = (event['data'] as Map?)?.cast<String, dynamic>() ?? {};

        logger.info('Dart trigger fired', {
          'model': data['model'],
          'appId': event['appId'],
          'authType': event['authType'],
        });

        // The Gemini Developer API and Agent Platform Gemini API have
        // different request shapes. Only handle the one this app uses.
        if (data['api'] != _vertexV1Beta1) {
          return _allowUnchanged();
        }

        final aiRequest =
            (data['request'] as Map?)?.cast<String, dynamic>() ?? {};

        // Walk contents[] -> parts[] -> text.
        final prompt = ((aiRequest['contents'] as List?) ?? [])
            .expand((c) => ((c as Map?)?['parts'] as List?) ?? [])
            .map((p) => ((p as Map?)?['text'] as String?) ?? '')
            .join(' ')
            .toLowerCase();

        final blocked =
            _blockedTopics.where((t) => prompt.contains(t)).firstOrNull;
        if (blocked != null) {
          logger.warn('Blocked a prompt', {'topic': blocked});
          // A 500 with an rpc code is how the Node SDK signals a rejection.
          // The model never runs. The message stays in the logs — it does not
          // reach the client.
          return Response(
            500,
            body: jsonEncode({
              'code': _invalidArgument,
              'message': "Story Studio doesn't write about $blocked.",
            }),
            headers: {'content-type': 'application/json'},
          );
        }

        // Image models return the picture as output tokens, so a text-sized
        // cap would truncate it. `model` is a full resource path, so match on
        // a substring rather than equality.
        final model = (data['model'] as String?) ?? '';
        if (model.contains('image')) {
          return _allowUnchanged();
        }

        // Return the *whole* request, edited — not just the changed fields.
        final generationConfig =
            (aiRequest['generationConfig'] as Map?)?.cast<String, dynamic>() ??
                {};
        final requested = generationConfig['maxOutputTokens'] as int?;

        return Response.ok(
          jsonEncode({
            ...aiRequest,
            'generationConfig': {
              ...generationConfig,
              'maxOutputTokens': requested == null
                  ? _maxOutputTokens
                  : (requested < _maxOutputTokens ? requested : _maxOutputTokens),
            },
            '@type': _vertexRequestType,
          }),
          headers: {'content-type': 'application/json'},
        );
      },
    );
  });
}

/// An empty 200 leaves the request exactly as the client sent it.
Response _allowUnchanged() => Response.ok(
      '{}',
      headers: {'content-type': 'application/json'},
    );

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
