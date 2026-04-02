import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

import 'behavior/self_improvement_service.dart';
import 'session/session_reset_service.dart';
import 'task/tool_call_summary.dart';
import 'turn_governance_enforcer.dart';
import 'turn_manager.dart';
import 'turn_progress_monitor.dart';

/// Evaluates guard-chain results for inbound and outbound turn content.
class TurnGuardEvaluator {
  static final _log = Logger('TurnGuardEvaluator');

  final GuardChain? _guardChain;
  final MessageService _messages;
  final SessionService? _sessions;
  final SelfImprovementService? _selfImprovement;

  TurnGuardEvaluator({
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
  final String _sessionId;
  final String _turnId;
  final SessionResetService? _resetService;
  final TurnProgressMonitor? _progressMonitor;
  final TurnGovernanceEnforcer _governanceEnforcer;
  final LoopAction? _loopAction;
  final TurnProgressSnapshot Function() _buildSnapshot;
  final void Function(TurnProgressEvent event) _emitProgressEvent;
  final void Function(LoopDetection detection)? _onLoopAbort;

  final List<ToolUseEvent> _toolEvents = [];
  final Map<String, ({String name, String? context, DateTime startedAt})> _pendingToolCalls = {};
  final List<ToolCallRecord> _completedToolCalls = [];
  int _toolCallCount = 0;
  String? _lastToolName;

  TurnToolHookCallbackHandler({
    required String sessionId,
    required String turnId,
    required TurnGovernanceEnforcer governanceEnforcer,
    required TurnProgressSnapshot Function() buildSnapshot,
    required void Function(TurnProgressEvent event) emitProgressEvent,
    SessionResetService? resetService,
    TurnProgressMonitor? progressMonitor,
    LoopAction? loopAction,
    void Function(LoopDetection detection)? onLoopAbort,
  }) : _sessionId = sessionId,
       _turnId = turnId,
       _resetService = resetService,
       _progressMonitor = progressMonitor,
       _governanceEnforcer = governanceEnforcer,
       _loopAction = loopAction,
       _buildSnapshot = buildSnapshot,
       _emitProgressEvent = emitProgressEvent,
       _onLoopAbort = onLoopAbort;

  List<ToolUseEvent> get toolEvents => _toolEvents;

  List<ToolCallRecord> get completedToolCalls => _completedToolCalls;

  int get toolCallCount => _toolCallCount;

  String? get lastToolName => _lastToolName;

  void handleToolUse(ToolUseEvent event) {
    _toolEvents.add(event);
    _progressMonitor?.recordProgress();
    _resetService?.touchActivity(_sessionId);
    _pendingToolCalls[event.toolId] = (
      name: event.toolName,
      context: summarizeToolInput(event.toolName, event.input),
      startedAt: DateTime.now(),
    );
    _toolCallCount += 1;
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
    _progressMonitor?.recordProgress();
    _resetService?.touchActivity(_sessionId);
    final pending = _pendingToolCalls.remove(event.toolId);
    if (pending == null) {
      return;
    }

    final durationMs = DateTime.now().difference(pending.startedAt).inMilliseconds;
    _completedToolCalls.add(
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
      _completedToolCalls.add(
        ToolCallRecord(
          name: entry.value.name,
          success: false,
          durationMs: durationMs,
          errorType: 'incomplete',
          context: entry.value.context,
        ),
      );
    }
    _pendingToolCalls.clear();
  }
}
