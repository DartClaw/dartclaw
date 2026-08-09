import 'dart:async';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' as core;
import 'package:dartclaw_core/dartclaw_core.dart'
    hide TurnManager, HarnessPool, TurnRunner, TurnOutcome, TurnStatus, BusyTurnException;
import 'package:logging/logging.dart';

import 'behavior/behavior_file_service.dart';
import 'behavior/self_improvement_service.dart';
import 'concurrency/session_lock_manager.dart';
import 'context/context_monitor.dart';
import 'context/exploration_summarizer.dart';
import 'harness_pool.dart';
import 'observability/usage_tracker.dart';
import 'session/session_reset_service.dart';
import 'turn_runner.dart';
import 'turn_wait_status.dart';
import 'worker_pool_coordinator.dart';

// ---------------------------------------------------------------------------
// Data types (re-exported from dartclaw_core for local convenience)
// ---------------------------------------------------------------------------

typedef TurnStatus = core.TurnStatus;
typedef TurnOutcome = core.TurnOutcome;
typedef BusyTurnException = core.BusyTurnException;

/// Metadata for an in-flight agent turn.
class TurnContext {
  final String turnId;
  final String sessionId;
  final String agentName;
  final DateTime startedAt;
  final String? taskId;

  /// Optional working directory override for this turn (e.g. worktree path).
  final String? directory;

  /// Optional per-turn model override for task execution.
  final String? model;

  /// Optional per-turn reasoning effort override.
  final String? effort;

  /// Authoritative system prompt for this turn when non-empty.
  final String? systemPromptOverride;

  /// Optional hard cap on the number of harness turns for this request.
  final int? maxTurns;

  /// Optional task-scoped behavior service override.
  ///
  /// When set, this behavior service is used for system prompt composition
  /// instead of the shared [TurnRunner._behavior] instance. Used by
  /// [TaskExecutor] to read project-specific CLAUDE.md and AGENTS.md files.
  final BehaviorFileService? behaviorOverride;

  /// Prompt scope controlling which workspace behavior files are included.
  ///
  /// When null, [PromptScope.interactive] is used as the default.
  final PromptScope? promptScope;

  /// Optional tool allowlist enforced only for this active turn.
  final List<String>? allowedTools;

  /// Whether this active turn should be evaluated as read-only.
  final bool readOnly;

  TurnContext({
    required this.turnId,
    required this.sessionId,
    this.agentName = 'main',
    required this.startedAt,
    this.taskId,
    this.directory,
    this.model,
    this.effort,
    this.systemPromptOverride,
    this.maxTurns,
    this.behaviorOverride,
    this.promptScope,
    this.allowedTools,
    this.readOnly = false,
  });
}

// ---------------------------------------------------------------------------
// TurnManager
// ---------------------------------------------------------------------------

/// Manages agent turn lifecycle: start, stream, cancel, and drain.
///
/// Uses [HarnessPool.primary] for ordinary sessions and provider-matched task
/// runners for sessions pinned to a specific provider. Exposes the [pool] for
/// [TaskExecutor] to acquire workers.
class TurnManager implements core.TurnManager, Reconfigurable {
  static final _log = Logger('TurnManager');

  final HarnessPool _pool;
  final SessionService? _sessions;
  final WorkerPoolCoordinator? _workerPoolCoordinator;
  late final TurnRunner _primary = _pool.primary;
  final Map<String, TurnRunner> _reservedTurnRunners = {};
  final Map<String, TurnRunner> _providerSessionRunners = {};
  final Map<String, int> _providerSessionReservations = {};
  final Map<String, Future<TurnRunner>> _providerSessionAcquisitions = {};

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
    EventBus? eventBus,
    Duration stallTimeout = Duration.zero,
    TurnProgressAction stallAction = TurnProgressAction.warn,
    TurnMonitorConfig turnMonitor = const TurnMonitorConfig.defaults(),
    Duration? globalTimeout,
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
             eventBus: eventBus,
             stallTimeout: stallTimeout,
             stallAction: stallAction,
             turnMonitor: turnMonitor,
             globalTimeout: globalTimeout,
             outcomeTtl: outcomeTtl,
           ),
         ],
       ),
       _sessions = sessions,
       _workerPoolCoordinator = null;

  /// Creates a TurnManager backed by a [HarnessPool].
  TurnManager.fromPool({
    required HarnessPool pool,
    SessionService? sessions,
    WorkerPoolCoordinator? workerPoolCoordinator,
  }) : _pool = pool,
       _sessions = sessions,
       _workerPoolCoordinator = workerPoolCoordinator;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  @override
  Set<String> get watchKeys => const {'governance.*'};

  @override
  void reconfigure(ConfigDelta delta) {
    _log.info('TurnManager: governance config changed — rate limits and budgets updated at next turn');
  }

  /// The pool backing this manager. Used by [TaskExecutor] to acquire
  /// workers.
  @override
  HarnessPool get pool => _pool;

  /// Number of runners currently available to accept a new task.
  @override
  int get availableRunnerCount => _pool.availableCount;

  @override
  Iterable<String> get activeSessionIds sync* {
    for (final runner in _pool.runners) {
      yield* runner.activeSessionIds;
    }
  }

  @override
  bool isActive(String sessionId) => _pool.runners.any((runner) => runner.isActive(sessionId));

  @override
  String? activeTurnId(String sessionId) {
    for (final runner in _pool.runners) {
      final turnId = runner.activeTurnId(sessionId);
      if (turnId != null) return turnId;
    }
    return null;
  }

  @override
  bool isActiveTurn(String sessionId, String turnId) =>
      _pool.runners.any((runner) => runner.isActiveTurn(sessionId, turnId));

  @override
  TurnOutcome? recentOutcome(String sessionId, String turnId) {
    for (final runner in _pool.runners) {
      final outcome = runner.recentOutcome(sessionId, turnId);
      if (outcome != null) return outcome;
    }
    return null;
  }

  @override
  Future<String> reserveTurn(
    String sessionId, {
    String agentName = 'main',
    String? directory,
    String? model,
    String? effort,
    String? systemPromptOverride,
    String? workerProfile,
    int? maxTurns,
    String? taskId,
    bool isHumanInput = false,
    BehaviorFileService? behaviorOverride,
    PromptScope? promptScope,
    List<String>? allowedTools,
    bool readOnly = false,
  }) async {
    final runner = await _reserveRunnerForSession(sessionId, workerProfile: workerProfile);
    try {
      final turnId = await runner.reserveTurn(
        sessionId,
        agentName: agentName,
        directory: directory,
        model: model,
        effort: effort,
        systemPromptOverride: systemPromptOverride,
        maxTurns: maxTurns,
        taskId: taskId,
        isHumanInput: isHumanInput,
        behaviorOverride: behaviorOverride,
        promptScope: promptScope,
        allowedTools: allowedTools,
        readOnly: readOnly,
      );
      _reservedTurnRunners[turnId] = runner;
      return turnId;
    } catch (_) {
      // Reservation failed — release provider slot if non-primary, then bubble the original error.
      if (!identical(runner, _primary)) {
        _releaseProviderReservation(sessionId, runner);
      }
      rethrow;
    }
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
    final runner = _reservedTurnRunners[turnId] ?? _providerSessionRunners[sessionId] ?? _primary;
    runner.executeTurn(sessionId, turnId, messages, source: source, agentName: agentName, resume: resume);
    unawaited(
      runner.waitForOutcome(sessionId, turnId).whenComplete(() {
        _reservedTurnRunners.remove(turnId);
        if (!identical(runner, _primary)) {
          _releaseProviderReservation(sessionId, runner);
        }
      }),
    );
  }

  @override
  void releaseTurn(String sessionId, String turnId) {
    final runner = _reservedTurnRunners.remove(turnId) ?? _providerSessionRunners[sessionId] ?? _primary;
    runner.releaseTurn(sessionId, turnId);
    if (!identical(runner, _primary)) {
      _releaseProviderReservation(sessionId, runner);
    }
  }

  @override
  Future<void> resetSessionContinuity(String sessionId) async {
    if (isActive(sessionId)) {
      throw BusyTurnException('Cannot reset: turn in progress', isSameSession: true);
    }
    for (final runner in _pool.runners) {
      await runner.resetSessionContinuity(sessionId);
    }
    _providerSessionRunners.remove(sessionId);
    _providerSessionReservations.remove(sessionId);
  }

  /// Clears continuity for a completed provider-pinned session without touching the primary caller.
  Future<void> resetProviderSessionContinuity(String sessionId) async {
    if (isActive(sessionId)) {
      throw BusyTurnException('Cannot reset: turn in progress', isSameSession: true);
    }
    for (final runner in _pool.runners.skip(1)) {
      if (runner.activeSessionIds.isNotEmpty) continue;
      await runner.resetSessionContinuity(sessionId);
    }
    _providerSessionRunners.remove(sessionId);
    _providerSessionReservations.remove(sessionId);
  }

  @override
  Future<String> startTurn(
    String sessionId,
    List<Map<String, dynamic>> messages, {
    String? source,
    String agentName = 'main',
    String? model,
    String? effort,
    String? systemPromptOverride,
    int? maxTurns,
    String? taskId,
    bool isHumanInput = false,
    List<String>? allowedTools,
    bool readOnly = false,
    PromptScope? promptScope,
  }) async {
    final turnId = await reserveTurn(
      sessionId,
      agentName: agentName,
      model: model,
      effort: effort,
      systemPromptOverride: systemPromptOverride,
      maxTurns: maxTurns,
      taskId: taskId,
      isHumanInput: isHumanInput,
      allowedTools: allowedTools,
      readOnly: readOnly,
      promptScope: promptScope,
    );
    try {
      executeTurn(sessionId, turnId, messages, source: source, agentName: agentName);
      return turnId;
    } catch (_) {
      // Execute dispatch failed — release the reserved turn before bubbling.
      releaseTurn(sessionId, turnId);
      rethrow;
    }
  }

  @override
  Future<void> cancelTurn(String sessionId) async {
    for (final runner in _pool.runners) {
      if (runner.isActive(sessionId)) {
        await runner.cancelTurn(sessionId);
        return;
      }
    }
  }

  TurnStatusSnapshot turnStatus(String sessionId) {
    TurnStatusSnapshot? latestTerminal;
    for (final runner in _pool.runners) {
      final status = runner.turnStatus(sessionId);
      switch (status.state) {
        case TurnWaitState.running:
        case TurnWaitState.waiting:
        case TurnWaitState.stuck:
        case TurnWaitState.cancelling:
          return status;
        case TurnWaitState.cancelled:
        case TurnWaitState.completed:
        case TurnWaitState.failed:
          if (_isLaterTerminal(status, latestTerminal)) {
            latestTerminal = status;
          }
        case TurnWaitState.idle:
          break;
      }
    }
    return latestTerminal ?? TurnStatusSnapshot.idle(sessionId);
  }

  Future<TurnCancelResult> cancelTurnById(String sessionId, String turnId, TurnCancelReason reason) async {
    for (final runner in _pool.runners) {
      if (runner.isActiveTurn(sessionId, turnId)) {
        return runner.cancelTurnById(sessionId, turnId, reason);
      }
    }
    for (final runner in _pool.runners) {
      if (runner.recentOutcome(sessionId, turnId) != null) {
        return runner.cancelTurnById(sessionId, turnId, reason);
      }
    }
    throw const TurnCancelException('TURN_NOT_FOUND', 'Turn not found', statusCode: 404);
  }

  bool _isLaterTerminal(TurnStatusSnapshot candidate, TurnStatusSnapshot? current) {
    // Order terminal snapshots by their internal completion timestamp, not the
    // API `global_timeout_at` field (which is null for terminal turns).
    final candidateCompletedAt = candidate.completedAt;
    if (candidateCompletedAt == null) return current == null;
    final currentCompletedAt = current?.completedAt;
    if (currentCompletedAt == null) return true;
    return candidateCompletedAt.isAfter(currentCompletedAt);
  }

  @override
  Future<void> waitForCompletion(String sessionId, {Duration timeout = const Duration(seconds: 10)}) async {
    for (final runner in _pool.runners) {
      if (runner.isActive(sessionId)) {
        await runner.waitForCompletion(sessionId, timeout: timeout);
        return;
      }
    }
  }

  @override
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

  @override
  Future<List<String>> detectAndCleanOrphanedTurns() => _primary.detectAndCleanOrphanedTurns();

  @override
  bool consumeRecoveryNotice(String sessionId) => _primary.consumeRecoveryNotice(sessionId);

  /// Updates the per-task tool allowlist on the primary runner's guard.
  ///
  /// Used by [TaskExecutor] in single-harness mode — passes through to
  /// the primary [TurnRunner.setTaskToolFilter].
  @override
  void setTaskToolFilter(List<String>? allowedTools) {
    _primary.setTaskToolFilter(allowedTools);
  }

  /// Updates the per-task read-only mode on the primary runner's guard.
  ///
  /// Used by [TaskExecutor] in single-harness mode — passes through to
  /// the primary [TurnRunner.setTaskReadOnly].
  @override
  void setTaskReadOnly(bool readOnly) {
    _primary.setTaskReadOnly(readOnly);
  }

  Future<TurnRunner> _reserveRunnerForSession(String sessionId, {String? workerProfile}) async {
    var activeRunner = _providerSessionRunners[sessionId];
    if (activeRunner != null) {
      _providerSessionReservations[sessionId] = (_providerSessionReservations[sessionId] ?? 0) + 1;
      return activeRunner;
    }

    final session = await _sessions?.getSession(sessionId);
    final provider = session?.provider;
    if (provider == null) {
      return _primary;
    }

    activeRunner = _providerSessionRunners[sessionId];
    if (activeRunner != null) {
      _providerSessionReservations[sessionId] = (_providerSessionReservations[sessionId] ?? 0) + 1;
      return activeRunner;
    }

    var acquisition = _providerSessionAcquisitions[sessionId];
    if (acquisition == null) {
      acquisition = _acquireProviderRunner(provider, workerProfile: workerProfile);
      _providerSessionAcquisitions[sessionId] = acquisition;
    }
    try {
      final runner = await acquisition;
      _providerSessionRunners[sessionId] = runner;
      _providerSessionReservations[sessionId] = (_providerSessionReservations[sessionId] ?? 0) + 1;
      return runner;
    } finally {
      if (identical(_providerSessionAcquisitions[sessionId], acquisition)) {
        final removed = _providerSessionAcquisitions.remove(sessionId);
        assert(identical(removed, acquisition));
      }
    }
  }

  Future<TurnRunner> _acquireProviderRunner(String provider, {String? workerProfile}) async {
    final acquired = _workerPoolCoordinator == null
        ? workerProfile == null
              ? _pool.tryAcquireForProvider(provider)
              : _pool.tryAcquireForProviderAndProfile(provider, workerProfile)
        : await _workerPoolCoordinator.provisionAndAcquireProvider(provider, profileId: workerProfile);
    final runner = acquired as TurnRunner?;
    if (runner != null) return runner;
    throw BusyTurnException(
      'Provider "$provider" worker pool unavailable${workerProfile == null ? '' : ' for profile "$workerProfile"'}; '
      'increase providers.$provider.pool_size',
      isSameSession: false,
    );
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
