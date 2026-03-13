import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

// ---------------------------------------------------------------------------
// FakeWorkerService
// ---------------------------------------------------------------------------

class FakeWorkerService implements AgentHarness {
  final _eventsCtrl = StreamController<BridgeEvent>.broadcast();
  Completer<Map<String, dynamic>>? _turnCompleter;
  bool cancelCalled = false;

  @override
  PromptStrategy get promptStrategy => PromptStrategy.replace;

  @override
  WorkerState get state => WorkerState.idle;

  @override
  Stream<BridgeEvent> get events => _eventsCtrl.stream;

  @override
  Future<void> start() async {}

  @override
  Future<Map<String, dynamic>> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    Map<String, dynamic>? mcpServers,
    bool resume = false,
    String? directory,
    String? model,
  }) {
    _turnCompleter = Completer<Map<String, dynamic>>();
    return _turnCompleter!.future;
  }

  @override
  Future<void> cancel() async {
    cancelCalled = true;
    _turnCompleter?.completeError(StateError('Cancelled'));
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    if (!_eventsCtrl.isClosed) await _eventsCtrl.close();
  }

  void emit(BridgeEvent event) => _eventsCtrl.add(event);
  void completeSuccess() => _turnCompleter?.complete({'ok': true});
  void completeFail(Object error) => _turnCompleter?.completeError(error);
}

// ---------------------------------------------------------------------------
// FakeTurnManager
// ---------------------------------------------------------------------------

class FakeTurnManager extends TurnManager {
  bool _busy = false;
  final Map<String, String> _activeTurns = {};
  final Map<String, TurnOutcome> _outcomes = {};

  FakeTurnManager(MessageService messages, FakeWorkerService worker)
    : super(
        messages: messages,
        worker: worker,
        behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test'),
      );

  void setBusy() {
    _busy = true;
  }

  void clearBusy() => _busy = false;

  @override
  Future<String> reserveTurn(String sessionId, {String agentName = 'main', String? directory, String? model}) async {
    if (_busy) {
      throw BusyTurnException('global busy', isSameSession: false);
    }
    const turnId = 'fake-turn-id';
    _activeTurns[sessionId] = turnId;
    return turnId;
  }

  @override
  void executeTurn(
    String sessionId,
    String turnId,
    List<Map<String, dynamic>> messages, {
    String? source,
    String agentName = 'main',
  }) {
    // no-op: FakeTurnManager doesn't run real async turns
  }

  @override
  void releaseTurn(String sessionId, String turnId) {
    _activeTurns.remove(sessionId);
  }

  @override
  bool isActive(String sessionId) => _activeTurns.containsKey(sessionId);

  @override
  String? activeTurnId(String sessionId) => _activeTurns[sessionId];

  @override
  bool isActiveTurn(String sessionId, String turnId) => _activeTurns[sessionId] == turnId;

  @override
  TurnOutcome? recentOutcome(String sessionId, String turnId) => _outcomes[turnId];

  @override
  Future<TurnOutcome> waitForOutcome(String sessionId, String turnId) {
    return Completer<TurnOutcome>().future; // never completes in tests
  }

  @override
  Future<void> cancelTurn(String sessionId) async {
    _activeTurns.remove(sessionId);
  }

  void setRecentOutcome(String turnId, TurnOutcome outcome) {
    _outcomes[turnId] = outcome;
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Future<String> _errorCode(Response res) async {
  final body = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
  return (body['error'] as Map<String, dynamic>)['code'] as String;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUpAll(() => initTemplates(resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  late Directory tempDir;
  late SessionService sessions;
  late MessageService messages;
  late FakeWorkerService worker;
  late FakeTurnManager turns;
  late Handler handler;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_routes_test_');
    sessions = SessionService(baseDir: tempDir.path);
    messages = MessageService(baseDir: tempDir.path);
    worker = FakeWorkerService();
    turns = FakeTurnManager(messages, worker);
    handler = sessionRoutes(sessions, messages, turns, worker).call;
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  // -------------------------------------------------------------------------
  group('GET /api/sessions', () {
    test('returns 200 with empty list', () async {
      final res = await handler(Request('GET', Uri.parse('http://localhost/api/sessions')));
      expect(res.statusCode, equals(200));
      final list = jsonDecode(await res.readAsString()) as List<dynamic>;
      expect(list, isEmpty);
    });

    test('returns 200 with sessions list', () async {
      await sessions.createSession();
      final res = await handler(Request('GET', Uri.parse('http://localhost/api/sessions')));
      expect(res.statusCode, equals(200));
      final body = await res.readAsString();
      final list = jsonDecode(body) as List<dynamic>;
      expect(list.length, equals(1));
    });

    test('excludes task sessions by default', () async {
      await sessions.createSession(type: SessionType.user);
      await sessions.createSession(type: SessionType.task);

      final res = await handler(Request('GET', Uri.parse('http://localhost/api/sessions')));
      expect(res.statusCode, equals(200));
      final list = jsonDecode(await res.readAsString()) as List<dynamic>;
      expect(list, hasLength(1));
      expect((list.single as Map<String, dynamic>)['type'], 'user');
    });
  });

  // -------------------------------------------------------------------------
  group('POST /api/sessions', () {
    test('returns 201 with created session', () async {
      final res = await handler(Request('POST', Uri.parse('http://localhost/api/sessions')));
      expect(res.statusCode, equals(201));
      final body = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(body.containsKey('id'), isTrue);
      expect(body.containsKey('createdAt'), isTrue);
      expect(body.containsKey('updatedAt'), isTrue);
    });
  });

  // -------------------------------------------------------------------------
  group('PATCH /api/sessions/<id>', () {
    test('returns 200 with updated session (form-urlencoded)', () async {
      final session = await sessions.createSession();
      final res = await handler(
        Request(
          'PATCH',
          Uri.parse('http://localhost/api/sessions/${session.id}'),
          body: 'title=New+Title',
          headers: {'content-type': 'application/x-www-form-urlencoded'},
        ),
      );
      expect(res.statusCode, equals(200));
      final body = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(body['title'], equals('New Title'));
    });

    test('returns 200 with updated session (JSON)', () async {
      final session = await sessions.createSession();
      final res = await handler(
        Request(
          'PATCH',
          Uri.parse('http://localhost/api/sessions/${session.id}'),
          body: jsonEncode({'title': 'JSON Title'}),
          headers: {'content-type': 'application/json'},
        ),
      );
      expect(res.statusCode, equals(200));
      final body = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(body['title'], equals('JSON Title'));
    });

    test('returns 400 for empty title', () async {
      final session = await sessions.createSession();
      final res = await handler(
        Request(
          'PATCH',
          Uri.parse('http://localhost/api/sessions/${session.id}'),
          body: 'title=',
          headers: {'content-type': 'application/x-www-form-urlencoded'},
        ),
      );
      expect(res.statusCode, equals(400));
      expect(await _errorCode(res), equals('INVALID_INPUT'));
    });

    test('returns 404 for unknown session', () async {
      final res = await handler(
        Request(
          'PATCH',
          Uri.parse('http://localhost/api/sessions/nonexistent'),
          body: 'title=Test',
          headers: {'content-type': 'application/x-www-form-urlencoded'},
        ),
      );
      expect(res.statusCode, equals(404));
      expect(await _errorCode(res), equals('SESSION_NOT_FOUND'));
    });

    test('returns 415 for unsupported content type', () async {
      final session = await sessions.createSession();
      final res = await handler(
        Request(
          'PATCH',
          Uri.parse('http://localhost/api/sessions/${session.id}'),
          body: 'title=Test',
          headers: {'content-type': 'text/plain'},
        ),
      );
      expect(res.statusCode, equals(415));
      expect(await _errorCode(res), equals('UNSUPPORTED_MEDIA_TYPE'));
    });
  });

  // -------------------------------------------------------------------------
  group('DELETE /api/sessions/<id>', () {
    test('returns 204 and deletes session', () async {
      final session = await sessions.createSession();
      final deleteRes = await handler(Request('DELETE', Uri.parse('http://localhost/api/sessions/${session.id}')));
      expect(deleteRes.statusCode, equals(204));

      final listRes = await handler(Request('GET', Uri.parse('http://localhost/api/sessions')));
      final list = jsonDecode(await listRes.readAsString()) as List<dynamic>;
      expect(list, isEmpty);
    });

    test('returns 404 for unknown session', () async {
      final res = await handler(Request('DELETE', Uri.parse('http://localhost/api/sessions/nonexistent')));
      expect(res.statusCode, equals(404));
      expect(await _errorCode(res), equals('SESSION_NOT_FOUND'));
    });
  });

  // -------------------------------------------------------------------------
  group('GET /api/sessions/<id>/messages', () {
    test('returns 200 with empty list', () async {
      final session = await sessions.createSession();
      final res = await handler(Request('GET', Uri.parse('http://localhost/api/sessions/${session.id}/messages')));
      expect(res.statusCode, equals(200));
      final list = jsonDecode(await res.readAsString()) as List<dynamic>;
      expect(list, isEmpty);
    });

    test('returns 200 with messages list', () async {
      final session = await sessions.createSession();
      await messages.insertMessage(sessionId: session.id, role: 'user', content: 'Hello');
      final res = await handler(Request('GET', Uri.parse('http://localhost/api/sessions/${session.id}/messages')));
      expect(res.statusCode, equals(200));
      final list = jsonDecode(await res.readAsString()) as List<dynamic>;
      expect(list.length, equals(1));
    });

    test('returns 404 for unknown session', () async {
      final res = await handler(Request('GET', Uri.parse('http://localhost/api/sessions/nonexistent/messages')));
      expect(res.statusCode, equals(404));
      expect(await _errorCode(res), equals('SESSION_NOT_FOUND'));
    });
  });

  // -------------------------------------------------------------------------
  group('POST /api/sessions/<id>/send', () {
    test('returns 200 HTML fragment with sse-connect', () async {
      final session = await sessions.createSession();
      final res = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/sessions/${session.id}/send'),
          body: 'message=Hello',
          headers: {'content-type': 'application/x-www-form-urlencoded'},
        ),
      );
      expect(res.statusCode, equals(200));
      expect(res.headers['content-type'], contains('text/html'));
      final html = await res.readAsString();
      expect(html, contains('sse-connect="/api/sessions/'));
      expect(html, contains('id="streaming-content"'));
      expect(html, contains('class="msg msg-user"'));
      expect(html, contains('class="msg msg-assistant"'));
    });

    test('escapes user message in HTML fragment', () async {
      final session = await sessions.createSession();
      final res = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/sessions/${session.id}/send'),
          body: 'message=%3Cscript%3Ealert(1)%3C%2Fscript%3E',
          headers: {'content-type': 'application/x-www-form-urlencoded'},
        ),
      );
      expect(res.statusCode, equals(200));
      final html = await res.readAsString();
      expect(html, contains('&lt;script&gt;alert(1)&lt;/script&gt;'));
      expect(html, isNot(contains('<script>alert(1)</script>')));
    });

    test('returns 200 HTML fragment via JSON content-type', () async {
      final session = await sessions.createSession();
      final res = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/sessions/${session.id}/send'),
          body: jsonEncode({'message': 'test'}),
          headers: {'content-type': 'application/json'},
        ),
      );
      expect(res.statusCode, equals(200));
      expect(res.headers['content-type'], contains('text/html'));
    });

    test('returns 400 for empty message', () async {
      final session = await sessions.createSession();
      final res = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/sessions/${session.id}/send'),
          body: 'message=',
          headers: {'content-type': 'application/x-www-form-urlencoded'},
        ),
      );
      expect(res.statusCode, equals(400));
      expect(await _errorCode(res), equals('INVALID_INPUT'));
    });

    test('returns 400 for whitespace-only message', () async {
      final session = await sessions.createSession();
      final res = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/sessions/${session.id}/send'),
          body: 'message=%20%20',
          headers: {'content-type': 'application/x-www-form-urlencoded'},
        ),
      );
      expect(res.statusCode, equals(400));
      expect(await _errorCode(res), equals('INVALID_INPUT'));
    });

    test('returns 404 for unknown session', () async {
      final res = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/sessions/nonexistent/send'),
          body: 'message=Hello',
          headers: {'content-type': 'application/x-www-form-urlencoded'},
        ),
      );
      expect(res.statusCode, equals(404));
      expect(await _errorCode(res), equals('SESSION_NOT_FOUND'));
    });

    test('returns 409 AGENT_BUSY_GLOBAL when global cap exceeded', () async {
      final session = await sessions.createSession();
      turns.setBusy();
      final res = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/sessions/${session.id}/send'),
          body: 'message=Hello',
          headers: {'content-type': 'application/x-www-form-urlencoded'},
        ),
      );
      expect(res.statusCode, equals(409));
      expect(await _errorCode(res), equals('AGENT_BUSY_GLOBAL'));
    });

    test('returns 415 for unsupported content type', () async {
      final session = await sessions.createSession();
      final res = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/sessions/${session.id}/send'),
          body: 'message=Hello',
          headers: {'content-type': 'text/plain'},
        ),
      );
      expect(res.statusCode, equals(415));
      expect(await _errorCode(res), equals('UNSUPPORTED_MEDIA_TYPE'));
    });

    test('does not persist user message when busy (atomic reservation)', () async {
      final session = await sessions.createSession();
      turns.setBusy();
      final res = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/sessions/${session.id}/send'),
          body: 'message=Hello',
          headers: {'content-type': 'application/x-www-form-urlencoded'},
        ),
      );
      expect(res.statusCode, equals(409));
      final msgRes = await handler(Request('GET', Uri.parse('http://localhost/api/sessions/${session.id}/messages')));
      final list = jsonDecode(await msgRes.readAsString()) as List<dynamic>;
      expect(list, isEmpty);
    });

    test('returns 400 for malformed JSON body', () async {
      final session = await sessions.createSession();
      final res = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/sessions/${session.id}/send'),
          body: 'not-valid-json{',
          headers: {'content-type': 'application/json'},
        ),
      );
      expect(res.statusCode, equals(400));
      expect(await _errorCode(res), equals('INVALID_INPUT'));
    });

    test('returns 400 for wrong JSON structure (array instead of object)', () async {
      final session = await sessions.createSession();
      final res = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/sessions/${session.id}/send'),
          body: '[1,2,3]',
          headers: {'content-type': 'application/json'},
        ),
      );
      expect(res.statusCode, equals(400));
      expect(await _errorCode(res), equals('INVALID_INPUT'));
    });

    test('persists user message before starting turn', () async {
      final session = await sessions.createSession();
      await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/sessions/${session.id}/send'),
          body: 'message=Hello',
          headers: {'content-type': 'application/x-www-form-urlencoded'},
        ),
      );
      final msgRes = await handler(Request('GET', Uri.parse('http://localhost/api/sessions/${session.id}/messages')));
      final list = jsonDecode(await msgRes.readAsString()) as List<dynamic>;
      expect(list.length, equals(1));
      expect((list[0] as Map<String, dynamic>)['role'], equals('user'));
    });
  });

  // -------------------------------------------------------------------------
  group('typed session lifecycle', () {
    test('GET /api/sessions?type= filters by type', () async {
      await sessions.createSession(type: SessionType.user);
      await sessions.createSession(type: SessionType.main, channelKey: 'main');
      await sessions.createSession(type: SessionType.task);
      final res = await handler(Request('GET', Uri.parse('http://localhost/api/sessions?type=user')));
      expect(res.statusCode, equals(200));
      final list = jsonDecode(await res.readAsString()) as List<dynamic>;
      expect(list.length, equals(1));
      expect((list[0] as Map<String, dynamic>)['type'], equals('user'));
    });

    test('GET /api/sessions?type=task includes task sessions explicitly', () async {
      await sessions.createSession(type: SessionType.user);
      await sessions.createSession(type: SessionType.task);

      final res = await handler(Request('GET', Uri.parse('http://localhost/api/sessions?type=task')));
      expect(res.statusCode, equals(200));
      final list = jsonDecode(await res.readAsString()) as List<dynamic>;
      expect(list.length, equals(1));
      expect((list[0] as Map<String, dynamic>)['type'], equals('task'));
    });

    test('DELETE returns 403 for main session', () async {
      final session = await sessions.createSession(type: SessionType.main, channelKey: 'main');
      final res = await handler(Request('DELETE', Uri.parse('http://localhost/api/sessions/${session.id}')));
      expect(res.statusCode, equals(403));
      expect(await _errorCode(res), equals('FORBIDDEN'));
    });

    test('DELETE returns 403 for channel session', () async {
      final session = await sessions.createSession(type: SessionType.channel, channelKey: 'wa:123');
      final res = await handler(Request('DELETE', Uri.parse('http://localhost/api/sessions/${session.id}')));
      expect(res.statusCode, equals(403));
    });

    test('DELETE returns 403 for task session', () async {
      final session = await sessions.createSession(type: SessionType.task);
      final res = await handler(Request('DELETE', Uri.parse('http://localhost/api/sessions/${session.id}')));
      expect(res.statusCode, equals(403));
      expect(await _errorCode(res), equals('FORBIDDEN'));
    });

    test('DELETE returns 204 for archive session', () async {
      final session = await sessions.createSession(type: SessionType.archive);
      final res = await handler(Request('DELETE', Uri.parse('http://localhost/api/sessions/${session.id}')));
      expect(res.statusCode, equals(204));
    });

    test('POST /send returns 403 for archive session', () async {
      final session = await sessions.createSession(type: SessionType.archive);
      final res = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/sessions/${session.id}/send'),
          body: 'message=Hello',
          headers: {'content-type': 'application/x-www-form-urlencoded'},
        ),
      );
      expect(res.statusCode, equals(403));
      expect(await _errorCode(res), equals('FORBIDDEN'));
    });

    test('POST /send returns 403 for task session', () async {
      final session = await sessions.createSession(type: SessionType.task);
      final res = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/sessions/${session.id}/send'),
          body: 'message=Hello',
          headers: {'content-type': 'application/x-www-form-urlencoded'},
        ),
      );
      expect(res.statusCode, equals(403));
      expect(await _errorCode(res), equals('FORBIDDEN'));
    });

    test('POST /reset returns 403 for archive session', () async {
      final session = await sessions.createSession(type: SessionType.archive);
      handler = sessionRoutes(
        sessions,
        messages,
        turns,
        worker,
        resetService: SessionResetService(sessions: sessions, messages: messages),
      ).call;
      final res = await handler(Request('POST', Uri.parse('http://localhost/api/sessions/${session.id}/reset')));
      expect(res.statusCode, equals(403));
      expect(await _errorCode(res), equals('FORBIDDEN'));
    });

    test('POST /reset returns 403 for task session', () async {
      final session = await sessions.createSession(type: SessionType.task);
      handler = sessionRoutes(
        sessions,
        messages,
        turns,
        worker,
        resetService: SessionResetService(sessions: sessions, messages: messages),
      ).call;
      final res = await handler(Request('POST', Uri.parse('http://localhost/api/sessions/${session.id}/reset')));
      expect(res.statusCode, equals(403));
      expect(await _errorCode(res), equals('FORBIDDEN'));
    });

    test('POST /resume returns 200 and changes archive to user', () async {
      final session = await sessions.createSession(type: SessionType.archive);
      final res = await handler(Request('POST', Uri.parse('http://localhost/api/sessions/${session.id}/resume')));
      expect(res.statusCode, equals(200));
      final body = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(body['type'], equals('user'));
    });

    test('POST /resume returns 400 for non-archive session', () async {
      final session = await sessions.createSession(type: SessionType.user);
      final res = await handler(Request('POST', Uri.parse('http://localhost/api/sessions/${session.id}/resume')));
      expect(res.statusCode, equals(400));
      expect(await _errorCode(res), equals('INVALID_STATE'));
    });

    test('POST /resume returns 404 for unknown session', () async {
      final res = await handler(Request('POST', Uri.parse('http://localhost/api/sessions/nonexistent/resume')));
      expect(res.statusCode, equals(404));
    });

    test('session JSON includes type field', () async {
      await sessions.createSession(type: SessionType.user);
      final res = await handler(Request('GET', Uri.parse('http://localhost/api/sessions')));
      final list = jsonDecode(await res.readAsString()) as List<dynamic>;
      expect((list[0] as Map<String, dynamic>)['type'], equals('user'));
    });
  });

  // -------------------------------------------------------------------------
  group('GET /api/sessions/<id>/stream', () {
    test('returns 404 when turn param is missing', () async {
      final session = await sessions.createSession();
      final res = await handler(Request('GET', Uri.parse('http://localhost/api/sessions/${session.id}/stream')));
      expect(res.statusCode, equals(404));
      expect(await _errorCode(res), equals('TURN_NOT_FOUND'));
    });

    test('returns 404 for unknown turn', () async {
      final session = await sessions.createSession();
      final res = await handler(
        Request('GET', Uri.parse('http://localhost/api/sessions/${session.id}/stream?turn=unknown')),
      );
      expect(res.statusCode, equals(404));
      expect(await _errorCode(res), equals('TURN_NOT_FOUND'));
    });

    test('returns 204 when turn outcome is cached (reconnect guard)', () async {
      final session = await sessions.createSession();
      const turnId = 'fake-turn-id';
      final outcome = TurnOutcome(
        turnId: turnId,
        sessionId: session.id,
        status: TurnStatus.completed,
        completedAt: DateTime.now(),
      );
      turns.setRecentOutcome(turnId, outcome);
      // isActiveTurn returns false (no active entry), recentOutcome returns the outcome
      final res = await handler(
        Request('GET', Uri.parse('http://localhost/api/sessions/${session.id}/stream?turn=$turnId')),
      );
      expect(res.statusCode, equals(204));
    });

    test('returns 200 SSE stream for active turn', () async {
      final session = await sessions.createSession();
      // POST /send to create an active turn in FakeTurnManager
      await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/sessions/${session.id}/send'),
          body: 'message=Hello',
          headers: {'content-type': 'application/x-www-form-urlencoded'},
        ),
      );
      // Now fake-turn-id is active
      final res = await handler(
        Request('GET', Uri.parse('http://localhost/api/sessions/${session.id}/stream?turn=fake-turn-id')),
      );
      expect(res.statusCode, equals(200));
      expect(res.headers['content-type'], contains('text/event-stream'));
    });
  });
}
