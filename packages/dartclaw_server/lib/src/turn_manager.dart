import 'package:dartclaw_core/dartclaw_core.dart';

import 'behavior/behavior_file_service.dart';
import 'behavior/self_improvement_service.dart';
import 'concurrency/session_lock_manager.dart';
import 'context/context_monitor.dart';
import 'context/result_trimmer.dart';
import 'harness_pool.dart';
import 'observability/usage_tracker.dart';
import 'session/session_reset_service.dart';
import 'turn_runner.dart';

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

/// Outcome status of a completed turn.
enum TurnStatus { completed, failed, cancelled }

/// Metadata for an in-flight agent turn.
class TurnContext {
  final String turnId;
  final String sessionId;
  final String agentName;
  final DateTime startedAt;

  /// Optional working directory override for this turn (e.g. worktree path).
  final String? directory;

  /// Optional per-turn model override for task execution.
  final String? model;

  TurnContext({
    required this.turnId,
    required this.sessionId,
    this.agentName = 'main',
    required this.startedAt,
    this.directory,
    this.model,
  });
}

/// Result of a completed turn including status and optional error.
class TurnOutcome {
  final String turnId;
  final String sessionId;
  final TurnStatus status;
  final String? errorMessage; // non-null when failed
  final String? responseText; // non-null when completed
  final int inputTokens;
  final int outputTokens;
  final DateTime completedAt;

  int get totalTokens => inputTokens + outputTokens;

  TurnOutcome({
    required this.turnId,
    required this.sessionId,
    required this.status,
    this.errorMessage,
    this.responseText,
    this.inputTokens = 0,
    this.outputTokens = 0,
    required this.completedAt,
  });
}

/// Thrown when a turn cannot start because the agent is already busy.
class BusyTurnException implements Exception {
  final String message;
  final bool isSameSession; // true = same session busy, false = global busy (different session)

  BusyTurnException(this.message, {required this.isSameSession});

  @override
  String toString() => 'BusyTurnException: $message';
}

// ---------------------------------------------------------------------------
// TurnManager
// ---------------------------------------------------------------------------

/// Manages agent turn lifecycle: start, stream, cancel, and drain.
///
/// Thin wrapper around [HarnessPool.primary] — delegates all turn operations
/// to the primary [TurnRunner]. Exposes the [pool] for [TaskExecutor] to
/// acquire task runners.
class TurnManager {
  final HarnessPool _pool;
  late final TurnRunner _primary = _pool.primary;

  /// Backward-compatible constructor: accepts a single [AgentHarness] and wraps
  /// it in a single-runner pool. Used by existing callers and tests that don't
  /// need multi-harness support.
  TurnManager({
    required MessageService messages,
    required AgentHarness worker,
    required BehaviorFileService behavior,
    MemoryFileService? memoryFile,
    SessionService? sessions,
    KvService? kv,
    GuardChain? guardChain,
    SessionLockManager? lockManager,
    SessionResetService? resetService,
    ContextMonitor? contextMonitor,
    ResultTrimmer? resultTrimmer,
    MessageRedactor? redactor,
    SelfImprovementService? selfImprovement,
    UsageTracker? usageTracker,
    Duration outcomeTtl = const Duration(seconds: 30),
  }) : _pool = HarnessPool(
         runners: [
           TurnRunner(
             harness: worker,
             messages: messages,
             behavior: behavior,
             memoryFile: memoryFile,
             sessions: sessions,
             kv: kv,
             guardChain: guardChain,
             lockManager: lockManager,
             resetService: resetService,
             contextMonitor: contextMonitor,
             resultTrimmer: resultTrimmer,
             redactor: redactor,
             selfImprovement: selfImprovement,
             usageTracker: usageTracker,
             outcomeTtl: outcomeTtl,
           ),
         ],
       );

  /// Creates a TurnManager backed by a [HarnessPool].
  TurnManager.fromPool({required HarnessPool pool}) : _pool = pool;

  // ---------------------------------------------------------------------------
  // Public API — delegates to primary TurnRunner
  // ---------------------------------------------------------------------------

  /// The pool backing this manager. Used by [TaskExecutor] to acquire
  /// task runners.
  HarnessPool get pool => _pool;

  Iterable<String> get activeSessionIds sync* {
    for (final runner in _pool.runners) {
      yield* runner.activeSessionIds;
    }
  }

  bool isActive(String sessionId) => _pool.runners.any((runner) => runner.isActive(sessionId));

  String? activeTurnId(String sessionId) {
    for (final runner in _pool.runners) {
      final turnId = runner.activeTurnId(sessionId);
      if (turnId != null) return turnId;
    }
    return null;
  }

  bool isActiveTurn(String sessionId, String turnId) =>
      _pool.runners.any((runner) => runner.isActiveTurn(sessionId, turnId));

  TurnOutcome? recentOutcome(String sessionId, String turnId) {
    for (final runner in _pool.runners) {
      final outcome = runner.recentOutcome(sessionId, turnId);
      if (outcome != null) return outcome;
    }
    return null;
  }

  Future<String> reserveTurn(String sessionId, {String agentName = 'main', String? directory, String? model}) =>
      _primary.reserveTurn(sessionId, agentName: agentName, directory: directory, model: model);

  void executeTurn(
    String sessionId,
    String turnId,
    List<Map<String, dynamic>> messages, {
    String? source,
    String agentName = 'main',
  }) => _primary.executeTurn(sessionId, turnId, messages, source: source, agentName: agentName);

  void releaseTurn(String sessionId, String turnId) => _primary.releaseTurn(sessionId, turnId);

  Future<String> startTurn(
    String sessionId,
    List<Map<String, dynamic>> messages, {
    String? source,
    String agentName = 'main',
    String? model,
  }) => _primary.startTurn(sessionId, messages, source: source, agentName: agentName, model: model);

  Future<void> cancelTurn(String sessionId) async {
    for (final runner in _pool.runners) {
      if (runner.isActive(sessionId)) {
        await runner.cancelTurn(sessionId);
        return;
      }
    }
  }

  Future<void> waitForCompletion(String sessionId, {Duration timeout = const Duration(seconds: 10)}) async {
    for (final runner in _pool.runners) {
      if (runner.isActive(sessionId)) {
        await runner.waitForCompletion(sessionId, timeout: timeout);
        return;
      }
    }
  }

  Future<TurnOutcome> waitForOutcome(String sessionId, String turnId) async {
    for (final runner in _pool.runners) {
      final cached = runner.recentOutcome(sessionId, turnId);
      if (cached != null) return cached;
      if (runner.isActiveTurn(sessionId, turnId)) {
        return runner.waitForOutcome(sessionId, turnId);
      }
    }
    return _primary.waitForOutcome(sessionId, turnId);
  }

  Future<List<String>> detectAndCleanOrphanedTurns() => _primary.detectAndCleanOrphanedTurns();

  bool consumeRecoveryNotice(String sessionId) => _primary.consumeRecoveryNotice(sessionId);
}
