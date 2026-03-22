import 'dart:convert';

import 'package:dartclaw_core/src/channel/review_command_parser.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

class _FakeGoogleChatRestClient extends GoogleChatRestClient {
  _FakeGoogleChatRestClient() : super(authClient: MockClient((request) async => throw UnimplementedError()));

  @override
  Future<void> testConnection() async {}
}

class _FakeGoogleJwtVerifier extends GoogleJwtVerifier {
  _FakeGoogleJwtVerifier()
    : super(
        audience: const GoogleChatAudienceConfig(
          mode: GoogleChatAudienceMode.appUrl,
          value: 'https://example.com/integrations/googlechat',
        ),
      );

  @override
  Future<bool> verify(String? authHeader) async => true;
}

Map<String, dynamic> _payload({
  String invokedFunction = 'task_accept',
  Object? parameters = const [
    {'key': 'taskId', 'value': 'task-123'},
  ],
}) {
  return {
    'type': 'CARD_CLICKED',
    'space': {'name': 'spaces/AAAA'},
    'common': {'invokedFunction': invokedFunction, 'parameters': parameters},
    'user': {'name': 'users/123', 'displayName': 'Alice'},
  };
}

Future<Response> _post(GoogleChatWebhookHandler handler, Object payload) {
  return handler.handle(
    Request(
      'POST',
      Uri.parse('http://localhost/integrations/googlechat'),
      headers: const {'authorization': 'Bearer token'},
      body: jsonEncode(payload),
    ),
  );
}

void main() {
  late GoogleChatWebhookHandler handler;
  late List<(String, String)> reviewCalls;
  late ChannelReviewResult reviewResult;

  setUp(() {
    reviewCalls = [];
    reviewResult = const ChannelReviewSuccess(taskTitle: 'Fix login', action: 'accept');
    handler = GoogleChatWebhookHandler(
      channel: GoogleChatChannel(config: const GoogleChatConfig(), restClient: _FakeGoogleChatRestClient()),
      jwtVerifier: _FakeGoogleJwtVerifier(),
      config: const GoogleChatConfig(),
      reviewHandler: (taskId, action, {String? comment}) async {
        reviewCalls.add((taskId, action));
        return reviewResult;
      },
    );
  });

  test('routes accept button clicks through the review handler', () async {
    final response = await _post(handler, _payload());
    final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;

    expect(reviewCalls, [('task-123', 'accept')]);
    expect(body['cardsV2'], isA<List<dynamic>>());
  });

  test('accepts parameter maps as well as list entries', () async {
    reviewResult = const ChannelReviewSuccess(taskTitle: 'Fix login', action: 'reject');
    final response = await _post(
      handler,
      _payload(invokedFunction: 'task_reject', parameters: const {'taskId': 'task-456'}),
    );
    final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;

    expect(reviewCalls, [('task-456', 'reject')]);
    expect(body['cardsV2'], isA<List<dynamic>>());
  });

  test('ignores malformed parameter entries when a valid taskId is present', () async {
    final response = await _post(
      handler,
      _payload(
        parameters: [
          null,
          const {'key': 123, 'value': 'ignored'},
          const {'key': 'taskId', 'value': 'task-789'},
          const {'key': 'other', 'value': 123},
        ],
      ),
    );
    final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;

    expect(reviewCalls, [('task-789', 'accept')]);
    expect(body['cardsV2'], isA<List<dynamic>>());
  });

  test('ignores unknown card actions', () async {
    final response = await _post(handler, _payload(invokedFunction: 'unknown'));

    expect(reviewCalls, isEmpty);
    expect(await response.readAsString(), '{}');
  });

  test('returns an error when taskId is missing', () async {
    final response = await _post(handler, _payload(parameters: const []));

    expect(reviewCalls, isEmpty);
    expect(await response.readAsString(), '{"text":"Invalid button action: missing task ID."}');
  });

  test('returns an error when parameters are null or malformed', () async {
    final nullResponse = await _post(handler, _payload(parameters: null));
    final malformedResponse = await _post(
      handler,
      _payload(
        parameters: [
          null,
          const {'key': '', 'value': 'task-123'},
          const {'key': 'taskId'},
          const {'key': 'taskId', 'value': 123},
        ],
      ),
    );

    expect(reviewCalls, isEmpty);
    expect(await nullResponse.readAsString(), '{"text":"Invalid button action: missing task ID."}');
    expect(await malformedResponse.readAsString(), '{"text":"Invalid button action: missing task ID."}');
  });

  test('returns an error when no review handler is configured', () async {
    handler = GoogleChatWebhookHandler(
      channel: GoogleChatChannel(config: const GoogleChatConfig(), restClient: _FakeGoogleChatRestClient()),
      jwtVerifier: _FakeGoogleJwtVerifier(),
      config: const GoogleChatConfig(),
    );

    final response = await _post(handler, _payload());

    expect(await response.readAsString(), '{"text":"Review actions are not available."}');
  });

  test('returns merge conflict cards for conflict results', () async {
    reviewResult = const ChannelReviewMergeConflict(taskTitle: 'Fix login');

    final response = await _post(handler, _payload());
    final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
    final cardEntry = ((body['cardsV2'] as List).single as Map<String, dynamic>)['card'] as Map<String, dynamic>;

    expect((cardEntry['header'] as Map<String, dynamic>)['title'], 'Merge Conflict');
  });

  test('returns plain-text errors for failed reviews', () async {
    reviewResult = const ChannelReviewError('Task task123 is not in review.');

    final response = await _post(handler, _payload());

    expect(await response.readAsString(), '{"text":"Task task123 is not in review."}');
  });
}
