import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import 'behavior/behavior_file_service.dart';
import 'behavior/self_improvement_service.dart';
import 'concurrency/session_lock_manager.dart';
import 'context/context_monitor.dart';
import 'context/result_trimmer.dart';
import 'logging/log_context.dart';
import 'observability/usage_tracker.dart';
import 'session/session_reset_service.dart';
import 'turn_manager.dart';

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
  final GuardChain? _guardChain;
  final SessionLockManager _lockManager;
  final SessionResetService? _resetService;
  final ContextMonitor _contextMonitor;
  final ResultTrimmer _resultTrimmer;
  final MessageRedactor? _redactor;
  final SelfImprovementService? _selfImprovement;
  final UsageTracker? _usageTracker;
  final Duration _outcomeTtl;

  /// Security profile this runner's harness executes in (e.g. 'workspace', 'restricted').
  final String profileId;

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
    SessionLockManager? lockManager,
    SessionResetService? resetService,
    ContextMonitor? contextMonitor,
    ResultTrimmer? resultTrimmer,
    MessageRedactor? redactor,
    SelfImprovementService? selfImprovement,
    UsageTracker? usageTracker,
    Duration outcomeTtl = const Duration(seconds: 30),
    this.profileId = 'workspace',
  }) : _worker = harness,
       _messages = messages,
       _behavior = behavior,
       _memoryFile = memoryFile,
       _sessions = sessions,
       _turnState = turnState,
       _kv = kv,
       _guardChain = guardChain,
       _lockManager = lockManager ?? SessionLockManager(),
       _resetService = resetService,
       _contextMonitor = contextMonitor ?? ContextMonitor(),
       _resultTrimmer = resultTrimmer ?? const ResultTrimmer(),
       _redactor = redactor,
       _selfImprovement = selfImprovement,
       _usageTracker = usageTracker,
       _outcomeTtl = outcomeTtl;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// The underlying harness managed by this runner.
  AgentHarness get harness => _worker;

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
  Future<String> reserveTurn(String sessionId, {String agentName = 'main', String? directory, String? model, String? effort}) async {
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
  }) async {
    final turnId = await reserveTurn(sessionId, agentName: agentName, model: model, effort: effort);
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

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  Future<String> _buildSystemPrompt() async {
    if (_worker.promptStrategy == PromptStrategy.append) return '';

    final behaviorPrompt = await _behavior.composeSystemPrompt();

    final memFile = _memoryFile;
    if (memFile != null) {
      await memFile.readMemory();
      if (memFile.lastMemorySize > _memoryWarnBytes) {
        _log.warning(
          'MEMORY.md is ${memFile.lastMemorySize} bytes (>${_memoryWarnBytes ~/ 1024}KB) — consider pruning',
        );
      }
    }

    final agentsContent = await _behavior.composeAppendPrompt();
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
    final toolEvents = <ToolUseEvent>[];
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
      } else if (event is ToolUseEvent) {
        toolEvents.add(event);
      } else if (event is SystemInitEvent) {
        _contextMonitor.update(contextWindow: event.contextWindow);
      }
    });

    TurnOutcome? outcome;
    try {
      try {
        final chain = _guardChain;
        if (chain != null && userMessageFull != null && userMessageFull.isNotEmpty) {
          final msgVerdict = await chain.evaluateMessageReceived(userMessageFull, source: source, sessionId: sessionId);
          if (msgVerdict.isBlock) {
            await _messages.insertMessage(
              sessionId: sessionId,
              role: 'assistant',
              content: '[Blocked by guard: ${msgVerdict.message}]',
            );
            outcome = TurnOutcome(
              turnId: turnId,
              sessionId: sessionId,
              status: TurnStatus.failed,
              errorMessage: 'Blocked by guard: ${msgVerdict.message}',
              completedAt: DateTime.now(),
            );
            unawaited(
              _selfImprovement?.appendError(
                errorType: 'GUARD_BLOCK',
                sessionId: sessionId,
                context: msgVerdict.message ?? 'unknown',
              ),
            );
            return;
          }
        }

        final systemPrompt = await _buildSystemPrompt();
        final turnCtx = _activeTurns[sessionId];
        final result = await _worker.turn(
          sessionId: sessionId,
          messages: messages,
          systemPrompt: systemPrompt,
          directory: turnCtx?.directory,
          model: turnCtx?.model,
          effort: turnCtx?.effort,
        );
        final accumulated = buffer.toString();

        try {
          await _trackCost(sessionId, result);
          _contextMonitor.update(contextTokens: result['input_tokens'] as int?);
        } catch (e) {
          _log.warning('Failed to track cost', e);
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
                .catchError((_) {}),
          );
        }

        if (chain != null && accumulated.isNotEmpty) {
          final sendVerdict = await chain.evaluateBeforeAgentSend(accumulated, sessionId: sessionId);
          if (sendVerdict.isBlock) {
            await _messages.insertMessage(
              sessionId: sessionId,
              role: 'assistant',
              content: '[Response blocked by guard: ${sendVerdict.message}]',
            );
            await _sessions?.touchUpdatedAt(sessionId);
            outcome = TurnOutcome(
              turnId: turnId,
              sessionId: sessionId,
              status: TurnStatus.failed,
              errorMessage: 'Response blocked by guard: ${sendVerdict.message}',
              completedAt: DateTime.now(),
            );
            unawaited(
              _selfImprovement?.appendError(
                errorType: 'RESPONSE_BLOCKED',
                sessionId: sessionId,
                context: sendVerdict.message ?? 'unknown',
              ),
            );
            return;
          }
        }

        final redacted = _redactor?.redact(accumulated) ?? accumulated;
        final trimmed = _resultTrimmer.trim(redacted);
        await _messages.insertMessage(sessionId: sessionId, role: 'assistant', content: trimmed);
        await _sessions?.touchUpdatedAt(sessionId);
        outcome = TurnOutcome(
          turnId: turnId,
          sessionId: sessionId,
          status: TurnStatus.completed,
          responseText: trimmed,
          inputTokens: result['input_tokens'] as int? ?? 0,
          outputTokens: result['output_tokens'] as int? ?? 0,
          completedAt: DateTime.now(),
        );

        try {
          await _appendDailyLog(
            sessionId: sessionId,
            userMessage: userMessage,
            toolEvents: toolEvents,
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
        _log.warning('Turn $turnId ${wasCancelled ? 'cancelled' : 'failed'}', e, st);
        try {
          var partial = buffer.toString();
          if (partial.isNotEmpty && _redactor != null) {
            partial = _redactor.redact(partial);
          }
          await _messages.insertMessage(
            sessionId: sessionId,
            role: 'assistant',
            content: partial.isNotEmpty ? partial : (wasCancelled ? '[Turn cancelled]' : '[Turn failed]'),
          );
        } catch (_) {}
        outcome = TurnOutcome(
          turnId: turnId,
          sessionId: sessionId,
          status: wasCancelled ? TurnStatus.cancelled : TurnStatus.failed,
          errorMessage: wasCancelled ? null : 'Turn execution failed',
          completedAt: DateTime.now(),
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
      await eventSub.cancel();
      _activeTurns.remove(sessionId);
      _lockManager.release(sessionId);

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

  Future<void> _trackCost(String sessionId, Map<String, dynamic> result) async {
    final kv = _kv;
    if (kv == null) return;

    final key = 'session_cost:$sessionId';
    final existing = await kv.get(key);
    Map<String, dynamic> costData;
    if (existing != null) {
      costData = jsonDecode(existing) as Map<String, dynamic>;
    } else {
      costData = {'input_tokens': 0, 'output_tokens': 0, 'total_tokens': 0, 'estimated_cost_usd': 0.0, 'turn_count': 0};
    }

    final inputTokens = result['input_tokens'] as int? ?? 0;
    final outputTokens = result['output_tokens'] as int? ?? 0;
    final costUsd = (result['total_cost_usd'] as num?)?.toDouble() ?? 0.0;

    costData['input_tokens'] = (costData['input_tokens'] as int) + inputTokens;
    costData['output_tokens'] = (costData['output_tokens'] as int) + outputTokens;
    costData['total_tokens'] = (costData['total_tokens'] as int) + inputTokens + outputTokens;
    costData['estimated_cost_usd'] = (costData['estimated_cost_usd'] as num).toDouble() + costUsd;
    costData['turn_count'] = (costData['turn_count'] as int) + 1;

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
      } catch (_) {}
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
      final systemPrompt = await _buildSystemPrompt();
      final flushMessage = <String, dynamic>{'role': 'user', 'content': _flushPrompt};
      await _worker.turn(sessionId: sessionId, messages: [flushMessage], systemPrompt: systemPrompt);
      _log.info('Pre-compaction flush completed for session $sessionId');
    } finally {
      _contextMonitor.markFlushCompleted();
    }
  }

  static String _truncate(String s, int maxLen) => s.length <= maxLen ? s : '${s.substring(0, maxLen)}...';

  void _evictExpiredOutcomes() {
    final now = DateTime.now();
    _recentOutcomes.removeWhere((_, v) => v.expiresAt.isBefore(now));
  }
}
