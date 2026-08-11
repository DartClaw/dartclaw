import 'dart:async';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' as core;
import 'package:dartclaw_core/dartclaw_core.dart'
    hide TurnManager, TurnRunner, TurnOutcome, TurnStatus, BusyTurnException;
import 'package:logging/logging.dart';

import 'behavior/behavior_file_service.dart';
import 'behavior/self_improvement_service.dart';
import 'concurrency/session_lock_manager.dart';
import 'context/context_monitor.dart';
import 'context/exploration_summarizer.dart';
import 'execution_coordinator.dart';
import 'execution_policy_resolver.dart';
import 'observability/usage_tracker.dart';
import 'session/session_reset_service.dart';
import 'turn_runner.dart';
import 'turn_wait_status.dart';

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
/// Routes interactive and provider-pinned sessions through one execution authority.
class TurnManager implements core.TurnManager, Reconfigurable {
  static final _log = Logger('TurnManager');

  final ExecutionCoordinator _executions;
  final SessionService? _sessions;
  final ExecutionPolicyResolver? _policyResolver;
  late final TurnRunner _primary = _executions.primary!;
  final Map<String, TurnRunner> _reservedTurnRunners = {};
  final Map<String, ExecutionLease> _reservedTurnLeases = {};

  /// Composes a single primary harness for SDK and test hosts.
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
  }) : this.fromCoordinator(
         coordinator: _singleHarnessCoordinator(
           messages: messages,
           worker: worker,
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
         sessions: sessions,
       );

  TurnManager.fromCoordinator({
    required ExecutionCoordinator coordinator,
    SessionService? sessions,
    ExecutionPolicyResolver? policyResolver,
  }) : _executions = coordinator,
       _sessions = sessions,
       _policyResolver = policyResolver;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  @override
  Set<String> get watchKeys => const {'governance.*'};

  @override
  void reconfigure(ConfigDelta delta) {
    _log.info('TurnManager: governance config changed — rate limits and budgets updated at next turn');
  }

  ExecutionCoordinator get executions => _executions;

  /// Number of runners currently available to accept a new task.
  @override
  int get availableRunnerCount => _executions.snapshot.availableWorkers;

  @override
  Iterable<String> get activeSessionIds sync* {
    for (final runner in _executions.runners) {
      yield* runner.activeSessionIds;
    }
  }

  @override
  bool isActive(String sessionId) => _executions.runners.any((runner) => runner.isActive(sessionId));

  @override
  String? activeTurnId(String sessionId) {
    for (final runner in _executions.runners) {
      final turnId = runner.activeTurnId(sessionId);
      if (turnId != null) return turnId;
    }
    return null;
  }

  @override
  bool isActiveTurn(String sessionId, String turnId) =>
      _executions.runners.any((runner) => runner.isActiveTurn(sessionId, turnId));

  @override
  TurnOutcome? recentOutcome(String sessionId, String turnId) {
    final retained = _executions.recentOutcome(sessionId, turnId);
    if (retained != null) return retained;
    for (final runner in _executions.runners) {
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
    ExecutionPolicy? workerPolicy,
    int? maxTurns,
    String? taskId,
    bool isHumanInput = false,
    BehaviorFileService? behaviorOverride,
    PromptScope? promptScope,
    List<String>? allowedTools,
    bool readOnly = false,
  }) async {
    final lease = await _reserveExecutionForSession(
      sessionId,
      workerPolicy: workerPolicy,
      taskId: taskId,
      isHumanInput: isHumanInput,
      agentName: agentName,
    );
    final runner = lease.runner!;
    try {
      final turnId = await runner.reserveAdmittedTurn(
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
      _reservedTurnLeases[turnId] = lease;
      return turnId;
    } catch (_) {
      await lease.release();
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
    final runner = _reservedTurnRunners[turnId] ?? _primary;
    runner.executeTurn(sessionId, turnId, messages, source: source, agentName: agentName, resume: resume);
    unawaited(
      runner
          .waitForExecutionSettled(sessionId, turnId)
          .whenComplete(() async {
            _reservedTurnRunners.remove(turnId);
            await _reservedTurnLeases.remove(turnId)?.release();
          })
          .catchError((Object error, StackTrace stackTrace) {
            _log.warning('Turn execution settlement failed', error, stackTrace);
          }),
    );
  }

  @override
  void releaseTurn(String sessionId, String turnId) {
    final runner = _reservedTurnRunners.remove(turnId) ?? _primary;
    runner.releaseTurn(sessionId, turnId);
    unawaited(_reservedTurnLeases.remove(turnId)?.release());
  }

  @override
  Future<void> resetSessionContinuity(String sessionId) async {
    if (isActive(sessionId)) {
      throw BusyTurnException('Cannot reset: turn in progress', isSameSession: true);
    }
    await _executions.resetSessionContinuity(sessionId);
  }

  /// Clears continuity for a completed provider-pinned session without touching the primary caller.
  Future<void> resetProviderSessionContinuity(String sessionId) async {
    if (isActive(sessionId)) {
      throw BusyTurnException('Cannot reset: turn in progress', isSameSession: true);
    }
    await _executions.resetSessionContinuity(sessionId, workersOnly: true);
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
    for (final runner in _executions.runners) {
      if (runner.isActive(sessionId)) {
        await runner.cancelTurn(sessionId);
        return;
      }
    }
  }

  TurnStatusSnapshot turnStatus(String sessionId) {
    TurnStatusSnapshot? latestTerminal;
    for (final runner in _executions.runners) {
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
    final retained = _executions.recentStatus(sessionId);
    if (retained != null && _isLaterTerminal(retained, latestTerminal)) {
      latestTerminal = retained;
    }
    return latestTerminal ?? TurnStatusSnapshot.idle(sessionId);
  }

  Future<TurnCancelResult> cancelTurnById(String sessionId, String turnId, TurnCancelReason reason) async {
    for (final runner in _executions.runners) {
      if (runner.isActiveTurn(sessionId, turnId)) {
        return runner.cancelTurnById(sessionId, turnId, reason);
      }
    }
    final outcome = recentOutcome(sessionId, turnId);
    if (outcome != null) {
      if (outcome.status == TurnStatus.completed || outcome.status == TurnStatus.cancelled) {
        return TurnCancelResult(
          status: outcome.status == TurnStatus.completed ? TurnWaitState.completed : TurnWaitState.cancelled,
          releasedSessionLock: false,
        );
      }
      throw const TurnCancelException('TURN_NOT_CANCELLABLE', 'Turn is not cancellable', statusCode: 409);
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
    for (final runner in _executions.runners) {
      if (runner.isActive(sessionId)) {
        await runner.waitForCompletion(sessionId, timeout: timeout);
        return;
      }
    }
  }

  @override
  Future<TurnOutcome> waitForOutcome(String sessionId, String turnId) async {
    final retained = recentOutcome(sessionId, turnId);
    if (retained != null) return retained;
    final reservedRunner = _reservedTurnRunners[turnId];
    if (reservedRunner != null) {
      return reservedRunner.waitForOutcome(sessionId, turnId);
    }
    for (final runner in _executions.runners) {
      final cached = runner.recentOutcome(sessionId, turnId);
      if (cached != null) return cached;
      if (runner.isActiveTurn(sessionId, turnId)) {
        return runner.waitForOutcome(sessionId, turnId);
      }
    }
    throw ArgumentError('Unknown turnId: $turnId');
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

  Future<ExecutionLease> _reserveExecutionForSession(
    String sessionId, {
    ExecutionPolicy? workerPolicy,
    String? taskId,
    required bool isHumanInput,
    String? agentName,
  }) async {
    final session = await _sessions?.getSession(sessionId);
    final provider = session?.provider ?? _primary.providerId;
    final policy = workerPolicy ?? await _sessionExecutionPolicy(session);
    final isLogicalAgent = session?.type == SessionType.logicalAgent;
    final surface = switch (session?.type) {
      SessionType.cron => ExecutionSurface.scheduler,
      SessionType.channel => ExecutionSurface.channel,
      SessionType.logicalAgent => ExecutionSurface.logicalAgent,
      SessionType.task => ExecutionSurface.task,
      _ => ExecutionSurface.interactive,
    };
    final lease = await _executions.acquire(
      ExecutionRequest(
        surface: surface,
        providerId: provider,
        policy: policy,
        sessionId: sessionId,
        admission: isLogicalAgent ? ExecutionAdmission.failFast : ExecutionAdmission.wait,
        isHumanInput: isHumanInput,
        taskId: taskId,
        logicalAgentId: isLogicalAgent ? agentName : null,
      ),
    );
    if (lease != null) return lease;
    throw BusyTurnException(
      'Provider "$provider" worker capacity unavailable for ${policy.describe()} execution; '
      'increase providers.$provider.pool_size',
      isSameSession: false,
    );
  }

  /// Resolves the execution policy pinned to [session].
  ///
  /// Sessions without pinned routing follow the primary runner, preserving the
  /// deployment's effective placement for interactive and inherited work. A
  /// session pinned before execution mode existed has its mode derived once and
  /// persisted forward.
  Future<ExecutionPolicy> _sessionExecutionPolicy(Session? session) async {
    final resolver = _policyResolver;
    if (session == null || resolver == null) return _primary.executionPolicy;
    if (session.executionMode == null && session.securityProfile == null) return _primary.executionPolicy;
    final policy = resolver.resolveForPinnedSession(
      sessionId: session.id,
      executionMode: session.executionMode,
      securityProfile: session.securityProfile,
    );
    if (session.executionMode == null) {
      await _sessions?.updateExecutionMode(session.id, policy.mode);
    }
    return policy;
  }
}

ExecutionCoordinator _singleHarnessCoordinator({
  required MessageService messages,
  required AgentHarness worker,
  required BehaviorFileService behavior,
  required MemoryFileService? memoryFile,
  required SessionService? sessions,
  required KvService? kv,
  required GuardChain? guardChain,
  required TaskToolFilterGuard? taskToolFilterGuard,
  required SessionLockManager? lockManager,
  required SessionResetService? resetService,
  required ContextMonitor? contextMonitor,
  required ExplorationSummarizer? explorationSummarizer,
  required MessageRedactor? redactor,
  required SelfImprovementService? selfImprovement,
  required UsageTracker? usageTracker,
  required EventBus? eventBus,
  required Duration stallTimeout,
  required TurnProgressAction stallAction,
  required TurnMonitorConfig turnMonitor,
  required Duration? globalTimeout,
  required Duration outcomeTtl,
}) {
  final primary = TurnRunner(
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
  );
  return ExecutionCoordinator(
    providerCapacities: const {},
    createWorker: (_) => throw StateError('Worker execution is unavailable in single-harness mode'),
    primary: primary,
    allowPrimaryBackgroundFallback: true,
    admitExecution: (request) => primary.admitTurn(request.sessionId, isHumanInput: request.isHumanInput),
    releaseAdmission: primary.releaseAdmission,
    outcomeTtl: outcomeTtl,
  );
}
