import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show Message;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../session_turn_manager_test_support.dart';

void main() {
  late Directory root;
  late SessionService sessions;
  late MessageService messages;
  late Handler handler;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dartclaw_history_routes_');
    sessions = SessionService(baseDir: root.path);
    messages = MessageService(baseDir: root.path);
    final worker = FakeAgentHarness();
    handler = sessionRoutes(sessions, messages, FakeTurnManager(messages, worker), worker).call;
  });

  tearDown(() async {
    await messages.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('bounded windows preserve cursor anchor lineage and explicit unavailable targets', () async {
    final session = await sessions.createSession();
    final written = <Message>[];
    for (var index = 0; index < 240; index++) {
      written.add(
        await messages.insertMessage(
          sessionId: session.id,
          role: index.isEven ? 'user' : 'assistant',
          content: 'm$index',
        ),
      );
    }

    final tail = await _get(handler, '/api/sessions/${session.id}/messages?count=100');
    expect((tail['messages'] as List), hasLength(100));
    expect(tail['earliest_cursor'], 141);
    expect(tail['has_earlier'], isTrue);

    final before = await _get(handler, '/api/sessions/${session.id}/messages?count=100&before_cursor=141');
    expect((before['messages'] as List), hasLength(100));
    expect(before['earliest_cursor'], 41);

    final around = await _get(
      handler,
      '/api/sessions/${session.id}/messages?count=25&around_message_id=${written[20].id}',
    );
    expect((around['messages'] as List).map((item) => (item as Map)['id']), contains(written[20].id));
    expect((around['target'] as Map)['state'], 'available');

    final unavailable = await _get(
      handler,
      '/api/sessions/${session.id}/messages?around_message_id=00000000-0000-4000-8000-000000000099',
    );
    expect((unavailable['messages'] as List), isEmpty);
    expect((unavailable['target'] as Map)['state'], 'unavailable');

    final now = DateTime.utc(2026, 9, 14);
    var state = await sessions.getConversationState(session.id);
    state = state.put(
      ConversationSubmissionClaim(
        submissionId: 'removed-submission',
        revisionId: 'removed-revision',
        messageId: written[20].id,
        payloadDigest: 'removed-digest',
        message: written[20].content,
        commitState: SubmissionCommitState.committed,
        workState: ConversationWorkState.removed,
        createdAt: now,
        updatedAt: now,
      ),
    );
    await sessions.updateConversationState(session.id, state);
    final removed = await _get(handler, '/api/sessions/${session.id}/messages?around_message_id=${written[20].id}');
    expect((removed['messages'] as List), isEmpty);
    expect((removed['target'] as Map)['state'], 'unavailable');

    final malformed = await handler(
      Request('GET', Uri.parse('http://localhost/api/sessions/${session.id}/messages?before_cursor=invalid')),
    );
    expect(malformed.statusCode, 400);

    final combined = await handler(
      Request(
        'GET',
        Uri.parse(
          'http://localhost/api/sessions/${session.id}/messages?before_cursor=20&around_message_id=${written[10].id}',
        ),
      ),
    );
    expect(combined.statusCode, 400);
    final oversized = await handler(
      Request('GET', Uri.parse('http://localhost/api/sessions/${session.id}/messages?count=201')),
    );
    expect(oversized.statusCode, 400);

    final filteredSession = await sessions.createSession();
    final filteredMessages = <Message>[];
    for (var index = 0; index < 240; index += 1) {
      filteredMessages.add(
        await messages.insertMessage(sessionId: filteredSession.id, role: 'user', content: 'filtered-$index'),
      );
    }
    var filteredState = await sessions.getConversationState(filteredSession.id);
    for (var index = 140; index < filteredMessages.length; index += 1) {
      final message = filteredMessages[index];
      filteredState = filteredState.put(
        ConversationSubmissionClaim(
          submissionId: 'hidden-$index',
          revisionId: 'hidden-r$index',
          messageId: message.id,
          payloadDigest: 'hidden-digest-$index',
          message: message.content,
          commitState: SubmissionCommitState.committed,
          workState: ConversationWorkState.held,
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
    await sessions.updateConversationState(filteredSession.id, filteredState);
    final filteredTail = await _get(handler, '/api/sessions/${filteredSession.id}/messages?count=100');
    final visible = filteredTail['messages'] as List;
    expect(visible, hasLength(100));
    expect((visible.first as Map)['cursor'], 41);
    expect((visible.last as Map)['cursor'], 140);
    expect(filteredTail['has_earlier'], isTrue);
  });
}

Future<Map<String, dynamic>> _get(Handler handler, String path) async {
  final response = await handler(Request('GET', Uri.parse('http://localhost$path')));
  expect(response.statusCode, 200);
  return jsonDecode(await response.readAsString()) as Map<String, dynamic>;
}
