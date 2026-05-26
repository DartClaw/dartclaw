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

  /// Prompt scope controlling which workspace behavior files are included.
  ///
  /// When null, [PromptScope.interactive] is used as the default.
  final PromptScope? promptScope;

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
    this.promptScope,
  });
}

// ---------------------------------------------------------------------------
// TurnManager
// ---------------------------------------------------------------------------

/// Manages agent turn lifecycle: start, stream, cancel, and drain.
///
/// Uses [HarnessPool.primary] for ordinary sessions and provider-matched task
/// runners for sessions pinned to a specific provider. Exposes the [pool] for
/// [TaskExecutor] to acquire task runners.
class TurnManager implements core.TurnManager, Reconfigurable {
  static final _log = Logger('TurnManager');

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

  @override
  Set<String> get watchKeys => const {'governance.*'};

  @override
  void reconfigure(ConfigDelta delta) {
    _log.info('TurnManager: governance config changed — rate limits and budgets updated at next turn');
  }

  /// The pool backing this manager. Used by [TaskExecutor] to acquire
  /// task runners.
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
    int? maxTurns,
    bool isHumanInput = false,
    BehaviorFileService? behaviorOverride,
    PromptScope? promptScope,
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
        promptScope: promptScope,
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
