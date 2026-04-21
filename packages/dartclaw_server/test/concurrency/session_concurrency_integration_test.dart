import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// FakeWorkerService — controllable agent harness for integration tests
// ---------------------------------------------------------------------------

class FakeWorkerService implements AgentHarness {
  @override
  String skillActivationLine(String skill) => "Use the '$skill' skill.";

  final _eventsCtrl = StreamController<BridgeEvent>.broadcast();
  final _turnCompleters = <String, Completer<Map<String, dynamic>>>{};
  Completer<void> _turnInvoked = Completer<void>();

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
  bool get supportsPreCompactHook => false;

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
    final completer = Completer<Map<String, dynamic>>();
    _turnCompleters[sessionId] = completer;
    if (!_turnInvoked.isCompleted) _turnInvoked.complete();
    return completer.future;
  }

  @override
  Future<void> cancel() async {
    for (final c in _turnCompleters.values) {
      if (!c.isCompleted) c.completeError(StateError('Cancelled'));
    }
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    if (!_eventsCtrl.isClosed) await _eventsCtrl.close();
  }

  void completeSession(String sessionId) {
    _turnCompleters[sessionId]?.complete({'ok': true});
    _turnCompleters.remove(sessionId);
    _turnInvoked = Completer<void>();
  }

  void completeSuccess() {
    // Complete the most recently added turn
    if (_turnCompleters.isNotEmpty) {
      final sessionId = _turnCompleters.keys.last;
      completeSession(sessionId);
    }
  }
}

// ---------------------------------------------------------------------------
// Integration tests
// ---------------------------------------------------------------------------

void main() {
  late Directory tempDir;
  late MessageService messages;
  late FakeWorkerService worker;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_concurrency_test_');
    messages = MessageService(baseDir: tempDir.path);
    worker = FakeWorkerService();
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('session concurrency integration', () {
    test('two different sessions can be active concurrently', () async {
      final turns = TurnManager(
        messages: messages,
        worker: worker,
        behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test'),
      );

      // Start both sessions — lock manager should allow both
      final turnId1 = await turns.startTurn('s1', []);
      await worker.turnInvoked;
      final turnId2 = await turns.startTurn('s2', []);

      // Both sessions active simultaneously
      expect(turns.activeSessionIds, containsAll(['s1', 's2']));
      expect(turns.isActive('s1'), isTrue);
      expect(turns.isActive('s2'), isTrue);

      // Cleanup
      worker.completeSession('s1');
      await turns.waitForOutcome('s1', turnId1);
      await worker.turnInvoked;
      worker.completeSession('s2');
      await turns.waitForOutcome('s2', turnId2);
    });

    test('same-session second request queues behind first', () async {
      final turns = TurnManager(
        messages: messages,
        worker: worker,
        behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test'),
      );

      final turnId1 = await turns.startTurn('s1', []);
      expect(turns.isActive('s1'), isTrue);

      // Second request on same session should queue (not throw)
      var secondStarted = false;
      final secondFuture = turns.startTurn('s1', []).then((turnId) {
        secondStarted = true;
        return turnId;
      });

      // Yield to microtask queue — second should still be waiting
      await Future.delayed(Duration.zero);
      expect(secondStarted, isFalse);

      // Complete first turn
      await worker.turnInvoked;
      worker.completeSuccess();
      await turns.waitForOutcome('s1', turnId1);

      // Second should now proceed
      final turnId2 = await secondFuture;
      expect(secondStarted, isTrue);
      expect(turnId2, isNotEmpty);
      expect(turnId2, isNot(equals(turnId1)));

      // Cleanup second turn
      await worker.turnInvoked;
      worker.completeSuccess();
      await turns.waitForOutcome('s1', turnId2);
    });

    test('global cap exceeded returns BusyTurnException', () async {
      final turns = TurnManager(
        messages: messages,
        worker: worker,
        behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test'),
        lockManager: SessionLockManager(maxParallel: 1),
      );

      final turnId1 = await turns.startTurn('s1', []);

      // Different session should be rejected by global cap
      expect(
        () => turns.startTurn('s2', []),
        throwsA(isA<BusyTurnException>().having((e) => e.isSameSession, 'isSameSession', isFalse)),
      );

      // Cleanup
      await worker.turnInvoked;
      worker.completeSuccess();
      await turns.waitForOutcome('s1', turnId1);
    });
  });
}
