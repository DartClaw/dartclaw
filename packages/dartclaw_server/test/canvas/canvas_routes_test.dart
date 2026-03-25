import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

class _TurnCall {
  final String sessionId;
  final List<Map<String, dynamic>> messages;
  final String? source;
  final bool isHumanInput;

  const _TurnCall({required this.sessionId, required this.messages, required this.source, required this.isHumanInput});
}

class _RecordingTurnManager extends TurnManager {
  final List<_TurnCall> calls = [];

  _RecordingTurnManager({required super.messages, required super.worker})
    : super(behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test'));

  @override
  Future<String> startTurn(
    String sessionId,
    List<Map<String, dynamic>> messages, {
    String? source,
    String agentName = 'main',
    String? model,
    String? effort,
    bool isHumanInput = false,
  }) async {
    calls.add(_TurnCall(sessionId: sessionId, messages: messages, source: source, isHumanInput: isHumanInput));
    return 'turn-${calls.length}';
  }
}

void main() {
  group('canvasRoutes', () {
    late Directory tempDir;
    late SessionService sessions;
    late MessageService messages;
    late FakeAgentHarness worker;
    late _RecordingTurnManager turns;
    late CanvasService canvasService;
    late Handler handler;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('dartclaw_canvas_routes_test_');
      sessions = SessionService(baseDir: tempDir.path);
      messages = MessageService(baseDir: tempDir.path);
      worker = FakeAgentHarness();
      turns = _RecordingTurnManager(messages: messages, worker: worker);
      canvasService = CanvasService();
      handler = canvasRoutes(canvasService: canvasService, turns: turns, sessions: sessions).call;
    });

    tearDown(() async {
      await canvasService.dispose();
      await messages.dispose();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('POST /<token>/action with interact token injects formatted canvas message', () async {
      final sessionKey = SessionKey.webSession();
      final shareToken = canvasService.createShareToken(sessionKey, permission: CanvasPermission.interact);
      final response = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/${shareToken.token}/action'),
          headers: {'content-type': 'application/json', 'cookie': 'canvas_nickname=Alice'},
          body: jsonEncode({
            'action': 'vote',
            'payload': {'vote': 'A'},
          }),
        ),
      );

      expect(response.statusCode, 200);
      expect(turns.calls, hasLength(1));
      final call = turns.calls.single;
      expect(call.source, 'canvas');
      expect(call.isHumanInput, isTrue);
      expect(call.messages, hasLength(1));
      expect(call.messages.single['role'], 'user');
      expect(call.messages.single['content'], '[Canvas] vote: {"vote":"A"} (from: Alice via canvas)');

      final createdSession = await sessions.getSession(call.sessionId);
      expect(createdSession, isNotNull);
      expect(createdSession!.channelKey, sessionKey);
      expect(createdSession.type, SessionType.channel);
    });

    test('POST /<token>/action with view-only token returns 404', () async {
      final shareToken = canvasService.createShareToken('session-view', permission: CanvasPermission.view);
      final response = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/${shareToken.token}/action'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({'action': 'vote', 'payload': 'A'}),
        ),
      );

      expect(response.statusCode, 404);
      expect(turns.calls, isEmpty);
    });

    test('GET /<token>/stream sends current canvas state as first SSE event', () async {
      final sessionKey = SessionKey.webSession();
      final shareToken = canvasService.createShareToken(sessionKey);
      canvasService.push(sessionKey, '<h1>Live</h1>');

      final response = await handler(Request('GET', Uri.parse('http://localhost/${shareToken.token}/stream')));
      expect(response.statusCode, 200);
      expect(response.headers['content-type'], 'text/event-stream');

      final firstFrame = await response.read().transform(utf8.decoder).first;
      expect(firstFrame, startsWith('event: canvas_state\n'));
      expect(firstFrame, contains('"html":"<h1>Live</h1>"'));
    });
  });
}
