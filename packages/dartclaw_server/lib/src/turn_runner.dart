import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' as core show TurnRunner;
import 'package:dartclaw_core/dartclaw_core.dart' hide TurnRunner, TurnOutcome, TurnStatus, BusyTurnException;
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

import 'api/sse_broadcast.dart';
import 'behavior/behavior_file_service.dart';
import 'behavior/self_improvement_service.dart';
import 'concurrency/session_lock_manager.dart';
import 'context/context_monitor.dart';
import 'context/exploration_summarizer.dart';
import 'governance/budget_enforcer.dart';
import 'logging/log_context.dart';
import 'observability/usage_tracker.dart';
import 'session/session_reset_service.dart';
import 'turn_governance_enforcer.dart';
import 'turn_guard_evaluator.dart';
import 'turn_manager.dart';
import 'turn_progress_monitor.dart';
import 'turn_wait_status.dart';

part 'turn_runner_cancellation.dart';

/// Per-harness turn execution engine.
///
/// Encapsulates the full turn lifecycle for a single [AgentHarness]: guard
/// evaluation, message persistence, event streaming, cost tracking, and crash
/// recovery. Multiple [TurnRunner] instances execute concurrently — one per
/// harness in the [HarnessPool].
class TurnRunner implements core.TurnRunner {
  static final _log = Logger('TurnRunner');
  static const _uuid = Uuid();
  static const _memoryWarnBytes = 50 * 1024;

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
  final ExplorationSummarizer _explorationSummarizer;
  final MessageRedactor? _redactor;
  final SelfImprovementService? _selfImprovement;
  final UsageTracker? _usageTracker;
  final SseBroadcast? _sseBroadcast;
  final TurnGuardEvaluator _guardEvaluator;
  final TurnGovernanceEnforcer _governanceEnforcer;
  final TaskToolFilterGuard? _taskToolFilterGuard;
  final LoopAction? _loopAction;
  final EventBus? _eventBus;
  final Duration _stallTimeout;
  final TurnProgressAction _stallAction;
  final TurnMonitorConfig _turnMonitor;
  final SessionLockTimerFactory _turnMonitorTimerFactory;
  final SessionLockNow _turnMonitorNow;
  final Duration? _globalTimeout;
  final Duration _outcomeTtl;

  /// Tracks turn IDs that were cancelled due to mid-turn loop detection.
  final Map<String, LoopDetection> _loopDetectedTurns = {};

  /// Security profile this runner's harness executes in (e.g. 'workspace', 'restricted').
  @override
  final String profileId;

  /// Agent provider backing this runner's harness (e.g. 'claude', 'codex').
  @override
  final String providerId;

  final _progressController = StreamController<TurnProgressEvent>.broadcast();
  Duration _statusTickInterval = Duration.zero;
  final Map<String, TurnProgressSnapshot Function()> _turnProgressSnapshots = {};

  final Map<String, TurnContext> _activeTurns = {};
  final Set<String> _cancelledTurns = {};
  final Set<String> _cancellingTurns = {};
  final Set<String> _externallyCompletedTurns = {};
  final Set<String> _acceptedCancelCleanupPending = {};
  final Map<String, Future<void>> _acceptedCancelRecovery = {};
  final Map<String, ({TurnOutcome outcome, DateTime expiresAt})> _recentOutcomes = {};
  final Map<String, String> _recentTaskIds = {};
  final Map<String, Completer<TurnOutcome>> _outcomePending = {};
  final Set<String> _recoveredSessions = {};
  final Map<String, _RuntimeWaitTracker> _runtimeWaits = {};

  TurnRunner({
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
    ExplorationSummarizer? explorationSummarizer,
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
    Duration stallTimeout = Duration.zero,
    TurnProgressAction stallAction = TurnProgressAction.warn,
    TurnMonitorConfig turnMonitor = const TurnMonitorConfig.defaults(),
    SessionLockTimerFactory? turnMonitorTimerFactory,
    SessionLockNow? turnMonitorNow,
    Duration? globalTimeout,
    Duration outcomeTtl = const Duration(seconds: 30),
    Future<void> Function(String sessionId, BudgetCheckResult result)? budgetWarningNotifier,
    this.profileId = 'workspace',
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
       _explorationSummarizer = explorationSummarizer ?? ExplorationSummarizer(),
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
       _stallTimeout = stallTimeout,
       _stallAction = stallAction,
       _turnMonitor = turnMonitor,
       _turnMonitorTimerFactory = turnMonitorTimerFactory ?? Timer.new,
       _turnMonitorNow = turnMonitorNow ?? DateTime.now,
       _globalTimeout = globalTimeout,
       _outcomeTtl = outcomeTtl;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// The underlying harness managed by this runner.
  @override
  AgentHarness get harness => _worker;

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

  /// Whether [turnId] is still tracked as externally completed. Should be false
  /// once `executeTurn` has exited via any path — used to assert no leak.
  @visibleForTesting
  bool tracksExternalCompletion(String turnId) => _externallyCompletedTurns.contains(turnId);

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
    int? maxTurns,
    String? taskId,
    bool isHumanInput = false,
    BehaviorFileService? behaviorOverride,
    PromptScope? promptScope,
    List<String>? allowedTools,
    bool readOnly = false,
  }) async {
    // Governance checks happen before the session lock so blocked turns do not
    // hold the lock while waiting or failing fast.
    await _governanceEnforcer.checkBudget(sessionId);
    await _governanceEnforcer.checkLoopPreTurn(sessionId, isHumanInput: isHumanInput);
    await _governanceEnforcer.awaitRateLimitWindow();

    await _lockManager.acquire(
      sessionId,
      waitWarningAfter: _turnMonitor.waitWarningAfter,
      stuckAfter: _turnMonitor.stuckAfter,
      onWaiting: () => _emitWaitState(sessionId, TurnWaitState.waiting),
      onStuck: () => _emitWaitState(sessionId, TurnWaitState.stuck),
    );
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
      maxTurns: maxTurns,
      taskId: taskId,
      behaviorOverride: behaviorOverride,
      promptScope: promptScope,
      allowedTools: allowedTools,
      readOnly: readOnly,
    );
    _outcomePending[turnId] = Completer<TurnOutcome>();
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

  /// Launches async execution for a previously [reserveTurn]'d turn.
  @override
  void executeTurn(
    String sessionId,
    String turnId,
    List<Map<String, dynamic>> messages, {
    String? source,
    String agentName = 'main',
    bool resume = false,
  }) {
    unawaited(_runTurn(sessionId: sessionId, turnId: turnId, messages: messages, source: source, resume: resume));
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
    _lockManager.release(sessionId);
    _outcomePending.remove(turnId)?.completeError(StateError('Turn released without execution'));
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
    _taskToolFilterGuard?.setSessionToolFilter(sessionId, null);
    _taskToolFilterGuard?.setSessionReadOnly(sessionId, false);
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
    int? maxTurns,
    String? taskId,
    bool isHumanInput = false,
    List<String>? allowedTools,
    bool readOnly = false,
  }) async {
    final turnId = await reserveTurn(
      sessionId,
      agentName: agentName,
      model: model,
      effort: effort,
      maxTurns: maxTurns,
      taskId: taskId,
      isHumanInput: isHumanInput,
      allowedTools: allowedTools,
      readOnly: readOnly,
    );
    executeTurn(sessionId, turnId, messages, source: source, agentName: agentName);
    return turnId;
  }

  @override
  Future<void> cancelTurn(String sessionId) async {
    final turnId = _activeTurns[sessionId]?.turnId;
    if (turnId == null) return;
    await cancelTurnById(sessionId, turnId, TurnCancelReason.operatorCancel, enforceCanCancel: false);
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

  /// Configures a best-effort notifier for newly emitted budget warnings.
  set budgetWarningNotifier(Future<void> Function(String sessionId, BudgetCheckResult result)? notifier) {
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

  Future<String> _buildSystemPrompt(String sessionId) async {
    // Use task-scoped behavior override when present (project-backed tasks).
    final turnContext = _activeTurns[sessionId];
    final effectiveBehavior = turnContext?.behaviorOverride ?? _behavior;
    final scope = turnContext?.promptScope ?? PromptScope.interactive;

    if (_worker.promptStrategy == PromptStrategy.append) {
      if (scope == PromptScope.webInteractive && effectiveBehavior.hasFreshOnboardingSentinel(logStale: true)) {
        return effectiveBehavior.composeStaticPrompt(scope: scope);
      }
      return '';
    }

    final behaviorPrompt = await effectiveBehavior.composeSystemPrompt(scope: scope);

    final memFile = _memoryFile;
    if (memFile != null) {
      await memFile.readMemory();
      if (memFile.lastMemorySize > _memoryWarnBytes) {
        _log.warning(
          'MEMORY.md is ${memFile.lastMemorySize} bytes (>${_memoryWarnBytes ~/ 1024}KB) — consider pruning',
        );
      }
    }

    final agentsContent = await effectiveBehavior.composeAppendPrompt(scope: scope);
    if (agentsContent.isEmpty) return behaviorPrompt;
    return '$behaviorPrompt\n\n$agentsContent';
  }

  Future<void> _runTurn({
    required String sessionId,
    required String turnId,
    required List<Map<String, dynamic>> messages,
    String? source,
    bool resume = false,
  }) async {
    return LogContext.runWith(
      () => _runTurnInner(sessionId: sessionId, turnId: turnId, messages: messages, source: source, resume: resume),
      sessionId: sessionId,
      turnId: turnId,
    );
  }

  Future<void> _runTurnInner({
    required String sessionId,
    required String turnId,
    required List<Map<String, dynamic>> messages,
    String? source,
    bool resume = false,
  }) async {
    final buffer = StringBuffer();
    final stopwatch = Stopwatch()..start();
    final turnPolicy = _activeTurns[sessionId];
    if (turnPolicy?.allowedTools != null) {
      _taskToolFilterGuard?.setSessionToolFilter(sessionId, turnPolicy!.allowedTools);
    }
    if (turnPolicy?.readOnly ?? false) {
      _taskToolFilterGuard?.setSessionReadOnly(sessionId, true);
    }
    var progressTextLength = 0;
    final progressMonitor = _stallTimeout > Duration.zero
        ? TurnProgressMonitor(
            stallTimeout: _stallTimeout,
            onStall: (stallTimeout) =>
                _handleTurnStall(sessionId: sessionId, turnId: turnId, stallTimeout: stallTimeout),
            timerFactory: _turnMonitorTimerFactory,
          )
        : null;

    late final TurnToolHookCallbackHandler toolHooks;
    TurnProgressSnapshot buildSnapshot() => TurnProgressSnapshot(
      elapsed: stopwatch.elapsed,
      toolCallCount: toolHooks.toolCallCount,
      lastToolName: toolHooks.lastToolName,
      textLength: progressTextLength,
    );
    toolHooks = TurnToolHookCallbackHandler(
      sessionId: sessionId,
      turnId: turnId,
      governanceEnforcer: _governanceEnforcer,
      resetService: _resetService,
      progressMonitor: progressMonitor,
      loopAction: _loopAction,
      buildSnapshot: buildSnapshot,
      emitProgressEvent: _progressController.add,
      onLoopAbort: (detection) {
        _loopDetectedTurns[turnId] = detection;
        unawaited(cancelTurnById(sessionId, turnId, TurnCancelReason.automationCancel, enforceCanCancel: false));
      },
    );
    _turnProgressSnapshots[sessionId] = buildSnapshot;
    _RuntimeWaitTracker? runtimeWait;

    String? userMessageFull;
    if (messages.isNotEmpty) {
      final last = messages.last;
      if (last['role'] == 'user') {
        userMessageFull = last['content'] as String?;
      }
    }
    final userMessage = userMessageFull != null ? truncate(userMessageFull, 100, suffix: '...') : null;

    final eventSub = _worker.events.listen((event) {
      if (event is DeltaEvent) {
        buffer.write(event.text);
        progressMonitor?.recordProgress();
        runtimeWait?.recordActivity(TurnWaitReason.unknown);
        _resetService?.touchActivity(sessionId);
        progressTextLength += event.text.length;
        _progressController.add(TextDeltaProgressEvent(snapshot: buildSnapshot(), text: event.text));
      } else if (event is ToolUseEvent) {
        runtimeWait?.recordActivity(TurnWaitReason.unknown);
        toolHooks.handleToolUse(event);
      } else if (event is ToolResultEvent) {
        runtimeWait?.recordActivity(TurnWaitReason.unknown);
        toolHooks.handleToolResult(event);
      } else if (event is ToolApprovalWaitEvent) {
        runtimeWait?.recordActivity(TurnWaitReason.toolApproval);
      } else if (event is ToolApprovalResolvedEvent) {
        runtimeWait?.recordActivity(TurnWaitReason.unknown);
      } else if (event is ProviderProgressBridgeEvent) {
        progressMonitor?.recordProgress();
        runtimeWait?.recordActivity(_waitReasonForProviderProgress(event.kind));
        _resetService?.touchActivity(sessionId);
        _progressController.add(ProviderProgressEvent(snapshot: buildSnapshot(), kind: event.kind, text: event.text));
      } else if (event is SystemInitEvent) {
        runtimeWait?.recordActivity(TurnWaitReason.unknown);
        _contextMonitor.update(contextWindow: event.contextWindow);
      } else if (event is CompactionStartingBridgeEvent) {
        _eventBus?.fire(CompactionStartingEvent(sessionId: sessionId, trigger: 'auto', timestamp: DateTime.now()));
      } else if (event is CompactionCompletedBridgeEvent) {
        _eventBus?.fire(CompactionCompletedEvent(sessionId: sessionId, trigger: 'auto', timestamp: DateTime.now()));
      }
    });

    TurnOutcome? outcome;
    Timer? statusTickTimer;
    try {
      try {
        final guardOutcome = await _guardEvaluator.evaluateMessageReceived(
          turnId: turnId,
          sessionId: sessionId,
          source: source,
          userMessageFull: userMessageFull,
        );
        if (guardOutcome != null) {
          outcome = guardOutcome;
          return;
        }

        final systemPrompt = await _buildSystemPrompt(sessionId);
        final turnCtx = _activeTurns[sessionId];
        await _awaitAcceptedCancelRecovery(sessionId);
        if (_externallyCompletedTurns.contains(turnId)) {
          outcome = TurnOutcome(
            turnId: turnId,
            sessionId: sessionId,
            status: TurnStatus.cancelled,
            completedAt: DateTime.now(),
          );
          return;
        }
        _log.info(
          'Turn start: session=$sessionId, turn=$turnId, '
          'provider=$providerId${userMessage != null ? ', prompt=$userMessage' : ''}',
        );
        statusTickTimer = _statusTickInterval > Duration.zero
            ? Timer.periodic(_statusTickInterval, (_) {
                _progressController.add(StatusTickProgressEvent(snapshot: buildSnapshot()));
              })
            : null;
        progressMonitor?.start();
        runtimeWait = _RuntimeWaitTracker(
          waitWarningAfter: _turnMonitor.waitWarningAfter,
          stuckAfter: _turnMonitor.stuckAfter,
          timerFactory: _turnMonitorTimerFactory,
          now: _turnMonitorNow,
          initialReason: TurnWaitReason.unknown,
          onWaiting: () => _emitWaitState(sessionId, TurnWaitState.waiting),
          onStuck: () => _emitWaitState(sessionId, TurnWaitState.stuck),
        );
        _runtimeWaits[sessionId] = runtimeWait;
        final result = await _worker.turn(
          sessionId: sessionId,
          messages: messages,
          systemPrompt: systemPrompt,
          directory: turnCtx?.directory,
          model: turnCtx?.model,
          effort: turnCtx?.effort,
          maxTurns: turnCtx?.maxTurns,
          resume: resume,
        );
        if (_externallyCompletedTurns.remove(turnId)) {
          outcome = TurnOutcome(
            turnId: turnId,
            sessionId: sessionId,
            status: TurnStatus.cancelled,
            completedAt: DateTime.now(),
          );
          return;
        }
        final accumulated = buffer.toString();
        toolHooks.finalizePendingToolCalls();
        stopwatch.stop();
        _log.info(
          'Turn complete: session=$sessionId, turn=$turnId, '
          'provider=$providerId, ${stopwatch.elapsedMilliseconds}ms, '
          'tools=${toolHooks.toolCallCount}, text=${accumulated.length} chars',
        );
        final cacheReadTokens = _worker.supportsCachedTokens ? (result['cache_read_tokens'] as int? ?? 0) : 0;
        final cacheWriteTokens = _worker.supportsCachedTokens ? (result['cache_write_tokens'] as int? ?? 0) : 0;

        try {
          await _trackSessionUsage(sessionId, result, providerId);
          await _applySessionMetadata(sessionId, result);
          _contextMonitor.update(contextTokens: result['input_tokens'] as int?);
        } catch (e) {
          _log.warning('Failed to track usage', e);
        }

        final tracker = _usageTracker;
        if (tracker != null) {
          final turnCtx = _activeTurns[sessionId];
          final inputTokens = result['input_tokens'] as int? ?? 0;
          final outputTokens = result['output_tokens'] as int? ?? 0;
          final durationMs = turnCtx != null ? DateTime.now().difference(turnCtx.startedAt).inMilliseconds : 0;
          unawaited(
            tracker
                .record(
                  UsageEvent(
                    timestamp: DateTime.now(),
                    sessionId: sessionId,
                    agentName: turnCtx?.agentName ?? 'main',
                    model: result['model'] as String?,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    durationMs: durationMs,
                  ),
                )
                .catchError((Object e) {
                  _log.fine('Failed to record usage', e);
                }),
          );

          // Post-hoc token velocity check (Mechanism 2).
          try {
            _governanceEnforcer.recordTokensAndCheckVelocity(sessionId, inputTokens + outputTokens);
            // Velocity detection post-hoc: fire warn event even in abort mode
            // (tokens already spent). Next pre-turn check will abort if still over.
          } catch (e) {
            _log.fine('Loop velocity check failed (non-fatal): $e');
          }
        }

        // Check context warning threshold (one-shot per session).
        try {
          if (_contextMonitor.checkThreshold(sessionId: sessionId)) {
            final percent = _contextMonitor.usagePercent ?? 0;
            _sseBroadcast?.broadcast('context_warning', {
              'sessionId': sessionId,
              'usagePercent': percent,
              'message':
                  'Context window $percent% used — consider starting '
                  'a new session or saving context to memory.',
            });
          }
        } catch (e) {
          _log.fine('Failed to emit context warning: $e');
        }

        if (accumulated.isNotEmpty) {
          final sendOutcome = await _guardEvaluator.evaluateBeforeAgentSend(
            turnId: turnId,
            sessionId: sessionId,
            accumulated: accumulated,
          );
          if (sendOutcome != null) {
            outcome = sendOutcome;
            return;
          }
        }

        if (result['stop_reason'] == 'cancelled') {
          outcome = TurnOutcome(
            turnId: turnId,
            sessionId: sessionId,
            status: TurnStatus.cancelled,
            inputTokens: result['input_tokens'] as int? ?? 0,
            outputTokens: result['output_tokens'] as int? ?? 0,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            turnDuration: stopwatch.elapsed,
            toolCalls: List.unmodifiable(toolHooks.completedToolCalls),
            completedAt: DateTime.now(),
          );
          return;
        }

        final redacted = _redactor?.redact(accumulated) ?? accumulated;
        final trimmed = _explorationSummarizer.summarizeOrTrim(
          redacted,
          fileHint: _lastToolFileHint(toolHooks.toolEvents),
        );
        await _messages.insertMessage(sessionId: sessionId, role: 'assistant', content: trimmed);
        await _sessions?.touchUpdatedAt(sessionId);
        outcome = TurnOutcome(
          turnId: turnId,
          sessionId: sessionId,
          status: TurnStatus.completed,
          responseText: trimmed,
          inputTokens: result['input_tokens'] as int? ?? 0,
          outputTokens: result['output_tokens'] as int? ?? 0,
          cacheReadTokens: cacheReadTokens,
          cacheWriteTokens: cacheWriteTokens,
          turnDuration: stopwatch.elapsed,
          toolCalls: List.unmodifiable(toolHooks.completedToolCalls),
          completedAt: DateTime.now(),
        );

        try {
          await _appendDailyLog(
            sessionId: sessionId,
            userMessage: userMessage,
            toolEvents: toolHooks.toolEvents,
            result: redacted,
          );
        } catch (e) {
          _log.warning('Failed to write daily log', e);
        }

        if (_contextMonitor.shouldFlushForCompactionSignal(compactionSignalAvailable: _worker.supportsPreCompactHook)) {
          try {
            await _runFlushTurn(sessionId);
          } catch (e) {
            _log.warning('Pre-compaction flush failed (lossy compaction possible)', e);
          }
        }
      } catch (e, st) {
        final wasCancelled = _cancelledTurns.remove(turnId);
        _cancellingTurns.remove(turnId);
        final acceptedCancel =
            _acceptedCancelCleanupPending.contains(turnId) || _externallyCompletedTurns.contains(turnId);
        final loopDetection = _loopDetectedTurns.remove(turnId);
        if (wasCancelled) {
          _log.info('Turn $turnId cancelled');
        } else {
          _log.warning('Turn $turnId failed', e, st);
        }
        if (!acceptedCancel) {
          try {
            var partial = buffer.toString();
            if (partial.isNotEmpty && _redactor != null) {
              partial = _redactor.redact(partial);
            }
            // Post loop detection message if this was a loop-cancelled turn.
            final loopMsg = loopDetection != null ? '[Loop detected: ${loopDetection.message}]' : null;
            await _messages.insertMessage(
              sessionId: sessionId,
              role: 'assistant',
              content:
                  loopMsg ?? (partial.isNotEmpty ? partial : (wasCancelled ? '[Turn cancelled]' : '[Turn failed]')),
            );
          } catch (e) {
            _log.warning('Failed to persist partial message after turn failure: $e');
          }
        }
        outcome = TurnOutcome(
          turnId: turnId,
          sessionId: sessionId,
          status: wasCancelled ? TurnStatus.cancelled : TurnStatus.failed,
          errorMessage: wasCancelled ? null : 'Turn execution failed',
          completedAt: DateTime.now(),
          loopDetection: loopDetection,
        );
        if (!acceptedCancel) {
          unawaited(
            _selfImprovement?.appendError(
              errorType: wasCancelled ? 'TURN_CANCELLED' : 'TURN_FAILURE',
              sessionId: sessionId,
              context: '$e',
            ),
          );
        }
      }
    } finally {
      if (turnPolicy?.allowedTools != null) {
        _taskToolFilterGuard?.setSessionToolFilter(sessionId, null);
      }
      if (turnPolicy?.readOnly ?? false) {
        _taskToolFilterGuard?.setSessionReadOnly(sessionId, false);
      }
      statusTickTimer?.cancel();
      progressMonitor?.stop();
      await eventSub.cancel();
      final activeStillThisTurn = _activeTurns[sessionId]?.turnId == turnId;
      final cancelCleanupPending = _acceptedCancelCleanupPending.contains(turnId);
      if (activeStillThisTurn) {
        _turnProgressSnapshots.remove(sessionId);
        _runtimeWaits.remove(sessionId)?.dispose();
      }
      final recentTaskId = activeStillThisTurn ? _activeTurns[sessionId]?.taskId : _recentTaskIds[turnId];
      final resolved =
          outcome ??
          TurnOutcome(
            turnId: turnId,
            sessionId: sessionId,
            status: TurnStatus.failed,
            errorMessage: 'Unexpected internal error',
            completedAt: DateTime.now(),
          );
      if (!cancelCleanupPending) {
        _rememberRecentOutcome(resolved, taskId: recentTaskId);
        _outcomePending.remove(turnId)?.complete(resolved);
      }
      if (activeStillThisTurn && !cancelCleanupPending) {
        switch (resolved.status) {
          case TurnStatus.completed:
            _emitWaitState(sessionId, TurnWaitState.completed);
          case TurnStatus.failed:
            _emitWaitState(sessionId, TurnWaitState.failed);
          case TurnStatus.cancelled:
            _emitWaitState(sessionId, TurnWaitState.cancelled);
        }
      }
      // All reads of this set (711, 748, catch at 897) run before finally, so an
      // unconditional remove here only closes the leak on throw/early-return paths.
      _externallyCompletedTurns.remove(turnId);
      if (!cancelCleanupPending) _cancellingTurns.remove(turnId);
      if (activeStillThisTurn && !cancelCleanupPending) {
        _activeTurns.remove(sessionId);
        _lockManager.release(sessionId);
      }
      _governanceEnforcer.cleanupTurn(turnId);

      final turnState = _turnState;
      if (turnState != null && activeStillThisTurn && !cancelCleanupPending) {
        unawaited(
          turnState.delete(sessionId).catchError((Object e, StackTrace st) {
            _log.warning('Failed to clean up turn state', e, st);
          }),
        );
      }
    }
  }

  Future<void> _trackSessionUsage(String sessionId, Map<String, dynamic> result, String provider) async {
    final kv = _kv;
    if (kv == null) return;

    final key = 'session_cost:$sessionId';
    final existing = await kv.get(key);
    Map<String, dynamic> costData;
    if (existing != null) {
      costData = jsonDecode(existing) as Map<String, dynamic>;
    } else {
      costData = {
        'input_tokens': 0,
        'output_tokens': 0,
        'cache_read_tokens': 0,
        'cache_write_tokens': 0,
        'total_tokens': 0,
        'effective_tokens': 0,
        'estimated_cost_usd': 0.0,
        'turn_count': 0,
      };
    }

    final inputTokens = result['input_tokens'] as int? ?? 0;
    final outputTokens = result['output_tokens'] as int? ?? 0;
    final cacheReadTokens = (result['cache_read_tokens'] as num?)?.toInt() ?? 0;
    final cacheWriteTokens = (result['cache_write_tokens'] as num?)?.toInt() ?? 0;
    final costUsd = _worker.supportsCostReporting ? (result['total_cost_usd'] as num?)?.toDouble() ?? 0.0 : 0.0;
    final existingProvider = switch (costData['provider']) {
      final String value when value.trim().isNotEmpty => value,
      _ => null,
    };
    final effectiveDelta = computeEffectiveTokens(
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cacheReadTokens: cacheReadTokens,
      cacheWriteTokens: cacheWriteTokens,
    );

    costData['input_tokens'] = ((costData['input_tokens'] as num?)?.toInt() ?? 0) + inputTokens;
    costData['output_tokens'] = ((costData['output_tokens'] as num?)?.toInt() ?? 0) + outputTokens;
    costData['cache_read_tokens'] = ((costData['cache_read_tokens'] as num?)?.toInt() ?? 0) + cacheReadTokens;
    costData['cache_write_tokens'] = ((costData['cache_write_tokens'] as num?)?.toInt() ?? 0) + cacheWriteTokens;
    costData['total_tokens'] = ((costData['total_tokens'] as num?)?.toInt() ?? 0) + inputTokens + outputTokens;
    costData['effective_tokens'] = ((costData['effective_tokens'] as num?)?.toInt() ?? 0) + effectiveDelta;
    costData['estimated_cost_usd'] = (costData['estimated_cost_usd'] as num).toDouble() + costUsd;
    costData['turn_count'] = ((costData['turn_count'] as num?)?.toInt() ?? 0) + 1;
    costData['provider'] = existingProvider ?? provider;

    await kv.set(key, jsonEncode(costData));
  }

  Future<void> _applySessionMetadata(String sessionId, Map<String, dynamic> result) async {
    final sessions = _sessions;
    if (sessions == null) return;
    final title = switch (result['session_title']) {
      final String value when value.trim().isNotEmpty => value.trim(),
      _ => null,
    };
    if (title != null) {
      await sessions.updateTitle(sessionId, title);
    }
  }

  Future<void> _appendDailyLog({
    required String sessionId,
    required String? userMessage,
    required List<ToolUseEvent> toolEvents,
    required String result,
  }) async {
    final memFile = _memoryFile;
    if (memFile == null || toolEvents.isEmpty) return;

    final now = DateTime.now();
    final time = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    var title = 'Chat';
    final sessions = _sessions;
    if (sessions != null) {
      try {
        final session = await sessions.getSession(sessionId);
        final t = session?.title;
        if (t != null && t.isNotEmpty) title = t;
      } catch (e) {
        _log.fine('Failed to fetch session title for daily log: $e');
      }
    }

    final seen = <String>{};
    final toolSummaries = <String>[];
    for (final t in toolEvents) {
      final key = '${t.toolName}:${t.input.values.firstOrNull ?? ''}';
      if (seen.add(key)) {
        final arg = t.input.values.firstOrNull;
        final argStr = arg != null ? truncate(arg.toString(), 50, suffix: '...') : '';
        toolSummaries.add('${t.toolName}($argStr)');
      }
    }

    final resultSnippet = truncate(result, 100, suffix: '...');
    final entry =
        '## $time — $title\n'
        '**User**: ${userMessage ?? '(no message)'}\n'
        '**Tools**: ${toolSummaries.join(', ')}\n'
        '**Result**: $resultSnippet';

    await memFile.appendDailyLog(entry);
  }

  static const _flushPrompt =
      'You are approaching your context limit. Before context compression '
      'occurs, save any important information from this conversation to MEMORY.md using the '
      'memory_save tool. Focus on:\n'
      '1. Key facts, decisions, or preferences mentioned by the user\n'
      '2. Important context about ongoing tasks\n'
      '3. Any information that would be lost during compression\n\n'
      'Save concisely. Do not ask for confirmation — just save what\'s important.';

  Future<void> _runFlushTurn(String sessionId) async {
    // SHA-256 dedup + cycle-aware skip: compute hash of last 3 messages.
    final messageHash = await _computeFlushHash(sessionId);
    if (_contextMonitor.shouldSkipFlush(messageHash)) {
      _log.info('Pre-compaction flush skipped (dedup) for session $sessionId');
      return;
    }

    _contextMonitor.markFlushStarted();
    try {
      final systemPrompt = await _buildSystemPrompt(sessionId);
      final flushMessage = <String, dynamic>{'role': 'user', 'content': _flushPrompt};
      await _worker.turn(sessionId: sessionId, messages: [flushMessage], systemPrompt: systemPrompt);
      _contextMonitor.markFlushed(messageHash);
      _log.info('Pre-compaction flush completed for session $sessionId');
    } finally {
      _contextMonitor.markFlushCompleted();
    }
  }

  /// Computes a SHA-256 hash of the last 3 messages for flush dedup.
  ///
  /// On any error, returns an empty string (fail-open: flush proceeds).
  Future<String> _computeFlushHash(String sessionId) async {
    try {
      final messages = await _messages.getMessagesTail(sessionId, count: 3);
      final content = messages.map((m) => m.content).join('\n');
      return sha256.convert(utf8.encode(content)).toString();
    } catch (e) {
      _log.warning('Failed to compute flush hash for $sessionId — proceeding with flush', e);
      return '';
    }
  }

  /// Extracts a file path hint from the last tool use event for type detection.
  ///
  /// Returns the file path if the last tool was a file-reading tool, or null
  /// if no hint can be extracted.
  static String? _lastToolFileHint(List<ToolUseEvent> toolEvents) {
    if (toolEvents.isEmpty) return null;
    final last = toolEvents.last;
    final name = last.toolName.toLowerCase();
    if (name == 'read' || name == 'view') {
      final path = last.input['file_path'];
      if (path is String) return path;
    }
    if (name == 'bash' || name == 'shell') {
      // Best-effort: look for a file path in the command (e.g. "cat /path/to/file.json")
      final cmd = last.input['command'];
      if (cmd is String) {
        final match = RegExp(r'[\w./\-]+\.\w+').firstMatch(cmd);
        if (match != null) return match.group(0);
      }
    }
    return null;
  }
}
