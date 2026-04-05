import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';

import 'behavior/behavior_file_service.dart';
import 'behavior/self_improvement_service.dart';
import 'concurrency/session_lock_manager.dart';
import 'context/context_monitor.dart';
import 'context/exploration_summarizer.dart';
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

  /// Optional per-turn reasoning effort override.
  final String? effort;

  /// Optional hard cap on the number of harness turns for this request.
  final int? maxTurns;

  /// Optional task-scoped behavior service override.
  ///
  /// When set, this behavior service is used for system prompt composition
  /// instead of the shared [TurnRunner._behavior] instance. Used by
  /// [TaskExecutor] to read project-specific CLAUDE.md and AGENTS.md files.
  final BehaviorFileService? behaviorOverride;

  TurnContext({
    required this.turnId,
    required this.sessionId,
    this.agentName = 'main',
    required this.startedAt,
    this.directory,
    this.model,
    this.effort,
    this.maxTurns,
    this.behaviorOverride,
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
  final int cacheReadTokens;
  final int cacheWriteTokens;
  final Duration turnDuration;
  final List<ToolCallRecord> toolCalls;
  final DateTime completedAt;

  /// Non-null when the turn was cancelled due to mid-turn loop detection.
  ///
  /// [TaskExecutor] checks this field to distinguish loop-caused cancellation
  /// from user-initiated cancellation, and transitions the task to `failed`.
  final LoopDetection? loopDetection;

  int get totalTokens => inputTokens + outputTokens;

  TurnOutcome({
    required this.turnId,
    required this.sessionId,
    required this.status,
    this.errorMessage,
    this.responseText,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
    this.turnDuration = Duration.zero,
    this.toolCalls = const [],
    required this.completedAt,
    this.loopDetection,
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
/// Uses [HarnessPool.primary] for ordinary sessions and provider-matched task
/// runners for sessions pinned to a specific provider. Exposes the [pool] for
/// [TaskExecutor] to acquire task runners.
class TurnManager {
  final HarnessPool _pool;
  final SessionService? _sessions;
  late final TurnRunner _primary = _pool.primary;
  final Map<String, TurnRunner> _reservedTurnRunners = {};
  final Map<String, TurnRunner> _providerSessionRunners = {};
  final Map<String, int> _providerSessionReservations = {};

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
    TaskToolFilterGuard? taskToolFilterGuard,
    SessionLockManager? lockManager,
    SessionResetService? resetService,
    ContextMonitor? contextMonitor,
    ExplorationSummarizer? explorationSummarizer,
    MessageRedactor? redactor,
    SelfImprovementService? selfImprovement,
    UsageTracker? usageTracker,
    Duration stallTimeout = Duration.zero,
    TurnProgressAction stallAction = TurnProgressAction.warn,
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
             taskToolFilterGuard: taskToolFilterGuard,
             lockManager: lockManager,
             resetService: resetService,
             contextMonitor: contextMonitor,
             explorationSummarizer: explorationSummarizer,
             redactor: redactor,
             selfImprovement: selfImprovement,
             usageTracker: usageTracker,
             stallTimeout: stallTimeout,
             stallAction: stallAction,
             outcomeTtl: outcomeTtl,
           ),
         ],
       ),
       _sessions = sessions;

  /// Creates a TurnManager backed by a [HarnessPool].
  TurnManager.fromPool({required HarnessPool pool, SessionService? sessions}) : _pool = pool, _sessions = sessions;

  // ---------------------------------------------------------------------------
  // Public API
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

  Future<String> reserveTurn(
    String sessionId, {
    String agentName = 'main',
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
    bool isHumanInput = false,
    BehaviorFileService? behaviorOverride,
  }) async {
    final runner = await _reserveRunnerForSession(sessionId);
    try {
      final turnId = await runner.reserveTurn(
        sessionId,
        agentName: agentName,
        directory: directory,
        model: model,
        effort: effort,
        maxTurns: maxTurns,
        isHumanInput: isHumanInput,
        behaviorOverride: behaviorOverride,
      );
      _reservedTurnRunners[turnId] = runner;
      return turnId;
    } catch (_) {
      if (!identical(runner, _primary)) {
        _releaseProviderReservation(sessionId, runner);
      }
      rethrow;
    }
  }

  void executeTurn(
    String sessionId,
    String turnId,
    List<Map<String, dynamic>> messages, {
    String? source,
    String agentName = 'main',
  }) {
    final runner = _reservedTurnRunners[turnId] ?? _providerSessionRunners[sessionId] ?? _primary;
    runner.executeTurn(sessionId, turnId, messages, source: source, agentName: agentName);
    unawaited(
      runner.waitForOutcome(sessionId, turnId).whenComplete(() {
        _reservedTurnRunners.remove(turnId);
        if (!identical(runner, _primary)) {
          _releaseProviderReservation(sessionId, runner);
        }
      }),
    );
  }

  void releaseTurn(String sessionId, String turnId) {
    final runner = _reservedTurnRunners.remove(turnId) ?? _providerSessionRunners[sessionId] ?? _primary;
    runner.releaseTurn(sessionId, turnId);
    if (!identical(runner, _primary)) {
      _releaseProviderReservation(sessionId, runner);
    }
  }

  Future<String> startTurn(
    String sessionId,
    List<Map<String, dynamic>> messages, {
    String? source,
    String agentName = 'main',
    String? model,
    String? effort,
    int? maxTurns,
    bool isHumanInput = false,
  }) async {
    final turnId = await reserveTurn(
      sessionId,
      agentName: agentName,
      model: model,
      effort: effort,
      maxTurns: maxTurns,
      isHumanInput: isHumanInput,
    );
    try {
      executeTurn(sessionId, turnId, messages, source: source, agentName: agentName);
      return turnId;
    } catch (_) {
      releaseTurn(sessionId, turnId);
      rethrow;
    }
  }

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
    final reservedRunner = _reservedTurnRunners[turnId];
    if (reservedRunner != null) {
      return reservedRunner.waitForOutcome(sessionId, turnId);
    }
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

  /// Updates the per-task tool allowlist on the primary runner's guard.
  ///
  /// Used by [TaskExecutor] in single-harness mode — passes through to
  /// the primary [TurnRunner.setTaskToolFilter].
  void setTaskToolFilter(List<String>? allowedTools) {
    _primary.setTaskToolFilter(allowedTools);
  }

  Future<TurnRunner> _reserveRunnerForSession(String sessionId) async {
    final activeRunner = _providerSessionRunners[sessionId];
    if (activeRunner != null) {
      _providerSessionReservations[sessionId] = (_providerSessionReservations[sessionId] ?? 0) + 1;
      return activeRunner;
    }

    final session = await _sessions?.getSession(sessionId);
    final provider = session?.provider;
    if (provider == null) {
      return _primary;
    }

    // Provider-pinned interactive sessions fail fast instead of silently
    // falling back to another provider or queueing behind the generic pool.
    if (!_pool.hasTaskRunnerForProvider(provider)) {
      throw BusyTurnException('Provider $provider is unavailable for session turns', isSameSession: false);
    }

    final runner = _pool.tryAcquireForProvider(provider);
    if (runner == null) {
      throw BusyTurnException('No idle $provider workers available', isSameSession: false);
    }
    _providerSessionRunners[sessionId] = runner;
    _providerSessionReservations[sessionId] = 1;
    return runner;
  }

  void _releaseProviderReservation(String sessionId, TurnRunner runner) {
    final remaining = (_providerSessionReservations[sessionId] ?? 1) - 1;
    if (remaining > 0) {
      _providerSessionReservations[sessionId] = remaining;
      return;
    }
    _providerSessionReservations.remove(sessionId);
    _providerSessionRunners.remove(sessionId);
    _pool.release(runner);
  }
}
