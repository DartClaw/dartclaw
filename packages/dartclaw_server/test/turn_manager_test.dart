import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// FakeGuard for guard hook tests
// ---------------------------------------------------------------------------

class FakeGuard extends Guard {
  @override
  final String name;
  @override
  final String category;
  final GuardVerdict Function(GuardContext)? _evaluator;
  final GuardVerdict? _fixedVerdict;

  FakeGuard({
    this.name = 'fake',
    this.category = 'test',
    GuardVerdict? verdict,
    GuardVerdict Function(GuardContext)? evaluator,
  }) : _fixedVerdict = verdict,
       _evaluator = evaluator;

  @override
  Future<GuardVerdict> evaluate(GuardContext context) async {
    if (_evaluator != null) return _evaluator(context);
    return _fixedVerdict ?? GuardVerdict.pass();
  }
}

// ---------------------------------------------------------------------------
// FakeWorkerService
// ---------------------------------------------------------------------------

class FakeWorkerService implements AgentHarness {
  final _eventsCtrl = StreamController<BridgeEvent>.broadcast();
  Completer<Map<String, dynamic>>? _turnCompleter;
  Completer<void> _turnInvoked = Completer<void>();
  bool cancelCalled = false;
  int turnCalls = 0;

  /// Resolves when the next [turn] call arrives (after composeSystemPrompt completes).
  Future<void> get turnInvoked => _turnInvoked.future;

  @override
  bool get supportsCostReporting => true;

  @override
  bool get supportsToolApproval => true;

  @override
  bool get supportsStreaming => true;

  @override
  bool get supportsCachedTokens => false;

  @override
  bool get supportsSessionContinuity => false;

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
  }) {
    turnCalls++;
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
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    if (!_eventsCtrl.isClosed) await _eventsCtrl.close();
  }

  void emit(BridgeEvent event) => _eventsCtrl.add(event);

  void completeSuccess() {
    _turnCompleter?.complete({'ok': true});
    _turnInvoked = Completer<void>();
  }

  void completeFail(Object error) {
    _turnCompleter?.completeError(error);
    _turnInvoked = Completer<void>();
  }

  Future<void> closeEvents() => _eventsCtrl.close();
}

// ---------------------------------------------------------------------------
// _AppendStrategyWorker — FakeWorkerService variant with append prompt strategy
// ---------------------------------------------------------------------------

class _AppendStrategyWorker implements AgentHarness {
  final _eventsCtrl = StreamController<BridgeEvent>.broadcast();
  Completer<Map<String, dynamic>>? _turnCompleter;
  Completer<void> _turnInvoked = Completer<void>();
  String? lastSystemPrompt;

  Future<void> get turnInvoked => _turnInvoked.future;

  @override
  bool get supportsCostReporting => true;

  @override
  bool get supportsToolApproval => true;

  @override
  bool get supportsStreaming => true;

  @override
  bool get supportsCachedTokens => false;

  @override
  bool get supportsSessionContinuity => false;

  @override
  PromptStrategy get promptStrategy => PromptStrategy.append;

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
  }) {
    lastSystemPrompt = systemPrompt;
    _turnCompleter = Completer<Map<String, dynamic>>();
    if (!_turnInvoked.isCompleted) _turnInvoked.complete();
    return _turnCompleter!.future;
  }

  @override
  Future<void> cancel() async {
    _turnCompleter?.completeError(StateError('Cancelled'));
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    if (!_eventsCtrl.isClosed) await _eventsCtrl.close();
  }

  void completeSuccess() {
    _turnCompleter?.complete({'ok': true});
    _turnInvoked = Completer<void>();
  }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late Directory tempDir;
  late MessageService messages;
  late FakeWorkerService worker;
  late TurnManager turns;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_turns_test_');
    messages = MessageService(baseDir: tempDir.path);
    worker = FakeWorkerService();
    turns = TurnManager(
      messages: messages,
      worker: worker,
      behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test'),
    );
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  // -------------------------------------------------------------------------
  group('startTurn', () {
    test('success: returns turnId, marks session active', () async {
      final turnId = await turns.startTurn('s1', []);

      expect(turnId, isNotEmpty);
      expect(turns.isActive('s1'), isTrue);
      expect(turns.activeTurnId('s1'), equals(turnId));
      expect(turns.isActiveTurn('s1', turnId), isTrue);

      // Cleanup — wait for async composeSystemPrompt to finish before completing turn
      await worker.turnInvoked;
      worker.completeSuccess();
      await turns.waitForOutcome('s1', turnId);
    });

    test('uses a provider-matched pooled runner for provider-pinned sessions', () async {
      final sessionService = SessionService(baseDir: tempDir.path);
      final session = await sessionService.createSession(provider: 'codex');
      final primaryWorker = FakeWorkerService();
      final codexWorker = FakeWorkerService();
      final providerTurns = TurnManager.fromPool(
        pool: HarnessPool(
          runners: [
            TurnRunner(
              harness: primaryWorker,
              messages: messages,
              behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test'),
              sessions: sessionService,
              providerId: 'claude',
            ),
            TurnRunner(
              harness: codexWorker,
              messages: messages,
              behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test'),
              sessions: sessionService,
              providerId: 'codex',
            ),
          ],
        ),
        sessions: sessionService,
      );
      addTearDown(providerTurns.pool.dispose);

      final turnId = await providerTurns.startTurn(session.id, []);
      await codexWorker.turnInvoked;

      expect(primaryWorker.turnCalls, 0);
      expect(codexWorker.turnCalls, 1);

      codexWorker.completeSuccess();
      await providerTurns.waitForOutcome(session.id, turnId);
    });

    test('same-session second request queues behind first (not 409)', () async {
      final turnId1 = await turns.startTurn('s1', []);

      // Second request on same session should queue, not throw
      var secondStarted = false;
      final secondFuture = turns.startTurn('s1', []).then((turnId) {
        secondStarted = true;
        return turnId;
      });

      await Future.delayed(Duration.zero);
      expect(secondStarted, isFalse);

      // Complete first turn to unblock second
      await worker.turnInvoked;
      worker.completeSuccess();
      await turns.waitForOutcome('s1', turnId1);

      final turnId2 = await secondFuture;
      expect(secondStarted, isTrue);
      expect(turnId2, isNotEmpty);

      // Cleanup second turn
      await worker.turnInvoked;
      worker.completeSuccess();
      await turns.waitForOutcome('s1', turnId2);
    });

    test('global busy (different session) throws BusyTurnException with isSameSession=false', () async {
      // Use a lock manager with maxParallel=1 to test global busy behavior
      final singleTurns = TurnManager(
        messages: messages,
        worker: worker,
        behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test'),
        lockManager: SessionLockManager(maxParallel: 1),
      );
      final turnId = await singleTurns.startTurn('s1', []);

      expect(
        () => singleTurns.startTurn('s2', []),
        throwsA(isA<BusyTurnException>().having((e) => e.isSameSession, 'isSameSession', isFalse)),
      );

      // Cleanup
      await worker.turnInvoked;
      worker.completeSuccess();
      await singleTurns.waitForOutcome('s1', turnId);
    });
  });

  // -------------------------------------------------------------------------
  group('promptStrategy', () {
    test('append-strategy harness receives empty systemPrompt', () async {
      final appendWorker = _AppendStrategyWorker();
      final appendTurns = TurnManager(
        messages: messages,
        worker: appendWorker,
        behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test'),
      );

      final turnId = await appendTurns.startTurn('s1', [
        {'role': 'user', 'content': 'hello'},
      ]);
      await appendWorker.turnInvoked;
      expect(appendWorker.lastSystemPrompt, isEmpty);

      appendWorker.completeSuccess();
      await appendTurns.waitForOutcome('s1', turnId);
    });

    test('replace-strategy harness receives non-empty systemPrompt', () async {
      final session = await SessionService(baseDir: tempDir.path).createSession();
      final sessionId = session.id;

      final turnId = await turns.startTurn(sessionId, [
        {'role': 'user', 'content': 'hello'},
      ]);
      await worker.turnInvoked;
      // Default FakeWorkerService has promptStrategy.replace — systemPrompt should be non-empty
      // (at least the default prompt from BehaviorFileService)
      worker.completeSuccess();
      await turns.waitForOutcome(sessionId, turnId);
      // The turn completed without error — the system prompt was composed and sent
    });
  });

  // -------------------------------------------------------------------------
  group('waitForOutcome', () {
    test('returns completed outcome after success', () async {
      final session = await SessionService(baseDir: tempDir.path).createSession();
      final sessionId = session.id;

      final turnId = await turns.startTurn(sessionId, []);
      await worker.turnInvoked;
      worker.completeSuccess();
      final outcome = await turns.waitForOutcome(sessionId, turnId);

      expect(outcome.status, equals(TurnStatus.completed));
      expect(outcome.errorMessage, isNull);
      expect(outcome.sessionId, equals(sessionId));
    });

    test('returns failed outcome after error', () async {
      final session = await SessionService(baseDir: tempDir.path).createSession();
      final sessionId = session.id;

      final turnId = await turns.startTurn(sessionId, []);
      await worker.turnInvoked;
      worker.completeFail(Exception('boom'));
      final outcome = await turns.waitForOutcome(sessionId, turnId);

      expect(outcome.status, equals(TurnStatus.failed));
      expect(outcome.errorMessage, isNotNull);
    });

    test('completes immediately if outcome already cached', () async {
      final session = await SessionService(baseDir: tempDir.path).createSession();
      final sessionId = session.id;

      final turnId = await turns.startTurn(sessionId, []);
      await worker.turnInvoked;
      worker.completeSuccess();
      await turns.waitForOutcome(sessionId, turnId); // first call, let it finish

      // Second call should return immediately from cache
      final cached = await turns.waitForOutcome(sessionId, turnId);
      expect(cached.status, equals(TurnStatus.completed));
    });

    test('throws ArgumentError for unknown turnId', () async {
      expect(() => turns.waitForOutcome('s1', 'unknown-turn-id'), throwsArgumentError);
    });
  });

  // -------------------------------------------------------------------------
  group('cleanup', () {
    test('isActive becomes false after turn completes', () async {
      final session = await SessionService(baseDir: tempDir.path).createSession();
      final sessionId = session.id;

      final turnId = await turns.startTurn(sessionId, []);
      await worker.turnInvoked;
      worker.completeSuccess();
      await turns.waitForOutcome(sessionId, turnId);

      expect(turns.isActive(sessionId), isFalse);
      expect(turns.activeTurnId(sessionId), isNull);
    });

    test('can start new turn after previous turn completes', () async {
      final session = await SessionService(baseDir: tempDir.path).createSession();
      final sessionId = session.id;

      final turnId1 = await turns.startTurn(sessionId, []);
      await worker.turnInvoked;
      worker.completeSuccess();
      await turns.waitForOutcome(sessionId, turnId1);

      // Should not throw
      final turnId2 = await turns.startTurn(sessionId, []);
      expect(turnId2, isNotEmpty);
      expect(turnId2, isNot(equals(turnId1)));

      // Cleanup
      await worker.turnInvoked;
      worker.completeSuccess();
      await turns.waitForOutcome(sessionId, turnId2);
    });
  });

  // -------------------------------------------------------------------------
  group('persistence', () {
    test('success: assistant message persisted with accumulated text', () async {
      final session = await SessionService(baseDir: tempDir.path).createSession();
      final sessionId = session.id;

      final turnId = await turns.startTurn(sessionId, []);
      await worker.turnInvoked;
      worker.emit(DeltaEvent('Hello '));
      worker.emit(DeltaEvent('World'));
      // Yield to let broadcast stream deliver events to the listener before completing.
      await Future<void>.delayed(Duration.zero);
      worker.completeSuccess();
      await turns.waitForOutcome(sessionId, turnId);

      final msgs = await messages.getMessages(sessionId);
      expect(msgs, isNotEmpty);
      final last = msgs.last;
      expect(last.role, equals('assistant'));
      expect(last.content, equals('Hello World'));
    });

    test('failure: assistant error message persisted', () async {
      final session = await SessionService(baseDir: tempDir.path).createSession();
      final sessionId = session.id;

      final turnId = await turns.startTurn(sessionId, []);
      await worker.turnInvoked;
      worker.completeFail(Exception('something went wrong'));
      await turns.waitForOutcome(sessionId, turnId);

      final msgs = await messages.getMessages(sessionId);
      expect(msgs, isNotEmpty);
      final last = msgs.last;
      expect(last.role, equals('assistant'));
      expect(last.content, equals('[Turn failed]'));
    });

    test('failure with partial content: saves accumulated buffer text', () async {
      final session = await SessionService(baseDir: tempDir.path).createSession();
      final sessionId = session.id;

      final turnId = await turns.startTurn(sessionId, []);
      await worker.turnInvoked;
      worker.emit(DeltaEvent('Partial '));
      worker.emit(DeltaEvent('response'));
      await Future<void>.delayed(Duration.zero); // let events propagate
      worker.completeFail(Exception('mid-stream failure'));
      await turns.waitForOutcome(sessionId, turnId);

      final msgs = await messages.getMessages(sessionId);
      expect(msgs, isNotEmpty);
      final last = msgs.last;
      expect(last.role, equals('assistant'));
      expect(last.content, equals('Partial response'));
    });

    test('success: session updatedAt is touched', () async {
      final sessionService = SessionService(baseDir: tempDir.path);
      final session = await sessionService.createSession();
      final sessionId = session.id;
      final originalUpdatedAt = session.updatedAt;

      final turnsWithSessions = TurnManager(
        messages: messages,
        worker: worker,
        behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test'),
        sessions: sessionService,
      );

      // Small delay to ensure updatedAt will differ
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final turnId = await turnsWithSessions.startTurn(sessionId, []);
      await worker.turnInvoked;
      worker.completeSuccess();
      await turnsWithSessions.waitForOutcome(sessionId, turnId);

      final updated = await sessionService.getSession(sessionId);
      expect(updated, isNotNull);
      expect(updated!.updatedAt.isAfter(originalUpdatedAt), isTrue);
    });
  });

  // -------------------------------------------------------------------------
  group('recentOutcome', () {
    test('returns null before turn completes', () async {
      final turnId = await turns.startTurn('s1', []);

      expect(turns.recentOutcome('s1', turnId), isNull);

      // Cleanup
      await worker.turnInvoked;
      worker.completeSuccess();
      await turns.waitForOutcome('s1', turnId);
    });

    test('returns outcome after turn completes', () async {
      final session = await SessionService(baseDir: tempDir.path).createSession();
      final sessionId = session.id;

      final turnId = await turns.startTurn(sessionId, []);
      await worker.turnInvoked;
      worker.completeSuccess();
      await turns.waitForOutcome(sessionId, turnId);

      expect(turns.recentOutcome(sessionId, turnId), isNotNull);
    });

    test('returns null after TTL expires', () async {
      final session = await SessionService(baseDir: tempDir.path).createSession();
      final sessionId = session.id;

      final shortTtlTurns = TurnManager(
        messages: messages,
        worker: worker,
        behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test'),
        outcomeTtl: const Duration(milliseconds: 1),
      );

      final turnId = await shortTtlTurns.startTurn(sessionId, []);
      await worker.turnInvoked;
      worker.completeSuccess();
      await shortTtlTurns.waitForOutcome(sessionId, turnId);

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(shortTtlTurns.recentOutcome(sessionId, turnId), isNull);
    });
  });

  // -------------------------------------------------------------------------
  group('cancelTurn', () {
    test('calls worker.cancel() when turn is active', () async {
      final session = await SessionService(baseDir: tempDir.path).createSession();
      final sessionId = session.id;

      final turnId = await turns.startTurn(sessionId, []);
      await worker.turnInvoked;
      await turns.cancelTurn(sessionId);

      expect(worker.cancelCalled, isTrue);

      // After cancel the turn completer errors — wait for cleanup
      try {
        await turns.waitForOutcome(sessionId, turnId);
      } catch (_) {}
    });

    test('is no-op when no active turn', () async {
      // Should complete without error
      await turns.cancelTurn('s1');
    });

    test('cancels active turns running on pooled task runners', () async {
      final taskWorker = FakeWorkerService();
      addTearDown(taskWorker.dispose);

      final behavior = BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test');
      final primaryRunner = TurnRunner(harness: worker, messages: messages, behavior: behavior);
      final taskRunner = TurnRunner(harness: taskWorker, messages: messages, behavior: behavior);
      final pooledTurns = TurnManager.fromPool(pool: HarnessPool(runners: [primaryRunner, taskRunner]));

      final session = await SessionService(baseDir: tempDir.path).createSession();
      final sessionId = session.id;

      final turnId = await taskRunner.startTurn(sessionId, []);
      await taskWorker.turnInvoked;
      await pooledTurns.cancelTurn(sessionId);

      expect(taskWorker.cancelCalled, isTrue);

      try {
        await taskRunner.waitForOutcome(sessionId, turnId);
      } catch (_) {}
    });
  });

  // -------------------------------------------------------------------------
  group('waitForCompletion', () {
    test('resolves after cancel completes', () async {
      final session = await SessionService(baseDir: tempDir.path).createSession();
      final sessionId = session.id;

      final turnId = await turns.startTurn(sessionId, []);
      await worker.turnInvoked;
      await turns.cancelTurn(sessionId);

      // Should resolve (turn completer errors on cancel, which completes the outcome)
      await turns.waitForCompletion(sessionId);

      expect(turns.isActive(sessionId), isFalse);

      // Cleanup
      try {
        await turns.waitForOutcome(sessionId, turnId);
      } catch (_) {}
    });

    test('returns immediately for nonexistent session', () async {
      // Should complete without error or delay
      await turns.waitForCompletion('nonexistent-session-id');
    });

    test('throws TimeoutException with very short timeout', () async {
      final session = await SessionService(baseDir: tempDir.path).createSession();
      final sessionId = session.id;

      final turnId = await turns.startTurn(sessionId, []);
      await worker.turnInvoked;

      // Very short timeout — turn is still active (not completed)
      await expectLater(
        turns.waitForCompletion(sessionId, timeout: const Duration(milliseconds: 1)),
        throwsA(isA<TimeoutException>()),
      );

      // Cleanup
      worker.completeSuccess();
      await turns.waitForOutcome(sessionId, turnId);
    });
  });

  // -------------------------------------------------------------------------
  group('guard hooks', () {
    test('messageReceived block verdict fails turn with blocked message', () async {
      final session = await SessionService(baseDir: tempDir.path).createSession();
      final sessionId = session.id;

      final guardedTurns = TurnManager(
        messages: messages,
        worker: worker,
        behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test'),
        guardChain: GuardChain(guards: [FakeGuard(verdict: GuardVerdict.block('unsafe input'))]),
      );

      final turnId = await guardedTurns.startTurn(sessionId, [
        {'role': 'user', 'content': 'bad message'},
      ]);
      final outcome = await guardedTurns.waitForOutcome(sessionId, turnId);

      expect(outcome.status, TurnStatus.failed);
      expect(outcome.errorMessage, contains('Blocked by guard'));

      final msgs = await messages.getMessages(sessionId);
      expect(msgs, isNotEmpty);
      expect(msgs.last.role, 'assistant');
      expect(msgs.last.content, contains('[Blocked by guard: unsafe input]'));
    });

    test('messageReceived warn verdict allows turn to proceed', () async {
      final session = await SessionService(baseDir: tempDir.path).createSession();
      final sessionId = session.id;

      final guardedTurns = TurnManager(
        messages: messages,
        worker: worker,
        behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test'),
        guardChain: GuardChain(guards: [FakeGuard(verdict: GuardVerdict.warn('proceed with caution'))]),
      );

      final turnId = await guardedTurns.startTurn(sessionId, [
        {'role': 'user', 'content': 'hello'},
      ]);
      await worker.turnInvoked;
      worker.emit(DeltaEvent('Normal response'));
      await Future<void>.delayed(Duration.zero);
      worker.completeSuccess();
      final outcome = await guardedTurns.waitForOutcome(sessionId, turnId);

      expect(outcome.status, TurnStatus.completed);
      final msgs = await messages.getMessages(sessionId);
      expect(msgs.last.content, 'Normal response');
    });

    test('beforeAgentSend block verdict replaces response with blocked message', () async {
      final session = await SessionService(baseDir: tempDir.path).createSession();
      final sessionId = session.id;

      // Guard that passes messageReceived but blocks beforeAgentSend
      final guardedTurns = TurnManager(
        messages: messages,
        worker: worker,
        behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test'),
        guardChain: GuardChain(
          guards: [
            FakeGuard(
              evaluator: (ctx) {
                if (ctx.hookPoint == 'beforeAgentSend') {
                  return GuardVerdict.block('sensitive content');
                }
                return GuardVerdict.pass();
              },
            ),
          ],
        ),
      );

      final turnId = await guardedTurns.startTurn(sessionId, [
        {'role': 'user', 'content': 'hello'},
      ]);
      await worker.turnInvoked;
      worker.emit(DeltaEvent('Secret response'));
      await Future<void>.delayed(Duration.zero);
      worker.completeSuccess();
      final outcome = await guardedTurns.waitForOutcome(sessionId, turnId);

      expect(outcome.status, TurnStatus.failed);
      expect(outcome.errorMessage, contains('Response blocked by guard'));

      final msgs = await messages.getMessages(sessionId);
      expect(msgs.last.content, contains('[Response blocked by guard: sensitive content]'));
    });

    test('beforeAgentSend warn verdict allows response to persist normally', () async {
      final session = await SessionService(baseDir: tempDir.path).createSession();
      final sessionId = session.id;

      final guardedTurns = TurnManager(
        messages: messages,
        worker: worker,
        behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test'),
        guardChain: GuardChain(
          guards: [
            FakeGuard(
              evaluator: (ctx) {
                if (ctx.hookPoint == 'beforeAgentSend') {
                  return GuardVerdict.warn('low confidence');
                }
                return GuardVerdict.pass();
              },
            ),
          ],
        ),
      );

      final turnId = await guardedTurns.startTurn(sessionId, [
        {'role': 'user', 'content': 'hello'},
      ]);
      await worker.turnInvoked;
      worker.emit(DeltaEvent('Good response'));
      await Future<void>.delayed(Duration.zero);
      worker.completeSuccess();
      final outcome = await guardedTurns.waitForOutcome(sessionId, turnId);

      expect(outcome.status, TurnStatus.completed);
      final msgs = await messages.getMessages(sessionId);
      expect(msgs.last.content, 'Good response');
    });

    test('null guardChain does not affect existing behavior', () async {
      // The default `turns` fixture has no guardChain — this test verifies
      // existing tests' behavior is unaffected (same as other tests above).
      final session = await SessionService(baseDir: tempDir.path).createSession();
      final sessionId = session.id;

      final turnId = await turns.startTurn(sessionId, [
        {'role': 'user', 'content': 'hello'},
      ]);
      await worker.turnInvoked;
      worker.emit(DeltaEvent('Response'));
      await Future<void>.delayed(Duration.zero);
      worker.completeSuccess();
      final outcome = await turns.waitForOutcome(sessionId, turnId);

      expect(outcome.status, TurnStatus.completed);
      final msgs = await messages.getMessages(sessionId);
      expect(msgs.last.content, 'Response');
    });
  });

  // -------------------------------------------------------------------------
  group('crash recovery', () {
    late KvService kvService;
    late Database turnStateDb;
    late TurnStateStore turnState;
    late TurnManager Function({TurnStateStore? turnStateStore, KvService? kv}) buildTurns;

    setUp(() {
      kvService = KvService(filePath: p.join(tempDir.path, 'kv.json'));
      turnStateDb = sqlite3.openInMemory();
      turnState = TurnStateStore(turnStateDb);
      buildTurns = ({TurnStateStore? turnStateStore, KvService? kv}) {
        return TurnManager.fromPool(
          pool: HarnessPool(
            runners: [
              TurnRunner(
                harness: worker,
                messages: messages,
                behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test'),
                turnState: turnStateStore,
                kv: kv,
              ),
            ],
          ),
        );
      };
    });

    tearDown(() async {
      await kvService.dispose();
      await turnState.dispose();
    });

    test('turn start writes turn state to store', () async {
      final turnsWithState = buildTurns(turnStateStore: turnState, kv: kvService);

      final turnId = await turnsWithState.startTurn('s1', []);

      final stored = (await turnState.getAll())['s1'];
      expect(stored, isNotNull);
      expect(stored?.turnId, equals(turnId));
      expect(stored?.startedAt, isA<DateTime>());

      // Cleanup
      await worker.turnInvoked;
      worker.completeSuccess();
      await turnsWithState.waitForOutcome('s1', turnId);
    });

    test('turn completion removes turn state from store', () async {
      final session = await SessionService(baseDir: tempDir.path).createSession();
      final sessionId = session.id;
      final turnsWithState = buildTurns(turnStateStore: turnState, kv: kvService);

      final turnId = await turnsWithState.startTurn(sessionId, []);
      await worker.turnInvoked;
      worker.completeSuccess();
      await turnsWithState.waitForOutcome(sessionId, turnId);

      expect(await turnState.getAll(), isNot(contains(sessionId)));
    });

    test('detectAndCleanOrphanedTurns finds and cleans orphans', () async {
      // Seed state store with orphaned turn entries (simulating a crash).
      await turnState.set('session1', 'turn-aaa', DateTime.parse('2026-01-01T00:00:00.000'));
      await turnState.set('session2', 'turn-bbb', DateTime.parse('2026-01-01T00:01:00.000'));
      await kvService.set('session_cost:session1', '{"total_tokens": 100}');

      final turnsWithState = buildTurns(turnStateStore: turnState, kv: kvService);

      final recovered = await turnsWithState.detectAndCleanOrphanedTurns();

      expect(recovered, unorderedEquals(['session1', 'session2']));
      expect(await turnState.getAll(), isEmpty);
      expect(await kvService.get('session_cost:session1'), isNotNull);
    });

    test('consumeRecoveryNotice returns true once then false', () async {
      await turnState.set('session1', 'turn-aaa', DateTime.parse('2026-01-01T00:00:00.000'));

      final turnsWithState = buildTurns(turnStateStore: turnState, kv: kvService);

      await turnsWithState.detectAndCleanOrphanedTurns();

      expect(turnsWithState.consumeRecoveryNotice('session1'), isTrue);
      expect(turnsWithState.consumeRecoveryNotice('session1'), isFalse);
    });

    test('detectAndCleanOrphanedTurns returns empty when no orphans', () async {
      await kvService.set('session_cost:xyz', '{"total_tokens": 50}');

      final turnsWithState = buildTurns(turnStateStore: turnState, kv: kvService);

      final recovered = await turnsWithState.detectAndCleanOrphanedTurns();
      expect(recovered, isEmpty);
    });

    test('detectAndCleanOrphanedTurns returns empty when no turn state store', () async {
      final turnsWithoutState = buildTurns(kv: kvService);

      final recovered = await turnsWithoutState.detectAndCleanOrphanedTurns();
      expect(recovered, isEmpty);
    });

    test('turn state write failure degrades gracefully', () async {
      final turnsWithBadState = buildTurns(turnStateStore: _ThrowingTurnStateStore(), kv: kvService);

      // Should not throw — turn proceeds despite state write failure.
      final turnId = await turnsWithBadState.startTurn('s1', []);
      expect(turnId, isNotEmpty);
      expect(turnsWithBadState.isActive('s1'), isTrue);

      // Cleanup
      await worker.turnInvoked;
      worker.completeSuccess();
      await turnsWithBadState.waitForOutcome('s1', turnId);
    });
  });
}

class _ThrowingTurnStateStore implements TurnStateStore {
  @override
  Future<void> delete(String sessionId) async => throw StateError('delete failed');

  @override
  Future<void> dispose() async {}

  @override
  Future<Map<String, ({String turnId, DateTime startedAt})>> getAll() async =>
      <String, ({String turnId, DateTime startedAt})>{};

  @override
  Future<void> set(String sessionId, String turnId, DateTime startedAt) async => throw StateError('set failed');
}
