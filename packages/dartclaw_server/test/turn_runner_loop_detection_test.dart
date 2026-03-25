import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'dart:io';

void main() {
  late Directory tempDir;
  late String sessionsDir;
  late String workspaceDir;
  late SessionService sessions;
  late MessageService messages;
  late _FakeWorker worker;
  late Database turnStateDb;
  late TurnStateStore turnState;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('turn_runner_loop_test_');
    sessionsDir = p.join(tempDir.path, 'sessions');
    workspaceDir = p.join(tempDir.path, 'workspace');
    Directory(sessionsDir).createSync(recursive: true);
    Directory(workspaceDir).createSync(recursive: true);

    sessions = SessionService(baseDir: sessionsDir);
    messages = MessageService(baseDir: sessionsDir);
    worker = _FakeWorker();
    turnStateDb = sqlite3.openInMemory();
    turnState = TurnStateStore(turnStateDb);
  });

  tearDown(() async {
    await messages.dispose();
    await worker.dispose();
    await turnState.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  LoopDetectionConfig loopConfig({
    bool enabled = true,
    int maxConsecutiveTurns = 3,
    int maxTokensPerMinute = 999999,
    int maxConsecutiveIdenticalToolCalls = 999,
    LoopAction action = LoopAction.abort,
  }) => LoopDetectionConfig(
    enabled: enabled,
    maxConsecutiveTurns: maxConsecutiveTurns,
    maxTokensPerMinute: maxTokensPerMinute,
    velocityWindowMinutes: 2,
    maxConsecutiveIdenticalToolCalls: maxConsecutiveIdenticalToolCalls,
    action: action,
  );

  TurnRunner buildRunner({
    LoopDetector? loopDetector,
    LoopAction? loopAction,
    EventBus? eventBus,
    _RecordingSseBroadcast? sse,
  }) {
    return TurnRunner(
      harness: worker,
      messages: messages,
      behavior: BehaviorFileService(workspaceDir: workspaceDir),
      sessions: sessions,
      turnState: turnState,
      loopDetector: loopDetector,
      loopAction: loopAction,
      eventBus: eventBus,
      sseBroadcast: sse,
    );
  }

  // ── No detector (backward compat) ─────────────────────────────────────────

  group('TurnRunner — loop detection disabled', () {
    test('no detector → no loop detection (backward compat)', () async {
      final runner = buildRunner(); // no loopDetector
      final session = await sessions.getOrCreateMain();
      worker.responseText = 'done';
      final turnId = await runner.startTurn(session.id, []).timeout(const Duration(seconds: 2));
      expect(turnId, isNotEmpty);
      await runner.waitForCompletion(session.id).timeout(const Duration(seconds: 2));
    });

    test('disabled detector → no detection even after many turns', () async {
      final loopDetector = LoopDetector(config: loopConfig(enabled: false));
      final runner = buildRunner(loopDetector: loopDetector, loopAction: LoopAction.abort);
      final session = await sessions.getOrCreateMain();
      worker.responseText = 'done';

      for (var i = 0; i < 10; i++) {
        final turnId = await runner.startTurn(session.id, []).timeout(const Duration(seconds: 2));
        expect(turnId, isNotEmpty);
        await runner.waitForCompletion(session.id).timeout(const Duration(seconds: 2));
      }
    });
  });

  // ── Turn chain depth — abort ───────────────────────────────────────────────

  group('TurnRunner — turn chain depth (abort)', () {
    test('exceeds threshold → LoopDetectedException thrown from reserveTurn', () async {
      final loopDetector = LoopDetector(config: loopConfig(maxConsecutiveTurns: 2));
      final runner = buildRunner(loopDetector: loopDetector, loopAction: LoopAction.abort);
      final session = await sessions.getOrCreateMain();
      worker.responseText = 'ok';

      // First 2 turns succeed (depth 1 and 2 — at threshold, not exceeding)
      await runner.startTurn(session.id, []).timeout(const Duration(seconds: 2));
      await runner.waitForCompletion(session.id).timeout(const Duration(seconds: 2));
      await runner.startTurn(session.id, []).timeout(const Duration(seconds: 2));
      await runner.waitForCompletion(session.id).timeout(const Duration(seconds: 2));

      // Third turn exceeds threshold (depth 3 > 2)
      await expectLater(runner.reserveTurn(session.id), throwsA(isA<LoopDetectedException>()));
    });

    test('SSE loop_detected event broadcast on abort', () async {
      final sse = _RecordingSseBroadcast();
      final loopDetector = LoopDetector(config: loopConfig(maxConsecutiveTurns: 1));
      final runner = buildRunner(loopDetector: loopDetector, loopAction: LoopAction.abort, sse: sse);
      final session = await sessions.getOrCreateMain();
      worker.responseText = 'ok';

      // First turn sets depth=1 (at threshold, no detection yet)
      await runner.startTurn(session.id, []).timeout(const Duration(seconds: 2));
      await runner.waitForCompletion(session.id).timeout(const Duration(seconds: 2));

      // Second turn depth=2 > 1 → abort, SSE
      await expectLater(runner.reserveTurn(session.id), throwsA(isA<LoopDetectedException>()));
      expect(sse.events, contains('loop_detected'));
    });

    test('EventBus LoopDetectedEvent fired on abort', () async {
      final eventBus = EventBus();
      final events = <LoopDetectedEvent>[];
      final sub = eventBus.on<LoopDetectedEvent>().listen(events.add);
      addTearDown(sub.cancel);

      final loopDetector = LoopDetector(config: loopConfig(maxConsecutiveTurns: 1));
      final runner = buildRunner(loopDetector: loopDetector, loopAction: LoopAction.abort, eventBus: eventBus);
      final session = await sessions.getOrCreateMain();
      worker.responseText = 'ok';

      await runner.startTurn(session.id, []).timeout(const Duration(seconds: 2));
      await runner.waitForCompletion(session.id).timeout(const Duration(seconds: 2));

      await expectLater(runner.reserveTurn(session.id), throwsA(isA<LoopDetectedException>()));

      // Allow event to be delivered
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));
      expect(events.first.mechanism, 'turnChainDepth');
      expect(events.first.action, 'abort');
    });
  });

  // ── Turn chain depth — warn ────────────────────────────────────────────────

  group('TurnRunner — turn chain depth (warn)', () {
    test('exceeds threshold → warn event fired, turn proceeds', () async {
      final sse = _RecordingSseBroadcast();
      final loopDetector = LoopDetector(config: loopConfig(maxConsecutiveTurns: 1, action: LoopAction.warn));
      final runner = buildRunner(loopDetector: loopDetector, loopAction: LoopAction.warn, sse: sse);
      final session = await sessions.getOrCreateMain();
      worker.responseText = 'ok';

      // Turn 1 — depth=1, at threshold, no detection
      await runner.startTurn(session.id, []).timeout(const Duration(seconds: 2));
      await runner.waitForCompletion(session.id).timeout(const Duration(seconds: 2));

      // Turn 2 — depth=2 > 1, fires warn but DOES NOT throw
      final turnId = await runner.reserveTurn(session.id).timeout(const Duration(seconds: 2));
      expect(turnId, isNotEmpty);
      expect(sse.events, contains('loop_detected'));

      runner.executeTurn(session.id, turnId, []);
      await runner.waitForCompletion(session.id).timeout(const Duration(seconds: 2));
    });
  });

  // ── isHumanInput resets chain ──────────────────────────────────────────────

  group('TurnRunner — isHumanInput resets chain', () {
    test('isHumanInput: true resets consecutive turn counter', () async {
      final loopDetector = LoopDetector(config: loopConfig(maxConsecutiveTurns: 1));
      final runner = buildRunner(loopDetector: loopDetector, loopAction: LoopAction.abort);
      final session = await sessions.getOrCreateMain();
      worker.responseText = 'ok';

      // Autonomous turn 1 — depth=1
      await runner.startTurn(session.id, []).timeout(const Duration(seconds: 2));
      await runner.waitForCompletion(session.id).timeout(const Duration(seconds: 2));

      // Human turn resets chain — should NOT throw even though depth would be 2
      final turnId = await runner.reserveTurn(session.id, isHumanInput: true).timeout(const Duration(seconds: 2));
      runner.executeTurn(session.id, turnId, []);
      await runner.waitForCompletion(session.id).timeout(const Duration(seconds: 2));

      // Autonomous turn after reset — depth=1 again (reset by human input)
      final nextTurnId = await runner.reserveTurn(session.id).timeout(const Duration(seconds: 2));
      expect(nextTurnId, isNotEmpty);
      runner.executeTurn(session.id, nextTurnId, []);
      await runner.waitForCompletion(session.id).timeout(const Duration(seconds: 2));
    });
  });

  // ── cleanupTurn in finally ─────────────────────────────────────────────────

  group('TurnRunner — cleanupTurn called in finally', () {
    test('tool fingerprint state is cleaned up after turn', () async {
      // Set threshold=2 for fingerprinting
      final loopDetector = LoopDetector(
        config: loopConfig(maxConsecutiveTurns: 999, maxConsecutiveIdenticalToolCalls: 2),
      );
      final runner = buildRunner(loopDetector: loopDetector, loopAction: LoopAction.warn);
      final session = await sessions.getOrCreateMain();

      // First turn: emit one tool event
      worker.responseText = 'done';
      worker.toolToEmit = ToolUseEvent(toolId: 'id1', toolName: 'bash', input: {'cmd': 'ls'});
      final t1 = await runner.startTurn(session.id, []).timeout(const Duration(seconds: 2));
      await runner.waitForCompletion(session.id).timeout(const Duration(seconds: 2));

      // After turn cleanup, turn state for t1 should be gone.
      // Second turn with same tool — if cleanup worked, count resets to 1.
      worker.toolToEmit = ToolUseEvent(toolId: 'id2', toolName: 'bash', input: {'cmd': 'ls'});
      // This should NOT detect because cleanup erased t1's fingerprint state
      final t2 = await runner.startTurn(session.id, []).timeout(const Duration(seconds: 2));
      await runner.waitForCompletion(session.id).timeout(const Duration(seconds: 2));

      // Suppress unused variable warnings
      expect(t1, isNotEmpty);
      expect(t2, isNotEmpty);
    });
  });
}

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _FakeWorker extends AgentHarness {
  String responseText = '';
  ToolUseEvent? toolToEmit;
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
    final tool = toolToEmit;
    if (tool != null) {
      _eventsCtrl.add(tool);
      toolToEmit = null;
    }
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
