import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:dartclaw_server/dartclaw_server.dart' hide TurnManager;
import 'package:dartclaw_server/src/turn_manager.dart' show TurnManager;
import 'package:dartclaw_server/src/turn_wait_status.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness;

/// Shared [TurnManager] subclass for session route tests.
///
/// These fakes extend the real server-owned [TurnManager] (so the consuming
/// files import the barrel with `hide TurnManager` and pull the real type from
/// `src/turn_manager.dart`). This is a distinct family from the callback-style
/// `FakeTurnManager` in the `dartclaw_testing` barrel.
///
/// Models the turn lifecycle in memory: [reserveTurn] honours [setBusy]
/// (throwing [BusyTurnException]) and tracks active turns; [executeTurn]
/// captures the last messages; [resetSessionContinuity] records session ids.
/// [reserveCalled] lets command-intercept tests assert a turn was never
/// reserved.
class FakeTurnManager extends TurnManager {
  FakeTurnManager(MessageService messages, AgentHarness worker)
    : super(
        messages: messages,
        worker: worker,
        behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-dartclaw-test'),
      );

  bool _busy = false;
  final Map<String, String> _activeTurns = {};
  final Map<String, TurnOutcome> _outcomes = {};
  bool canCancelActiveTurn = true;
  PromptScope? lastPromptScope;
  List<Map<String, dynamic>>? lastExecuteMessages;
  final List<String> resetContinuitySessionIds = [];
  bool reserveCalled = false;

  void setBusy() {
    _busy = true;
  }

  void clearBusy() => _busy = false;

  @override
  Future<String> reserveTurn(
    String sessionId, {
    String agentName = 'main',
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
    String? taskId,
    bool isHumanInput = false,
    BehaviorFileService? behaviorOverride,
    PromptScope? promptScope,
    List<String>? allowedTools,
    bool readOnly = false,
  }) async {
    reserveCalled = true;
    if (_busy) {
      throw BusyTurnException('global busy', isSameSession: false);
    }
    lastPromptScope = promptScope;
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
    bool resume = false,
  }) {
    lastExecuteMessages = messages;
  }

  @override
  void releaseTurn(String sessionId, String turnId) {
    _activeTurns.remove(sessionId);
  }

  @override
  Future<void> resetSessionContinuity(String sessionId) async {
    resetContinuitySessionIds.add(sessionId);
    await super.resetSessionContinuity(sessionId);
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

  @override
  TurnStatusSnapshot turnStatus(String sessionId) {
    final turnId = _activeTurns[sessionId];
    if (turnId == null) {
      TurnOutcome? latest;
      for (final outcome in _outcomes.values) {
        if (outcome.sessionId != sessionId) continue;
        if (latest == null || outcome.completedAt.isAfter(latest.completedAt)) {
          latest = outcome;
        }
      }
      return latest == null
          ? TurnStatusSnapshot.idle(sessionId)
          : TurnStatusSnapshot.fromOutcome(sessionId: sessionId, outcome: latest, provider: 'codex');
    }
    return TurnStatusSnapshot(
      sessionId: sessionId,
      turnId: turnId,
      provider: 'codex',
      state: TurnWaitState.waiting,
      waitReason: TurnWaitReason.sessionLock,
      waitingSince: DateTime.parse('2026-03-10T10:00:00Z'),
      globalTimeoutAt: DateTime.parse('2026-03-10T10:02:00Z'),
      canCancel: canCancelActiveTurn,
    );
  }

  @override
  Future<TurnCancelResult> cancelTurnById(String sessionId, String turnId, TurnCancelReason reason) async {
    final activeTurnId = _activeTurns[sessionId];
    if (activeTurnId == null || activeTurnId != turnId) {
      final recent = _outcomes[turnId];
      if (recent != null && recent.status == TurnStatus.completed) {
        return const TurnCancelResult(status: TurnWaitState.completed, releasedSessionLock: false);
      }
      if (recent != null) {
        throw const TurnCancelException('TURN_NOT_CANCELLABLE', 'Turn is not cancellable', statusCode: 409);
      }
      throw const TurnCancelException('TURN_NOT_FOUND', 'Turn not found', statusCode: 404);
    }
    _activeTurns.remove(sessionId);
    final outcome = TurnOutcome(
      turnId: turnId,
      sessionId: sessionId,
      status: TurnStatus.cancelled,
      completedAt: DateTime.parse('2026-03-10T10:01:00Z'),
    );
    _outcomes[turnId] = outcome;
    return const TurnCancelResult(status: TurnWaitState.cancelled, releasedSessionLock: true);
  }

  void setRecentOutcome(String turnId, TurnOutcome outcome) {
    _outcomes[turnId] = outcome;
  }
}

/// Tracks the archive call ordering exercised by `session_routes_test`.
class ArchiveCallTracker {
  bool cancelTurnCalled = false;
  bool updateSessionTypeCalled = false;
  bool cancelBeforeUpdate = false;
}

class RecordingTurnManager extends FakeTurnManager {
  RecordingTurnManager(super.messages, super.worker, this.tracker);

  final ArchiveCallTracker tracker;

  @override
  Future<void> cancelTurn(String sessionId) async {
    tracker.cancelTurnCalled = true;
    await super.cancelTurn(sessionId);
  }
}

class FailingStopHarness extends FakeAgentHarness {
  int remainingStopFailures = 1;

  @override
  Future<void> stop() async {
    stopCalled = true;
    if (remainingStopFailures > 0) {
      remainingStopFailures -= 1;
      throw StateError('stop failed');
    }
  }
}

/// [SessionService] wrapper that records whether a turn was cancelled before the
/// session type was updated (archive-ordering assertion).
class RecordingSessionService extends SessionService {
  RecordingSessionService({required super.baseDir, required this.tracker});

  final ArchiveCallTracker tracker;

  @override
  Future<Session?> updateSessionType(String id, SessionType type) async {
    tracker.updateSessionTypeCalled = true;
    tracker.cancelBeforeUpdate = tracker.cancelTurnCalled;
    return super.updateSessionType(id, type);
  }
}
