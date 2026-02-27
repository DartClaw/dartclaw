import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import 'concurrency/session_lock_manager.dart';
import 'context/context_monitor.dart';
import 'context/result_trimmer.dart';
import 'logging/log_context.dart';
import 'session/session_reset_service.dart';

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

enum TurnStatus { completed, failed, cancelled }

class TurnContext {
  final String turnId;
  final String sessionId;
  final DateTime startedAt;

  TurnContext({required this.turnId, required this.sessionId, required this.startedAt});
}

class TurnOutcome {
  final String turnId;
  final String sessionId;
  final TurnStatus status;
  final String? errorMessage; // non-null when failed
  final DateTime completedAt;

  TurnOutcome({
    required this.turnId,
    required this.sessionId,
    required this.status,
    this.errorMessage,
    required this.completedAt,
  });
}

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

class TurnManager {
  static final _log = Logger('TurnManager');
  static const _uuid = Uuid();
  static const _memoryWarnBytes = 50 * 1024;

  final MessageService _messages;
  final AgentHarness _worker;
  final BehaviorFileService _behavior;
  final MemoryFileService? _memoryFile;
  final SessionService? _sessions;
  final KvService? _kv;
  final GuardChain? _guardChain;
  final SessionLockManager _lockManager;
  final SessionResetService? _resetService;
  final ContextMonitor _contextMonitor;
  final ResultTrimmer _resultTrimmer;
  final Duration _outcomeTtl;

  final Map<String, TurnContext> _activeTurns = {};
  final Set<String> _cancelledTurns = {};
  final Map<String, ({TurnOutcome outcome, DateTime expiresAt})> _recentOutcomes = {};
  final Map<String, Completer<TurnOutcome>> _outcomePending = {};

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
    Duration outcomeTtl = const Duration(seconds: 30),
  }) : _messages = messages,
       _worker = worker,
       _behavior = behavior,
       _memoryFile = memoryFile,
       _sessions = sessions,
       _kv = kv,
       _guardChain = guardChain,
       _lockManager = lockManager ?? SessionLockManager(),
       _resetService = resetService,
       _contextMonitor = contextMonitor ?? ContextMonitor(),
       _resultTrimmer = resultTrimmer ?? const ResultTrimmer(),
       _outcomeTtl = outcomeTtl;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

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

  /// Atomically checks busy state and reserves a new turn slot.
  /// Returns the new [turnId]. Throws [BusyTurnException] if busy.
  /// Call [executeTurn] to start async execution, or [releaseTurn] to roll back.
  String reserveTurn(String sessionId) {
    _lockManager.acquire(sessionId); // throws BusyTurnException on conflict
    final turnId = _uuid.v4();
    _activeTurns[sessionId] = TurnContext(turnId: turnId, sessionId: sessionId, startedAt: DateTime.now());
    _outcomePending[turnId] = Completer<TurnOutcome>();
    _resetService?.touchActivity(sessionId);
    return turnId;
  }

  /// Launches async execution for a previously [reserveTurn]'d turn.
  void executeTurn(String sessionId, String turnId, List<Map<String, dynamic>> messages) {
    unawaited(_runTurn(sessionId: sessionId, turnId: turnId, messages: messages));
  }

  /// Rolls back a [reserveTurn] reservation without executing.
  void releaseTurn(String sessionId, String turnId) {
    _activeTurns.remove(sessionId);
    _lockManager.release(sessionId);
    _outcomePending.remove(turnId)?.completeError(StateError('Turn released without execution'));
  }

  Future<String> startTurn(String sessionId, List<Map<String, dynamic>> messages) async {
    final turnId = reserveTurn(sessionId);
    executeTurn(sessionId, turnId, messages);
    return turnId;
  }

  Future<void> cancelTurn(String sessionId) async {
    final turnId = _activeTurns[sessionId]?.turnId;
    if (turnId == null) return;
    _cancelledTurns.add(turnId);
    await _worker.cancel();
  }

  /// Waits for the active turn on [sessionId] to complete.
  /// Returns immediately if no active turn exists.
  /// Throws [TimeoutException] if the turn doesn't complete within [timeout].
  Future<void> waitForCompletion(String sessionId, {Duration timeout = const Duration(seconds: 10)}) async {
    final turnId = _activeTurns[sessionId]?.turnId;
    if (turnId == null) return; // No active turn

    final pending = _outcomePending[turnId];
    if (pending == null) return; // Already completed

    await pending.future.timeout(timeout);
  }

  Future<TurnOutcome> waitForOutcome(String sessionId, String turnId) async {
    final cached = recentOutcome(sessionId, turnId);
    if (cached != null) return cached;

    final pending = _outcomePending[turnId];
    if (pending != null) return pending.future;

    throw ArgumentError('Unknown turnId: $turnId');
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  Future<String> _buildSystemPrompt() async {
    final behaviorPrompt = await _behavior.composeSystemPrompt();

    // Check MEMORY.md size for warning (read by BehaviorFileService, use MemoryFileService for size tracking)
    final memFile = _memoryFile;
    if (memFile != null) {
      await memFile.readMemory(); // updates lastMemorySize
      if (memFile.lastMemorySize > _memoryWarnBytes) {
        _log.warning(
          'MEMORY.md is ${memFile.lastMemorySize} bytes (>${_memoryWarnBytes ~/ 1024}KB) — consider pruning',
        );
      }
    }

    // AGENTS.md appended after behavior files (harder to override via prompt injection)
    final agentsContent = await _behavior.composeAppendPrompt();
    if (agentsContent.isEmpty) return behaviorPrompt;
    return '$behaviorPrompt\n\n$agentsContent';
  }

  Future<void> _runTurn({
    required String sessionId,
    required String turnId,
    required List<Map<String, dynamic>> messages,
  }) async {
    return LogContext.runWith(() => _runTurnInner(
      sessionId: sessionId,
      turnId: turnId,
      messages: messages,
    ), sessionId: sessionId, turnId: turnId);
  }

  Future<void> _runTurnInner({
    required String sessionId,
    required String turnId,
    required List<Map<String, dynamic>> messages,
  }) async {
    // Subscribe BEFORE calling turn() — events stream is broadcast (non-replay).
    final buffer = StringBuffer();
    final toolEvents = <ToolUseEvent>[];
    String? userMessageFull;
    if (messages.isNotEmpty) {
      final last = messages.last;
      if (last['role'] == 'user') {
        userMessageFull = last['content'] as String?;
      }
    }
    // Truncated version for logging only — guards receive full content
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
        // Guard: messageReceived — evaluate full content before sending to agent
        final chain = _guardChain;
        if (chain != null && userMessageFull != null && userMessageFull.isNotEmpty) {
          final msgVerdict = await chain.evaluateMessageReceived(userMessageFull);
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
            return;
          }
        }

        final systemPrompt = await _buildSystemPrompt();
        final result = await _worker.turn(sessionId: sessionId, messages: messages, systemPrompt: systemPrompt);
        final accumulated = buffer.toString();

        // Track per-session token costs + update context monitor
        try {
          await _trackCost(sessionId, result);
          _contextMonitor.update(
            contextTokens: result['input_tokens'] as int?,
          );
        } catch (e) {
          _log.warning('Failed to track cost', e);
        }

        // Guard: beforeAgentSend — evaluate before persisting response
        if (chain != null && accumulated.isNotEmpty) {
          final sendVerdict = await chain.evaluateBeforeAgentSend(accumulated);
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
            return;
          }
        }

        final trimmed = _resultTrimmer.trim(accumulated);
        await _messages.insertMessage(sessionId: sessionId, role: 'assistant', content: trimmed);
        await _sessions?.touchUpdatedAt(sessionId);
        outcome = TurnOutcome(
          turnId: turnId,
          sessionId: sessionId,
          status: TurnStatus.completed,
          completedAt: DateTime.now(),
        );

        // Daily log (fire-and-forget, errors must not fail the turn)
        try {
          await _appendDailyLog(
            sessionId: sessionId,
            userMessage: userMessage,
            toolEvents: toolEvents,
            result: accumulated,
          );
        } catch (e) {
          _log.warning('Failed to write daily log', e);
        }

        // Pre-compaction flush check (fire-and-forget)
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
          final partial = buffer.toString();
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
      }
    } finally {
      await eventSub.cancel();
      _activeTurns.remove(sessionId);
      _lockManager.release(sessionId);
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

    // Get session title if available
    var title = 'Chat';
    final sessions = _sessions;
    if (sessions != null) {
      try {
        final session = await sessions.getSession(sessionId);
        final t = session?.title;
        if (t != null && t.isNotEmpty) title = t;
      } catch (_) {}
    }

    // Dedupe tool names and format: toolName(firstArg)
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

  static const _flushPrompt = 'You are approaching your context limit. Before context compression '
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
      final flushMessage = <String, dynamic>{
        'role': 'user',
        'content': _flushPrompt,
      };
      await _worker.turn(
        sessionId: sessionId,
        messages: [flushMessage],
        systemPrompt: systemPrompt,
      );
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
