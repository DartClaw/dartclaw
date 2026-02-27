import 'dart:async';
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
  bool cancelCalled = false;
  bool stopCalled = false;
  bool disposeCalled = false;

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
    disposeCalled = true;
    if (!_eventsCtrl.isClosed) await _eventsCtrl.close();
  }

  void completeSuccess() => _turnCompleter?.complete({'ok': true});
  Future<void> closeEvents() => _eventsCtrl.close();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Resolves static dir whether tests run from project root or package root.
String _staticDir() {
  final fromPkg = 'lib/src/static';
  if (Directory(fromPkg).existsSync()) return fromPkg;
  return p.join('packages', 'dartclaw_server', fromPkg);
}

void main() {
  late Directory tempDir;
  late SessionService sessions;
  late MessageService messages;
  late FakeWorkerService worker;
  late DartclawServer server;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_server_test_');
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
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('shutdown', () {
    test('cancels active turn then stops worker', () async {
      final session = await sessions.createSession();
      final sessionId = session.id;

      final handler = server.handler;

      // Fire POST /api/sessions/<id>/send to start a turn. Don't await — the
      // handler blocks until the turn completes, but we need to call shutdown
      // while it's still running.
      unawaited(
        Future(() async {
          await handler(
            Request(
              'POST',
              Uri.parse('http://localhost/api/sessions/$sessionId/send'),
              body: '{"message": "hello"}',
              headers: {'content-type': 'application/json'},
            ),
          );
        }),
      );

      // Let the event loop process so the turn actually starts.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await server.shutdown();

      expect(worker.cancelCalled, isTrue, reason: 'shutdown should cancel active turns');
      expect(worker.disposeCalled, isTrue, reason: 'shutdown should dispose the worker');
    });

    test('stops worker when no turns are active', () async {
      await server.shutdown();

      expect(worker.cancelCalled, isFalse, reason: 'no active turns to cancel');
      expect(worker.disposeCalled, isTrue, reason: 'worker.dispose() always called');
    });

    test('does not cancel after turn already completed', () async {
      final session = await sessions.createSession();
      final sessionId = session.id;

      final handler = server.handler;

      // Start a turn and let it complete before shutdown.
      unawaited(
        Future(() async {
          await handler(
            Request(
              'POST',
              Uri.parse('http://localhost/api/sessions/$sessionId/send'),
              body: '{"message": "hi"}',
              headers: {'content-type': 'application/json'},
            ),
          );
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      worker.completeSuccess();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Turn completed — no active sessions now.
      await server.shutdown();

      expect(worker.cancelCalled, isFalse, reason: 'no active turn to cancel after completion');
      expect(worker.disposeCalled, isTrue, reason: 'worker.dispose() always called');
    });
  });
}
