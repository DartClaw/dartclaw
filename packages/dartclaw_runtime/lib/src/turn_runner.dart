import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' as core show TurnRunner;
import 'package:dartclaw_core/dartclaw_core.dart' hide TurnRunner, TurnOutcome, TurnStatus, BusyTurnException;
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

import 'api/sse_broadcast.dart';
import 'behavior/behavior_file_service.dart';
import 'behavior/self_improvement_service.dart';
import 'concurrency/session_lock_manager.dart';
import 'context/context_monitor.dart';
import 'governance/budget_enforcer.dart';
import 'logging/log_context.dart';
import 'observability/usage_tracker.dart';
import 'session/session_reset_service.dart';
import 'turn_governance_enforcer.dart';
import 'turn_guard_evaluator.dart';
import 'turn_manager.dart';
import 'turn_liveness_tracker.dart';
import 'turn_wait_status.dart';

part 'turn_runner_cancellation.dart';
part 'turn_runner_execution.dart';
part 'turn_runner_execution_loop.dart';
part 'turn_runner_memory.dart';

/// Per-harness turn execution engine.
///
/// Encapsulates the full turn lifecycle for a single [AgentHarness]: guard
/// evaluation, message persistence, event streaming, cost tracking, and crash
/// recovery. Multiple [TurnRunner] instances execute concurrently — one per
/// harness behind one coordinator lease.
class TurnRunner implements core.TurnRunner {
  static final _log = Logger('TurnRunner');
  static const _uuid = Uuid();
  static String? _harnessAgentId(String? agentName) => agentName == null || agentName == 'main' ? null : agentName;

  final AgentHarness _worker;
  final MessageService _messages;
  final BehaviorFileService _behavior;
  final MemoryFileService? _memoryFile;
  final SessionService? _sessions;
  final TurnStateStore? _turnState;
  final KvService? _kv;
  final SessionLockManager _lockManager;
  final SessionResetService? _resetService;
  final ContextMonitor _contextMonitor;
  final MessageRedactor? _redactor;
  final SelfImprovementService? _selfImprovement;
  final UsageTracker? _usageTracker;
  final SseBroadcast? _sseBroadcast;
  final TurnGuardEvaluator _guardEvaluator;
  final TurnGovernanceEnforcer _governanceEnforcer;
  final TaskToolFilterGuard? _taskToolFilterGuard;
  final LoopAction? _loopAction;
  final EventBus? _eventBus;
  final TurnLimitsConfig _turnLimits;
  final SessionLockTimerFactory _livenessTimerFactory;
  final SessionLockNow _livenessNow;
  final Duration _outcomeTtl;
  void Function(TurnOutcome outcome)? _outcomeObserver;
  var _isReusable = true;

  /// Tracks turn IDs that were cancelled due to mid-turn loop detection.
  final Map<String, LoopDetection> _loopDetectedTurns = {};

  /// Where this runner's harness actually executes.
  ///
  /// Defaults to host execution, so a caller wiring a container-backed harness
  /// must pass the resolved policy — it is the reported placement, the
  /// worker-reuse identity, and the predicate that keeps container-backed
  /// runners out of the reuse cache.
  @override
  final ExecutionPolicy executionPolicy;

  /// Agent provider backing this runner's harness (e.g. 'claude', 'codex').
  @override
  final String providerId;

  final _progressController = StreamController<TurnProgressEvent>.broadcast();
  Duration _statusTickInterval = Duration.zero;
  final Map<String, TurnProgressSnapshot Function()> _turnProgressSnapshots = {};
  final _turnToolHooks = Map<String, TurnToolHookCallbackHandler>.of(const {});

  final Map<String, TurnContext> _activeTurns = {};
  final Set<String> _cancelledTurns = {};
  final Set<String> _cancellingTurns = {};
  final Set<String> _externallyAdmittedTurns = {};
  final Set<String> _externallyCompletedTurns = {};
  final _postProviderTurns = <String>{};
  final Set<String> _acceptedCancelCleanupPending = {};
  final Map<String, Future<void>> _acceptedCancelRecovery = {};
  final Map<String, ({TurnOutcome outcome, DateTime expiresAt})> _recentOutcomes = {};
  final Map<String, String> _recentTaskIds = {};
  final Map<String, Completer<TurnOutcome>> _outcomePending = {};
  final Map<String, ({String sessionId, Completer<void> completer})> _executionSettledPending = {};
  final Map<String, String> _turnPolicyOwners = {};
  final Set<String> _recoveredSessions = {};
  final Map<String, TurnLivenessTracker> _runtimeWaits = {};
  final Map<String, ({TurnLimitBreach breach, Duration budget})> _limitBreaches = {};

  /// Installs the coordinator-owned observer for terminal turn outcomes.
  @internal
  void setOutcomeObserver(void Function(TurnOutcome outcome)? observer) {
    _outcomeObserver = observer;
  }

  new({
    required AgentHarness harness,
    required MessageService messages,
    required BehaviorFileService behavior,
    MemoryFileService? memoryFile,
    SessionService? sessions,
    TurnStateStore? turnState,
    KvService? kv,
    GuardChain? guardChain,
    TaskToolFilterGuard? taskToolFilterGuard,
    SessionLockManager? lockManager,
    SessionResetService? resetService,
    ContextMonitor? contextMonitor,
    MessageRedactor? redactor,
    SelfImprovementService? selfImprovement,
    UsageTracker? usageTracker,
    SseBroadcast? sseBroadcast,
    TurnGuardEvaluator? guardEvaluator,
    TurnGovernanceEnforcer? governanceEnforcer,
    SlidingWindowRateLimiter? globalRateLimiter,
    BudgetEnforcer? budgetEnforcer,
    LoopDetector? loopDetector,
    LoopAction? loopAction,
    EventBus? eventBus,
    required TurnLimitsConfig turnLimits,
    SessionLockTimerFactory? turnMonitorTimerFactory,
    SessionLockNow? turnMonitorNow,
    Duration outcomeTtl = const Duration(seconds: 30),
    BudgetWarningNotifier? budgetWarningNotifier,
    this.executionPolicy = const ExecutionPolicy.host(),
    this.providerId = 'claude',
  }) : _worker = harness,
       _messages = messages,
       _behavior = behavior,
       _memoryFile = memoryFile,
       _sessions = sessions,
       _turnState = turnState,
       _kv = kv,
       _lockManager = lockManager ?? SessionLockManager(timerFactory: turnMonitorTimerFactory, now: turnMonitorNow),
       _resetService = resetService,
       _contextMonitor = contextMonitor ?? ContextMonitor(),
       _redactor = redactor,
       _selfImprovement = selfImprovement,
       _usageTracker = usageTracker,
       _sseBroadcast = sseBroadcast,
       _guardEvaluator =
           guardEvaluator ??
           TurnGuardEvaluator(
             guardChain: guardChain,
             messages: messages,
             sessions: sessions,
             selfImprovement: selfImprovement,
           ),
       _governanceEnforcer =
           governanceEnforcer ??
           TurnGovernanceEnforcer(
             budgetEnforcer: budgetEnforcer,
             globalRateLimiter: globalRateLimiter,
             loopDetector: loopDetector,
             loopAction: loopAction,
             sseBroadcast: sseBroadcast,
             eventBus: eventBus,
             budgetWarningNotifier: budgetWarningNotifier,
           ),
       _taskToolFilterGuard = taskToolFilterGuard,
       _loopAction = loopAction,
       _eventBus = eventBus,
       _turnLimits = turnLimits,
       _livenessTimerFactory = turnMonitorTimerFactory ?? Timer.new,
       _livenessNow = turnMonitorNow ?? DateTime.now,
       _outcomeTtl = outcomeTtl;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// The underlying harness managed by this runner.
  @override
  AgentHarness get harness => _worker;

  /// Turn budgets enforced by this runner.
  @internal
  TurnLimitsConfig get turnLimits => _turnLimits;

  @internal
  bool get isReusable => _isReusable;

  /// Structured progress events for the current turn.
  ///
  /// Replaces direct harness event subscription for progress tracking.
  /// Subscribers receive [TurnProgressEvent] subtypes that include a
  /// [TurnProgressSnapshot] at the time of emission.
  Stream<TurnProgressEvent> get progressEvents => _progressController.stream;

  /// Sets the periodic status tick interval. When positive, a
  /// [StatusTickProgressEvent] is emitted at this interval during turns.
  /// Defaults to [Duration.zero] (no ticks).
  set statusTickInterval(Duration interval) => _statusTickInterval = interval;

  @override
  Iterable<String> get activeSessionIds => _activeTurns.keys;

  @override
  bool isActive(String sessionId) => _activeTurns.containsKey(sessionId);

  @override
  String? activeTurnId(String sessionId) => _activeTurns[sessionId]?.turnId;

  @override
  bool isActiveTurn(String sessionId, String turnId) => _activeTurns[sessionId]?.turnId == turnId;

  @override
  TurnOutcome? recentOutcome(String sessionId, String turnId) {
    _evictExpiredOutcomes();
    final entry = _recentOutcomes[turnId];
    if (entry == null) return null;
    return entry.outcome.sessionId == sessionId ? entry.outcome : null;
  }

  /// Reserves a new turn slot for [sessionId].
  /// Returns the new [turnId]. Throws [BusyTurnException] if global cap reached.
  /// Same-session requests queue behind the active turn.
  /// Call [executeTurn] to start async execution, or [releaseTurn] to roll back.
  @override
  Future<String> reserveTurn(
    String sessionId, {
    String agentName = 'main',
    String? directory,
    String? model,
    String? effort,
    String? systemPromptOverride,
    int? maxTurns,
    Map<String, dynamic>? outputSchema,
    String? providerSessionId,
    bool requestProviderSessionResume = false,
    String? taskId,
    Duration? turnTimeout,
    bool isHumanInput = false,
    BehaviorFileService? behaviorOverride,
    List<String>? allowedTools,
    bool readOnly = false,
    PromptScope? promptScope,
  }) async {
    await admitTurn(sessionId, isHumanInput: isHumanInput);
    try {
      return _reserveTurnState(
        sessionId,
        agentName: agentName,
        directory: directory,
        model: model,
        effort: effort,
        systemPromptOverride: systemPromptOverride,
        maxTurns: maxTurns,
        outputSchema: outputSchema,
        providerSessionId: providerSessionId,
        requestProviderSessionResume: requestProviderSessionResume,
        taskId: taskId,
        turnTimeout: turnTimeout,
        behaviorOverride: behaviorOverride,
        isHumanInput: isHumanInput,
        allowedTools: allowedTools,
        readOnly: readOnly,
        promptScope: promptScope,
        externallyAdmitted: false,
      );
    } catch (_) {
      releaseAdmission(sessionId);
      rethrow;
    }
  }

  /// Applies deployment governance and session admission before execution allocation.
  Future<void> admitTurn(String sessionId, {required bool isHumanInput}) async {
    await _governanceEnforcer.checkBudget(sessionId);
    await _governanceEnforcer.checkLoopPreTurn(sessionId, isHumanInput: isHumanInput);
    await _governanceEnforcer.awaitRateLimitWindow();

    await _lockManager.acquire(
      sessionId,
      waitWarningAfter: const Duration(seconds: 30),
      stuckAfter: const Duration(seconds: 120),
      onWaiting: () => _emitWaitState(sessionId, TurnWaitState.waiting),
      onStuck: () => _emitWaitState(sessionId, TurnWaitState.stuck),
    );
  }

  /// Reserves turn-local state after the coordinator has admitted the session.
  Future<String> reserveAdmittedTurn(
    String sessionId, {
    String agentName = 'main',
    String? directory,
    String? model,
    String? effort,
    String? systemPromptOverride,
    int? maxTurns,
    Map<String, dynamic>? outputSchema,
    String? providerSessionId,
    bool requestProviderSessionResume = false,
    String? taskId,
    Duration? turnTimeout,
    bool isHumanInput = false,
    BehaviorFileService? behaviorOverride,
    List<String>? allowedTools,
    bool readOnly = false,
    PromptScope? promptScope,
  }) async => _reserveTurnState(
    sessionId,
    agentName: agentName,
    directory: directory,
    model: model,
    effort: effort,
    systemPromptOverride: systemPromptOverride,
    maxTurns: maxTurns,
    outputSchema: outputSchema,
    providerSessionId: providerSessionId,
    requestProviderSessionResume: requestProviderSessionResume,
    taskId: taskId,
    turnTimeout: turnTimeout,
    behaviorOverride: behaviorOverride,
    isHumanInput: isHumanInput,
    allowedTools: allowedTools,
    readOnly: readOnly,
    promptScope: promptScope,
    externallyAdmitted: true,
  );

  String _reserveTurnState(
    String sessionId, {
    required String agentName,
    required String? directory,
    required String? model,
    required String? effort,
    required String? systemPromptOverride,
    required int? maxTurns,
    required Map<String, dynamic>? outputSchema,
    required String? providerSessionId,
    required bool requestProviderSessionResume,
    required String? taskId,
    required Duration? turnTimeout,
    required BehaviorFileService? behaviorOverride,
    required bool isHumanInput,
    required List<String>? allowedTools,
    required bool readOnly,
    required PromptScope? promptScope,
    required bool externallyAdmitted,
  }) {
    // One turn per worker at a time. A provider process — Claude Code's
    // stream-json session, Codex's app-server — drives one turn, and a
    // `DeltaEvent` carries no turn identity, so a second concurrent turn on
    // this runner corrupts both: two providers' output assembled into one
    // buffer, and two overlapping turns driven into one process. Session
    // admission cannot see this: it locks per session, and parallel workflow
    // steps are distinct sessions sharing one leased worker.
    //
    // This is the invariant's backstop, not its scheduler — capacity and
    // idle-worker selection belong to `ExecutionCoordinator`. Reaching here
    // means something admitted two turns onto one worker.
    final busy = _activeTurns.entries.firstOrNull;
    if (busy != null) {
      throw BusyTurnException(
        'This worker is already running a turn for session ${busy.key}',
        isSameSession: busy.key == sessionId,
      );
    }

    final turnId = _uuid.v4();
    final startedAt = DateTime.now();
    _activeTurns[sessionId] = TurnContext(
      turnId: turnId,
      sessionId: sessionId,
      agentName: agentName,
      startedAt: startedAt,
      directory: directory,
      model: model,
      effort: effort,
      systemPromptOverride: systemPromptOverride,
      maxTurns: maxTurns,
      outputSchema: outputSchema,
      providerSessionId: providerSessionId,
      requestProviderSessionResume: requestProviderSessionResume,
      taskId: taskId,
      turnTimeout: turnTimeout,
      behaviorOverride: behaviorOverride,
      isHumanInput: isHumanInput,
      allowedTools: allowedTools,
      readOnly: readOnly,
      promptScope: promptScope,
    );
    if (externallyAdmitted) _externallyAdmittedTurns.add(turnId);
    _outcomePending[turnId] = Completer<TurnOutcome>();
    final settled = Completer<void>();
    settled.future.ignore();
    _executionSettledPending[turnId] = (sessionId: sessionId, completer: settled);
    _resetService?.touchActivity(sessionId);
    _emitWaitState(sessionId, TurnWaitState.running);

    final turnState = _turnState;
    if (turnState != null) {
      unawaited(
        turnState.set(sessionId, turnId, startedAt).catchError((Object e, StackTrace st) {
          _log.warning('Failed to persist turn state for crash recovery', e, st);
        }),
      );
    }

    return turnId;
  }

  void releaseAdmission(String sessionId) => _lockManager.release(sessionId);

  /// Launches async execution for a previously [reserveTurn]'d turn.
  @override
  void executeTurn(
    String sessionId,
    String turnId,
    List<Map<String, dynamic>> messages, {
    String? source,
    String agentName = 'main',
  }) {
    unawaited(_runTurnAndSettle(sessionId: sessionId, turnId: turnId, messages: messages, source: source));
  }

  /// Rolls back a [reserveTurn] reservation without executing.
  @override
  void releaseTurn(String sessionId, String turnId) {
    final turnState = _turnState;
    if (turnState != null) {
      unawaited(
        turnState.delete(sessionId).catchError((Object e, StackTrace st) {
          _log.warning('Failed to clean up turn state during release', e, st);
        }),
      );
    }
    _activeTurns.remove(sessionId);
    if (!_externallyAdmittedTurns.contains(turnId)) _lockManager.release(sessionId);
    _outcomePending.remove(turnId)?.completeError(StateError('Turn released without execution'));
    _completeExecutionSettlement(turnId);
  }

  @override
  Future<void> resetSessionContinuity(String sessionId) async {
    if (_activeTurns.isNotEmpty) {
      throw BusyTurnException(
        'Cannot reset session continuity while a turn is in progress',
        isSameSession: _activeTurns.containsKey(sessionId),
      );
    }
    _recentOutcomes.removeWhere((_, entry) => entry.outcome.sessionId == sessionId);
    _recoveredSessions.remove(sessionId);
    _turnProgressSnapshots.remove(sessionId);
    _forceClearTurnPolicy(sessionId);
    await _turnState?.delete(sessionId);
    await _worker.resetSessionContinuity(sessionId);
  }

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
    Duration? turnTimeout,
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
      turnTimeout: turnTimeout,
      isHumanInput: isHumanInput,
      allowedTools: allowedTools,
      readOnly: readOnly,
      promptScope: promptScope,
    );
    executeTurn(sessionId, turnId, messages, source: source, agentName: agentName);
    return turnId;
  }

  @override
  Future<void> cancelTurn(String sessionId) async {
    final turnId = _activeTurns[sessionId]?.turnId;
    if (turnId == null) return;
    try {
      await cancelTurnById(sessionId, turnId, TurnCancelReason.operatorCancel, enforceCanCancel: false);
    } on TurnCancelException catch (e) {
      if (e.code != 'TURN_NOT_CANCELLABLE') rethrow;
      final settlement = waitForExecutionSettled(sessionId, turnId);
      await settlement;
    }
  }

  @override
  Future<void> waitForCompletion(String sessionId, {Duration timeout = const Duration(seconds: 10)}) async {
    final turnId = _activeTurns[sessionId]?.turnId;
    if (turnId == null) return;

    final pending = _outcomePending[turnId];
    if (pending == null) return;

    await pending.future.timeout(timeout);
  }

  @override
  Future<TurnOutcome> waitForOutcome(String sessionId, String turnId) async {
    final cached = recentOutcome(sessionId, turnId);
    if (cached != null) return cached;

    final pending = _outcomePending[turnId];
    if (pending != null) return pending.future;

    throw ArgumentError('Unknown turnId: $turnId');
  }

  /// Waits until provider execution and any accepted-cancel recovery have both settled.
  Future<void> waitForExecutionSettled(String sessionId, String turnId) async {
    final pending = _executionSettledPending[turnId];
    if (pending != null) {
      if (pending.sessionId != sessionId) throw ArgumentError('Unknown turnId: $turnId');
      return pending.completer.future;
    }
    if (recentOutcome(sessionId, turnId) != null) return;
    throw ArgumentError('Unknown turnId: $turnId');
  }

  void _installTurnPolicy(String sessionId, String turnId, List<String>? allowedTools, bool readOnly) {
    _turnPolicyOwners[sessionId] = turnId;
    _taskToolFilterGuard?.setSessionToolFilter(sessionId, allowedTools);
    _taskToolFilterGuard?.setSessionReadOnly(sessionId, readOnly);
  }

  void _clearTurnPolicy(String sessionId, String turnId) {
    if (_turnPolicyOwners[sessionId] != turnId) return;
    _forceClearTurnPolicy(sessionId);
  }

  void _forceClearTurnPolicy(String sessionId) {
    _turnPolicyOwners.remove(sessionId);
    _taskToolFilterGuard?.setSessionToolFilter(sessionId, null);
    _taskToolFilterGuard?.setSessionReadOnly(sessionId, false);
  }

  /// Configures a best-effort notifier for newly emitted budget warnings.
  set budgetWarningNotifier(BudgetWarningNotifier? notifier) {
    _governanceEnforcer.budgetWarningNotifier = notifier;
  }

  /// Configures a best-effort notifier for loop detection events.
  set loopDetectionNotifier(Future<void> Function(String sessionId, LoopDetection detection, String action)? notifier) {
    _governanceEnforcer.loopDetectionNotifier = notifier;
  }

  /// Updates the per-task tool allowlist on the underlying [TaskToolFilterGuard].
  ///
  /// Called by [TaskExecutor] before each task turn to activate filtering,
  /// and after the turn (with null) to restore pass-through mode.
  /// No-op when this runner has no [TaskToolFilterGuard].
  @override
  void setTaskToolFilter(List<String>? allowedTools) {
    _taskToolFilterGuard?.allowedTools = allowedTools;
  }

  /// Enables or disables per-task read-only enforcement.
  ///
  /// When enabled, the underlying [TaskToolFilterGuard] blocks mutating shell
  /// commands and file-edit tools for the duration of the task turn.
  @override
  void setTaskReadOnly(bool readOnly) {
    _taskToolFilterGuard?.readOnly = readOnly;
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------
}
