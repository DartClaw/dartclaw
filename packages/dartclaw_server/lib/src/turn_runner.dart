import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:logging/logging.dart';
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

/// Per-harness turn execution engine.
///
/// Encapsulates the full turn lifecycle for a single [AgentHarness]: guard
/// evaluation, message persistence, event streaming, cost tracking, and crash
/// recovery. Multiple [TurnRunner] instances execute concurrently — one per
/// harness in the [HarnessPool].
class TurnRunner {
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
  final Duration _stallTimeout;
  final TurnProgressAction _stallAction;
  final Duration _outcomeTtl;

  /// Tracks turn IDs that were cancelled due to mid-turn loop detection.
  final Map<String, LoopDetection> _loopDetectedTurns = {};

  /// Security profile this runner's harness executes in (e.g. 'workspace', 'restricted').
  final String profileId;

  /// Agent provider backing this runner's harness (e.g. 'claude', 'codex').
  final String providerId;

  final _progressController = StreamController<TurnProgressEvent>.broadcast();
  Duration _statusTickInterval = Duration.zero;
  final Map<String, TurnProgressSnapshot Function()> _turnProgressSnapshots = {};

  final Map<String, TurnContext> _activeTurns = {};
  final Set<String> _cancelledTurns = {};
  final Map<String, ({TurnOutcome outcome, DateTime expiresAt})> _recentOutcomes = {};
  final Map<String, Completer<TurnOutcome>> _outcomePending = {};
  final Set<String> _recoveredSessions = {};

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
       _lockManager = lockManager ?? SessionLockManager(),
       _resetService = resetService,
       _contextMonitor = contextMonitor ?? ContextMonitor(),
       _explorationSummarizer = explorationSummarizer ?? const ExplorationSummarizer(),
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
       _stallTimeout = stallTimeout,
       _stallAction = stallAction,
       _outcomeTtl = outcomeTtl;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// The underlying harness managed by this runner.
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

  Iterable<String> get activeSessionIds => _activeTurns.keys;

  bool isActive(String sessionId) => _activeTurns.containsKey(sessionId);

  String? activeTurnId(String sessionId) => _activeTurns[sessionId]?.turnId;

  bool isActiveTurn(String sessionId, String turnId) => _activeTurns[sessionId]?.turnId == turnId;

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
    // Governance checks happen before the session lock so blocked turns do not
    // hold the lock while waiting or failing fast.
    await _governanceEnforcer.checkBudget(sessionId);
    await _governanceEnforcer.checkLoopPreTurn(sessionId, isHumanInput: isHumanInput);
    await _governanceEnforcer.awaitRateLimitWindow();

    await _lockManager.acquire(sessionId);
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
      behaviorOverride: behaviorOverride,
    );
    _outcomePending[turnId] = Completer<TurnOutcome>();
    _resetService?.touchActivity(sessionId);

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
  void executeTurn(
    String sessionId,
    String turnId,
    List<Map<String, dynamic>> messages, {
    String? source,
    String agentName = 'main',
  }) {
    unawaited(_runTurn(sessionId: sessionId, turnId: turnId, messages: messages, source: source));
  }

  /// Rolls back a [reserveTurn] reservation without executing.
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
    executeTurn(sessionId, turnId, messages, source: source, agentName: agentName);
    return turnId;
  }

  Future<void> cancelTurn(String sessionId) async {
    final turnId = _activeTurns[sessionId]?.turnId;
    if (turnId == null) return;
    _cancelledTurns.add(turnId);
    await _worker.cancel();
  }

  Future<void> waitForCompletion(String sessionId, {Duration timeout = const Duration(seconds: 10)}) async {
    final turnId = _activeTurns[sessionId]?.turnId;
    if (turnId == null) return;

    final pending = _outcomePending[turnId];
    if (pending == null) return;

    await pending.future.timeout(timeout);
  }

  Future<TurnOutcome> waitForOutcome(String sessionId, String turnId) async {
    final cached = recentOutcome(sessionId, turnId);
    if (cached != null) return cached;

    final pending = _outcomePending[turnId];
    if (pending != null) return pending.future;

    throw ArgumentError('Unknown turnId: $turnId');
  }

  /// Scans [TurnStateStore] for orphaned turns from a previous crash.
  Future<List<String>> detectAndCleanOrphanedTurns() async {
    final turnState = _turnState;
    if (turnState == null) return [];

    try {
      final orphans = await turnState.getAll();
      if (orphans.isEmpty) return [];

      final sessionIds = <String>[];
      for (final entry in orphans.entries) {
        final sessionId = entry.key;
        sessionIds.add(sessionId);

        final turnId = entry.value.turnId;
        final startedAt = entry.value.startedAt.toIso8601String();
        _log.warning('Orphaned turn detected: session=$sessionId, turn=$turnId, started=$startedAt');
        await turnState.delete(sessionId);
      }

      _recoveredSessions.addAll(sessionIds);
      _log.info('Cleaned up ${sessionIds.length} orphaned turn(s)');
      return sessionIds;
    } catch (e) {
      _log.warning('Failed to detect orphaned turns', e);
      return [];
    }
  }

  /// Returns true (once) if this session recovered from a crash.
  bool consumeRecoveryNotice(String sessionId) {
    return _recoveredSessions.remove(sessionId);
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
  void setTaskToolFilter(List<String>? allowedTools) {
    _taskToolFilterGuard?.allowedTools = allowedTools;
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  Future<String> _buildSystemPrompt(String sessionId) async {
    if (_worker.promptStrategy == PromptStrategy.append) return '';

    // Use task-scoped behavior override when present (project-backed tasks).
    final effectiveBehavior = _activeTurns[sessionId]?.behaviorOverride ?? _behavior;
    final behaviorPrompt = await effectiveBehavior.composeSystemPrompt(sessionId: sessionId);

    final memFile = _memoryFile;
    if (memFile != null) {
      await memFile.readMemory();
      if (memFile.lastMemorySize > _memoryWarnBytes) {
        _log.warning(
          'MEMORY.md is ${memFile.lastMemorySize} bytes (>${_memoryWarnBytes ~/ 1024}KB) — consider pruning',
        );
      }
    }

    final agentsContent = await effectiveBehavior.composeAppendPrompt();
    if (agentsContent.isEmpty) return behaviorPrompt;
    return '$behaviorPrompt\n\n$agentsContent';
  }

  Future<void> _runTurn({
    required String sessionId,
    required String turnId,
    required List<Map<String, dynamic>> messages,
    String? source,
  }) async {
    return LogContext.runWith(
      () => _runTurnInner(sessionId: sessionId, turnId: turnId, messages: messages, source: source),
      sessionId: sessionId,
      turnId: turnId,
    );
  }

  Future<void> _runTurnInner({
    required String sessionId,
    required String turnId,
    required List<Map<String, dynamic>> messages,
    String? source,
  }) async {
    final buffer = StringBuffer();
    final stopwatch = Stopwatch()..start();
    var progressTextLength = 0;
    final progressMonitor = _stallTimeout > Duration.zero
        ? TurnProgressMonitor(
            stallTimeout: _stallTimeout,
            onStall: (stallTimeout) =>
                _handleTurnStall(sessionId: sessionId, turnId: turnId, stallTimeout: stallTimeout),
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
        unawaited(cancelTurn(sessionId));
      },
    );
    _turnProgressSnapshots[sessionId] = buildSnapshot;

    String? userMessageFull;
    if (messages.isNotEmpty) {
      final last = messages.last;
      if (last['role'] == 'user') {
        userMessageFull = last['content'] as String?;
      }
    }
    final userMessage = userMessageFull != null ? _truncate(userMessageFull, 100) : null;

    final eventSub = _worker.events.listen((event) {
      if (event is DeltaEvent) {
        buffer.write(event.text);
        progressMonitor?.recordProgress();
        _resetService?.touchActivity(sessionId);
        progressTextLength += event.text.length;
        _progressController.add(TextDeltaProgressEvent(snapshot: buildSnapshot(), text: event.text));
      } else if (event is ToolUseEvent) {
        toolHooks.handleToolUse(event);
      } else if (event is ToolResultEvent) {
        toolHooks.handleToolResult(event);
      } else if (event is SystemInitEvent) {
        _contextMonitor.update(contextWindow: event.contextWindow);
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
        statusTickTimer = _statusTickInterval > Duration.zero
            ? Timer.periodic(_statusTickInterval, (_) {
                _progressController.add(StatusTickProgressEvent(snapshot: buildSnapshot()));
              })
            : null;
        progressMonitor?.start();
        final result = await _worker.turn(
          sessionId: sessionId,
          messages: messages,
          systemPrompt: systemPrompt,
          directory: turnCtx?.directory,
          model: turnCtx?.model,
          effort: turnCtx?.effort,
          maxTurns: turnCtx?.maxTurns,
        );
        final accumulated = buffer.toString();
        toolHooks.finalizePendingToolCalls();
        stopwatch.stop();
        final cacheReadTokens = _worker.supportsCachedTokens ? (result['cache_read_tokens'] as int? ?? 0) : 0;
        final cacheWriteTokens = _worker.supportsCachedTokens ? (result['cache_write_tokens'] as int? ?? 0) : 0;

        try {
          await _trackSessionUsage(sessionId, result, providerId);
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

        if (_contextMonitor.shouldFlush) {
          try {
            await _runFlushTurn(sessionId);
          } catch (e) {
            _log.warning('Pre-compaction flush failed (lossy compaction possible)', e);
          }
        }
      } catch (e, st) {
        final wasCancelled = _cancelledTurns.remove(turnId);
        final loopDetection = _loopDetectedTurns.remove(turnId);
        _log.warning('Turn $turnId ${wasCancelled ? 'cancelled' : 'failed'}', e, st);
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
            content: loopMsg ?? (partial.isNotEmpty ? partial : (wasCancelled ? '[Turn cancelled]' : '[Turn failed]')),
          );
        } catch (e) {
          _log.warning('Failed to persist partial message after turn failure: $e');
        }
        outcome = TurnOutcome(
          turnId: turnId,
          sessionId: sessionId,
          status: wasCancelled ? TurnStatus.cancelled : TurnStatus.failed,
          errorMessage: wasCancelled ? null : 'Turn execution failed',
          completedAt: DateTime.now(),
          loopDetection: loopDetection,
        );
        unawaited(
          _selfImprovement?.appendError(
            errorType: wasCancelled ? 'TURN_CANCELLED' : 'TURN_FAILURE',
            sessionId: sessionId,
            context: '$e',
          ),
        );
      }
    } finally {
      statusTickTimer?.cancel();
      progressMonitor?.stop();
      await eventSub.cancel();
      _turnProgressSnapshots.remove(sessionId);
      _activeTurns.remove(sessionId);
      _lockManager.release(sessionId);
      // Clean up loop detection state for this turn.
      _governanceEnforcer.cleanupTurn(turnId);

      final turnState = _turnState;
      if (turnState != null) {
        unawaited(
          turnState.delete(sessionId).catchError((Object e, StackTrace st) {
            _log.warning('Failed to clean up turn state', e, st);
          }),
        );
      }
      final resolved =
          outcome ??
          TurnOutcome(
            turnId: turnId,
            sessionId: sessionId,
            status: TurnStatus.failed,
            errorMessage: 'Unexpected internal error',
            completedAt: DateTime.now(),
          );
      _recentOutcomes[turnId] = (outcome: resolved, expiresAt: DateTime.now().add(_outcomeTtl));
      _outcomePending.remove(turnId)?.complete(resolved);
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

    costData['input_tokens'] = ((costData['input_tokens'] as num?)?.toInt() ?? 0) + inputTokens;
    costData['output_tokens'] = ((costData['output_tokens'] as num?)?.toInt() ?? 0) + outputTokens;
    costData['cache_read_tokens'] = ((costData['cache_read_tokens'] as num?)?.toInt() ?? 0) + cacheReadTokens;
    costData['cache_write_tokens'] = ((costData['cache_write_tokens'] as num?)?.toInt() ?? 0) + cacheWriteTokens;
    costData['total_tokens'] = ((costData['total_tokens'] as num?)?.toInt() ?? 0) + inputTokens + outputTokens;
    costData['estimated_cost_usd'] = (costData['estimated_cost_usd'] as num).toDouble() + costUsd;
    costData['turn_count'] = ((costData['turn_count'] as num?)?.toInt() ?? 0) + 1;
    costData['provider'] = existingProvider ?? provider;

    await kv.set(key, jsonEncode(costData));
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
        final argStr = arg != null ? _truncate(arg.toString(), 50) : '';
        toolSummaries.add('${t.toolName}($argStr)');
      }
    }

    final resultSnippet = _truncate(result, 100);
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
    _contextMonitor.markFlushStarted();
    try {
      final systemPrompt = await _buildSystemPrompt(sessionId);
      final flushMessage = <String, dynamic>{'role': 'user', 'content': _flushPrompt};
      await _worker.turn(sessionId: sessionId, messages: [flushMessage], systemPrompt: systemPrompt);
      _log.info('Pre-compaction flush completed for session $sessionId');
    } finally {
      _contextMonitor.markFlushCompleted();
    }
  }

  static String _truncate(String s, int maxLen) => s.length <= maxLen ? s : '${s.substring(0, maxLen)}...';

  void _handleTurnStall({required String sessionId, required String turnId, required Duration stallTimeout}) {
    final payload = {
      'sessionId': sessionId,
      'turnId': turnId,
      'silentForSeconds': stallTimeout.inSeconds,
      'action': _stallAction.name,
    };

    // Emit progress event for stall — snapshot from per-turn progress state.
    final snapshotFn = _turnProgressSnapshots[sessionId];
    final snapshot = snapshotFn != null ? snapshotFn() : TurnProgressSnapshot(elapsed: Duration.zero, toolCallCount: 0);
    _progressController.add(
      TurnStallProgressEvent(snapshot: snapshot, stallTimeout: stallTimeout, action: _stallAction.name),
    );

    switch (_stallAction) {
      case TurnProgressAction.warn:
        _log.warning('Turn $turnId has stalled for ${stallTimeout.inSeconds}s');
        _sseBroadcast?.broadcast('turn_progress_stall', payload);
      case TurnProgressAction.cancel:
        _log.warning('Cancelling stalled turn $turnId after ${stallTimeout.inSeconds}s');
        _sseBroadcast?.broadcast('turn_progress_stall', payload);
        unawaited(cancelTurn(sessionId));
      case TurnProgressAction.ignore:
        _log.info('Ignoring stalled turn $turnId after ${stallTimeout.inSeconds}s');
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

  void _evictExpiredOutcomes() {
    final now = DateTime.now();
    _recentOutcomes.removeWhere((_, v) => v.expiresAt.isBefore(now));
  }
}
