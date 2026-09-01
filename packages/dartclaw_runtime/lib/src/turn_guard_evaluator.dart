import 'dart:async';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

import 'behavior/self_improvement_service.dart';
import 'session/session_reset_service.dart';
import 'task/tool_call_summary.dart';
import 'turn_governance_enforcer.dart';

/// Evaluates guard-chain results for inbound and outbound turn content.
class TurnGuardEvaluator {
  static final _log = Logger('TurnGuardEvaluator');

  final GuardChain? _guardChain;
  final MessageService _messages;
  final SessionService? _sessions;
  final SelfImprovementService? _selfImprovement;

  new({
    required GuardChain? guardChain,
    required MessageService messages,
    required SessionService? sessions,
    required SelfImprovementService? selfImprovement,
  }) : _guardChain = guardChain,
       _messages = messages,
       _sessions = sessions,
       _selfImprovement = selfImprovement;

  /// Evaluates an inbound message before a turn starts.
  ///
  /// Returns a failed [TurnOutcome] if the message is blocked, otherwise null.
  Future<TurnOutcome?> evaluateMessageReceived({
    required String turnId,
    required String sessionId,
    required String? source,
    required String? userMessageFull,
  }) async {
    final chain = _guardChain;
    if (chain == null || userMessageFull == null || userMessageFull.isEmpty) return null;

    final verdict = await chain.evaluateMessageReceived(userMessageFull, source: source, sessionId: sessionId);
    if (!verdict.isBlock) return null;

    await _messages.insertMessage(
      sessionId: sessionId,
      role: 'assistant',
      content: '[Blocked by guard: ${verdict.message}]',
    );
    unawaited(
      _selfImprovement?.appendError(
        errorType: 'GUARD_BLOCK',
        sessionId: sessionId,
        context: verdict.message ?? 'unknown',
      ),
    );
    _log.warning('Inbound message blocked for session $sessionId');
    return TurnOutcome(
      turnId: turnId,
      sessionId: sessionId,
      status: TurnStatus.failed,
      errorMessage: 'Blocked by guard: ${verdict.message}',
      completedAt: DateTime.now(),
    );
  }

  /// Evaluates the accumulated assistant response before persistence.
  ///
  /// Returns a failed [TurnOutcome] if the response is blocked, otherwise null.
  Future<TurnOutcome?> evaluateBeforeAgentSend({
    required String turnId,
    required String sessionId,
    required String accumulated,
    List<ToolCallRecord> toolCalls = const [],
    int? toolCallCount,
    int? failedToolCallCount,
  }) async {
    final chain = _guardChain;
    if (chain == null || accumulated.isEmpty) return null;

    final verdict = await chain.evaluateBeforeAgentSend(accumulated, sessionId: sessionId);
    if (!verdict.isBlock) return null;

    await _messages.insertMessage(
      sessionId: sessionId,
      role: 'assistant',
      content: '[Response blocked by guard: ${verdict.message}]',
    );
    await _sessions?.touchUpdatedAt(sessionId);
    unawaited(
      _selfImprovement?.appendError(
        errorType: 'RESPONSE_BLOCKED',
        sessionId: sessionId,
        context: verdict.message ?? 'unknown',
      ),
    );
    _log.warning('Outbound response blocked for session $sessionId');
    return TurnOutcome(
      turnId: turnId,
      sessionId: sessionId,
      status: TurnStatus.failed,
      errorMessage: 'Response blocked by guard: ${verdict.message}',
      toolCalls: toolCalls,
      toolCallCount: toolCallCount,
      failedToolCallCount: failedToolCallCount,
      completedAt: DateTime.now(),
    );
  }
}

/// Tracks per-turn tool hook callbacks emitted by the harness event stream.
///
/// Centralizes the state transitions for tool-start/tool-result events so
/// [TurnRunner] only needs to forward the hook events and consume the
/// accumulated summaries.
class TurnToolHookCallbackHandler {
  /// Maximum raw tool events retained per turn: the first 63 plus the latest.
  static const maxRetainedToolEvents = 64;

  final String _sessionId;
  final String _turnId;
  final SessionResetService? _resetService;
  final void Function()? _recordProgress;
  final TurnGovernanceEnforcer _governanceEnforcer;
  final LoopAction? _loopAction;
  final TurnProgressSnapshot Function() _buildSnapshot;
  final void Function(TurnProgressEvent event) _emitProgressEvent;
  final void Function(LoopDetection detection)? _onLoopAbort;

  final List<ToolUseEvent> _toolEvents = [];
  final Map<String, ({String name, String? context, DateTime startedAt})> _pendingToolCalls = {};
  final List<ToolCallRecord> _completedToolCalls = [];
  int _toolCallCount = 0;
  int _failedToolCallCount = 0;
  int _unresolvedToolCallCount = 0;
  String? _lastToolName;
  ToolUseEvent? _lastToolEvent;

  new({
    required String sessionId,
    required String turnId,
    required TurnGovernanceEnforcer governanceEnforcer,
    required TurnProgressSnapshot Function() buildSnapshot,
    required void Function(TurnProgressEvent event) emitProgressEvent,
    SessionResetService? resetService,
    void Function()? recordProgress,
    LoopAction? loopAction,
    void Function(LoopDetection detection)? onLoopAbort,
  }) : _sessionId = sessionId,
       _turnId = turnId,
       _resetService = resetService,
       _recordProgress = recordProgress,
       _governanceEnforcer = governanceEnforcer,
       _loopAction = loopAction,
       _buildSnapshot = buildSnapshot,
       _emitProgressEvent = emitProgressEvent,
       _onLoopAbort = onLoopAbort;

  List<ToolUseEvent> get toolEvents => _toolEvents;

  List<ToolCallRecord> get completedToolCalls => _completedToolCalls;

  int get pendingToolCallCount => _pendingToolCalls.length;

  int get toolCallCount => _toolCallCount;

  int get failedToolCallCount => _failedToolCallCount;

  String? get lastToolName => _lastToolName;

  ToolUseEvent? get lastToolEvent => _lastToolEvent;

  void handleToolUse(ToolUseEvent event) {
    _lastToolEvent = event;
    if (_toolEvents.length < maxRetainedToolEvents) {
      _toolEvents.add(event);
    } else {
      _toolEvents[maxRetainedToolEvents - 1] = event;
    }
    _recordProgress?.call();
    _resetService?.touchActivity(_sessionId);
    if (!_pendingToolCalls.containsKey(event.toolId) && _pendingToolCalls.length >= maxRetainedToolEvents) {
      _pendingToolCalls.remove(_pendingToolCalls.keys.last);
    }
    _pendingToolCalls[event.toolId] = (
      name: event.toolName,
      context: summarizeToolInput(event.toolName, event.input),
      startedAt: DateTime.now(),
    );
    _toolCallCount += 1;
    _unresolvedToolCallCount += 1;
    _lastToolName = event.toolName;
    _emitProgressEvent(
      ToolStartedProgressEvent(snapshot: _buildSnapshot(), toolName: event.toolName, toolCallCount: _toolCallCount),
    );

    final detection = _governanceEnforcer.recordToolCall(_turnId, _sessionId, event.toolName, event.input);
    if (detection != null && _loopAction == LoopAction.abort) {
      _onLoopAbort?.call(detection);
    }
  }

  void handleToolResult(ToolResultEvent event) {
    _recordProgress?.call();
    _resetService?.touchActivity(_sessionId);
    if (_unresolvedToolCallCount > 0) {
      _unresolvedToolCallCount -= 1;
      if (event.isError) _failedToolCallCount += 1;
    }
    final pending = _pendingToolCalls.remove(event.toolId);
    if (pending == null) {
      return;
    }

    final durationMs = DateTime.now().difference(pending.startedAt).inMilliseconds;
    _retainCompletedToolCall(
      ToolCallRecord(
        name: pending.name,
        success: !event.isError,
        durationMs: durationMs,
        errorType: event.isError ? 'tool_error' : null,
        context: pending.context,
      ),
    );
    _emitProgressEvent(
      ToolCompletedProgressEvent(snapshot: _buildSnapshot(), toolName: pending.name, isError: event.isError),
    );
  }

  void finalizePendingToolCalls({DateTime? endedAt}) {
    final turnEndedAt = endedAt ?? DateTime.now();
    for (final entry in _pendingToolCalls.entries) {
      final durationMs = turnEndedAt.difference(entry.value.startedAt).inMilliseconds;
      _retainCompletedToolCall(
        ToolCallRecord(
          name: entry.value.name,
          success: false,
          durationMs: durationMs,
          errorType: 'incomplete',
          context: entry.value.context,
        ),
      );
    }
    _failedToolCallCount += _unresolvedToolCallCount;
    _unresolvedToolCallCount = 0;
    _pendingToolCalls.clear();
  }

  void _retainCompletedToolCall(ToolCallRecord record) {
    if (_completedToolCalls.length < maxRetainedToolEvents) {
      _completedToolCalls.add(record);
    } else {
      _completedToolCalls[maxRetainedToolEvents - 1] = record;
    }
  }
}
