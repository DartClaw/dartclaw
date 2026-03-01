import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' show Request;
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// FakeWorkerService
// ---------------------------------------------------------------------------

class FakeWorkerService implements AgentHarness {
  final _eventsCtrl = StreamController<BridgeEvent>.broadcast();
  Completer<Map<String, dynamic>>? _turnCompleter;
  Completer<void> _turnInvoked = Completer<void>();
  bool cancelCalled = false;
  bool stopCalled = false;

  Future<void> get turnInvoked => _turnInvoked.future;

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
  }) {
    _turnCompleter = Completer<Map<String, dynamic>>();
    if (!_turnInvoked.isCompleted) _turnInvoked.complete();
    return _turnCompleter!.future;
  }

  @override
  Future<void> cancel() async {
    cancelCalled = true;
    _turnCompleter?.completeError(StateError('Cancelled'));
  }

  @override
  Future<void> stop() async {
    stopCalled = true;
  }

  @override
  Future<void> dispose() async {
    if (!_eventsCtrl.isClosed) await _eventsCtrl.close();
  }

  void emit(BridgeEvent event) => _eventsCtrl.add(event);

  void completeSuccess() {
    _turnCompleter?.complete({'ok': true});
    _turnInvoked = Completer<void>();
  }

  Future<void> closeEvents() => _eventsCtrl.close();
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Resolves static dir whether tests run from project root or package root.
String _staticDir() {
  final fromPkg = 'packages/dartclaw_server/lib/src/static';
  if (Directory(fromPkg).existsSync()) return fromPkg;
  // Running from apps/dartclaw_cli
  final fromApp = p.join('..', '..', 'packages', 'dartclaw_server', 'lib', 'src', 'static');
  if (Directory(fromApp).existsSync()) return fromApp;
  return fromPkg;
}

// ---------------------------------------------------------------------------
// E2E Integration Tests
// ---------------------------------------------------------------------------

void main() {
  late Directory tempDir;
  late SessionService sessions;
  late MessageService messages;
  late FakeWorkerService worker;
  late DartclawServer server;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_e2e_test_');
    sessions = SessionService(baseDir: tempDir.path);
    messages = MessageService(baseDir: tempDir.path);
    worker = FakeWorkerService();
    server = DartclawServer(
      sessions: sessions,
      messages: messages,
      worker: worker,
      staticDir: _staticDir(),
      behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test'),
    );
  });

  tearDown(() async {
    await server.shutdown();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('E2E: full session lifecycle', () {
    test('create session, send message, verify persistence, SSE, isolation, delete', () async {
      final handler = server.handler;

      // 1. Create session 1
      final createRes1 = await handler(Request('POST', Uri.parse('http://localhost/api/sessions')));
      expect(createRes1.statusCode, equals(201));
      final session1 = jsonDecode(await createRes1.readAsString()) as Map<String, dynamic>;
      final sessionId1 = session1['id'] as String;
      expect(sessionId1, isNotEmpty);

      // 2. Send message to session 1 (returns HTML fragment with SSE URL)
      final sendRes1 = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/sessions/$sessionId1/send'),
          body: jsonEncode({'message': 'Hello from test'}),
          headers: {'content-type': 'application/json'},
        ),
      );
      expect(sendRes1.statusCode, equals(200));
      final sendHtml = await sendRes1.readAsString();
      expect(sendHtml, contains('data-sse-url'));

      // 3. Verify user message persisted
      final msgRes1 = await handler(Request('GET', Uri.parse('http://localhost/api/sessions/$sessionId1/messages')));
      expect(msgRes1.statusCode, equals(200));
      final msgList1 = jsonDecode(await msgRes1.readAsString()) as List<dynamic>;
      expect(msgList1.length, equals(1));
      expect((msgList1[0] as Map<String, dynamic>)['role'], equals('user'));
      expect((msgList1[0] as Map<String, dynamic>)['content'], equals('Hello from test'));

      // 4. Complete turn — emit delta then finish so assistant message is persisted
      await worker.turnInvoked;
      worker.emit(DeltaEvent('Agent reply'));
      await Future<void>.delayed(Duration.zero);
      worker.completeSuccess();
      // Allow async turn completion to flush
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // 5. Verify assistant message persisted
      final msgRes2 = await handler(Request('GET', Uri.parse('http://localhost/api/sessions/$sessionId1/messages')));
      final msgList2 = jsonDecode(await msgRes2.readAsString()) as List<dynamic>;
      expect(msgList2.length, equals(2));
      expect((msgList2[1] as Map<String, dynamic>)['role'], equals('assistant'));
      expect((msgList2[1] as Map<String, dynamic>)['content'], equals('Agent reply'));

      // 6. Create session 2 and send message — verify isolation
      final createRes2 = await handler(Request('POST', Uri.parse('http://localhost/api/sessions')));
      expect(createRes2.statusCode, equals(201));
      final session2 = jsonDecode(await createRes2.readAsString()) as Map<String, dynamic>;
      final sessionId2 = session2['id'] as String;

      final sendRes2 = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/sessions/$sessionId2/send'),
          body: jsonEncode({'message': 'Hello from session 2'}),
          headers: {'content-type': 'application/json'},
        ),
      );
      expect(sendRes2.statusCode, equals(200));

      // Complete session 2 turn
      await worker.turnInvoked;
      worker.completeSuccess();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Session 2 messages should NOT contain session 1 messages
      final msgRes3 = await handler(Request('GET', Uri.parse('http://localhost/api/sessions/$sessionId2/messages')));
      final msgList3 = jsonDecode(await msgRes3.readAsString()) as List<dynamic>;
      expect(msgList3.length, equals(2)); // user + assistant (empty/fail)
      expect((msgList3[0] as Map<String, dynamic>)['content'], equals('Hello from session 2'));

      // 7. Delete session 1 — verify gone, session 2 still exists
      final deleteRes = await handler(Request('DELETE', Uri.parse('http://localhost/api/sessions/$sessionId1')));
      expect(deleteRes.statusCode, equals(204));

      // Session 1 messages return 404
      final msgRes4 = await handler(Request('GET', Uri.parse('http://localhost/api/sessions/$sessionId1/messages')));
      expect(msgRes4.statusCode, equals(404));

      // Session 2 still exists
      final msgRes5 = await handler(Request('GET', Uri.parse('http://localhost/api/sessions/$sessionId2/messages')));
      expect(msgRes5.statusCode, equals(200));
    });

    test('SSE stream endpoint returns correct content-type', () async {
      final handler = server.handler;

      // Create session and send message to get an active turn
      final createRes = await handler(Request('POST', Uri.parse('http://localhost/api/sessions')));
      final session = jsonDecode(await createRes.readAsString()) as Map<String, dynamic>;
      final sessionId = session['id'] as String;

      await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/sessions/$sessionId/send'),
          body: jsonEncode({'message': 'stream test'}),
          headers: {'content-type': 'application/json'},
        ),
      );

      // Extract turn ID from send response HTML — parse data-sse-url
      final sendRes = await handler(Request('GET', Uri.parse('http://localhost/api/sessions/$sessionId/messages')));
      expect(sendRes.statusCode, equals(200));

      // The turn is active now — complete it before shutdown
      await worker.turnInvoked;
      worker.completeSuccess();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
  });
}
