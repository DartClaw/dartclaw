import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String sessionsDir;
  late String workspaceDir;
  late SessionService sessions;
  late MessageService messages;
  late _FastFakeWorker worker;
  late Database turnStateDb;
  late TurnStateStore turnState;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('turn_runner_rate_limit_test_');
    sessionsDir = p.join(tempDir.path, 'sessions');
    workspaceDir = p.join(tempDir.path, 'workspace');
    Directory(sessionsDir).createSync(recursive: true);
    Directory(workspaceDir).createSync(recursive: true);

    sessions = SessionService(baseDir: sessionsDir);
    messages = MessageService(baseDir: sessionsDir);
    worker = _FastFakeWorker();
    turnStateDb = sqlite3.openInMemory();
    turnState = TurnStateStore(turnStateDb);
  });

  tearDown(() async {
    await messages.dispose();
    await worker.dispose();
    await turnState.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  TurnRunner buildRunner({SlidingWindowRateLimiter? globalRateLimiter, _RecordingSseBroadcast? sse}) {
    return TurnRunner(
      harness: worker,
      messages: messages,
      behavior: BehaviorFileService(workspaceDir: workspaceDir),
      sessions: sessions,
      turnState: turnState,
      globalRateLimiter: globalRateLimiter,
      sseBroadcast: sse,
    );
  }

  group('TurnRunner — global rate limiting', () {
    test('turns within limit — reserve succeeds immediately', () async {
      final limiter = SlidingWindowRateLimiter(limit: 5, window: const Duration(minutes: 1));
      final runner = buildRunner(globalRateLimiter: limiter);

      final session = await sessions.getOrCreateMain();
      worker.responseText = 'done';
      final turnId = await runner.reserveTurn(session.id).timeout(const Duration(seconds: 2));

      expect(turnId, isNotEmpty);
      runner.executeTurn(session.id, turnId, [
        {'role': 'user', 'content': 'test'},
      ]);
      await runner.waitForOutcome(session.id, turnId);
    });

    test('no rate limiter — no limiting (backward compat)', () async {
      final runner = buildRunner(); // no globalRateLimiter

      final session = await sessions.getOrCreateMain();
      worker.responseText = 'done';
      final turnId = await runner.reserveTurn(session.id).timeout(const Duration(seconds: 2));

      expect(turnId, isNotEmpty);
      runner.executeTurn(session.id, turnId, [
        {'role': 'user', 'content': 'test'},
      ]);
      await runner.waitForOutcome(session.id, turnId);
    });

    test('80% warning — emitted once when crossing threshold', () async {
      final sse = _RecordingSseBroadcast();
      // limit of 5, use 4 (80%) via injectable now
      final t0 = DateTime.now();
      final limiter = SlidingWindowRateLimiter(limit: 5, window: const Duration(minutes: 1));
      // Pre-fill 4 events to reach 80%
      limiter.check('global', now: t0);
      limiter.check('global', now: t0.add(const Duration(seconds: 1)));
      limiter.check('global', now: t0.add(const Duration(seconds: 2)));
      limiter.check('global', now: t0.add(const Duration(seconds: 3)));

      final runner = buildRunner(globalRateLimiter: limiter, sse: sse);
      final session = await sessions.getOrCreateMain();
      worker.responseText = 'done';

      // Next check() will be 5th event = 100% usage which crosses 80% threshold.
      // But the deferral loop calls check('global') which records the event.
      // After recording, usage goes to 100% and we're at limit = loop defers.
      // We need to pre-fill only 4 to let the 5th pass.
      // Actually: with 4 pre-filled, usage = 4/5 = 80% -> warning emitted.
      // The 5th call to check() passes (records to 5/5) -> turn proceeds.
      final turnId = await runner.reserveTurn(session.id).timeout(const Duration(seconds: 5));
      runner.executeTurn(session.id, turnId, [
        {'role': 'user', 'content': 'test'},
      ]);
      await runner.waitForOutcome(session.id, turnId);

      expect(sse.events, contains('rate_limit_warning'));
    });

    test('turns at limit — deferred until window slides', () async {
      // Use a very short window so the test completes quickly.
      final limiter = SlidingWindowRateLimiter(limit: 1, window: const Duration(milliseconds: 150));
      // Fill the single allowed slot — limiter is now at capacity.
      limiter.check('global');
      expect(limiter.check('global'), isFalse); // verify at limit

      final runner = buildRunner(globalRateLimiter: limiter);
      final session = await sessions.getOrCreateMain();
      worker.responseText = 'done';

      // reserveTurn must defer until the 150ms window expires and then proceed.
      final turnId = await runner
          .reserveTurn(session.id)
          .timeout(const Duration(seconds: 5)); // generous safety timeout
      expect(turnId, isNotEmpty);

      runner.executeTurn(session.id, turnId, [
        {'role': 'user', 'content': 'test'},
      ]);
      await runner.waitForOutcome(session.id, turnId);
    });
  });
}

/// Fake harness that returns immediately.
class _FastFakeWorker extends AgentHarness {
  String responseText = '';
  final StreamController<BridgeEvent> _eventsCtrl = StreamController.broadcast();

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
    String? effort,
    int? maxTurns,
  }) async {
    if (responseText.isNotEmpty) {
      _eventsCtrl.add(DeltaEvent(responseText));
    }
    return <String, dynamic>{'input_tokens': 0, 'output_tokens': 0};
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    if (!_eventsCtrl.isClosed) await _eventsCtrl.close();
  }
}

class _RecordingSseBroadcast extends SseBroadcast {
  final List<String> events = [];

  @override
  void broadcast(String event, Map<String, dynamic> data) {
    events.add(event);
  }
}
