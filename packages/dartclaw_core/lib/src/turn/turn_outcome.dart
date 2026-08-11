import 'package:dartclaw_config/dartclaw_config.dart' show LoopDetection;

import 'tool_call_record.dart';
import 'turn_trace.dart' show computeEffectiveTokens;
import 'turn_status.dart';

/// Result of a completed turn including status and optional error.
class TurnOutcome {
  final String turnId;
  final String sessionId;
  final TurnStatus status;
  final String? errorMessage; // non-null when failed
  final String? responseText; // non-null when completed
  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;
  final Duration turnDuration;
  final List<ToolCallRecord> toolCalls;
  final int toolCallCount;
  final int failedToolCallCount;
  final DateTime completedAt;

  /// Non-null when the turn was cancelled due to mid-turn loop detection.
  final LoopDetection? loopDetection;

  int get totalTokens => inputTokens + outputTokens;

  /// Billing-weighted token count – see [computeEffectiveTokens].
  int get effectiveTokens => computeEffectiveTokens(
    inputTokens: inputTokens,
    outputTokens: outputTokens,
    cacheReadTokens: cacheReadTokens,
    cacheWriteTokens: cacheWriteTokens,
  );

  /// Whether [toolCalls] omits invocation details retained only in the counters.
  bool get toolCallsTruncated => toolCalls.length < toolCallCount;

  TurnOutcome({
    required this.turnId,
    required this.sessionId,
    required this.status,
    this.errorMessage,
    this.responseText,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
    this.turnDuration = Duration.zero,
    List<ToolCallRecord> toolCalls = const [],
    int? toolCallCount,
    int? failedToolCallCount,
    required this.completedAt,
    this.loopDetection,
  }) : toolCalls = toolCalls,
       toolCallCount = toolCallCount ?? toolCalls.length,
       failedToolCallCount = failedToolCallCount ?? toolCalls.where((call) => !call.success).length;
}
