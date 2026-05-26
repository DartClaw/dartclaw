import 'tool_call_record.dart';
import 'turn_trace.dart' show computeEffectiveTokens;

import 'package:dartclaw_config/dartclaw_config.dart' show LoopDetection;
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
  final DateTime completedAt;

  /// Non-null when the turn was cancelled due to mid-turn loop detection.
  ///
  /// [TaskExecutor] checks this field to distinguish loop-caused cancellation
  /// from user-initiated cancellation, and transitions the task to `failed`.
  final LoopDetection? loopDetection;

  int get totalTokens => inputTokens + outputTokens;

  /// Billing-weighted token count — see [computeEffectiveTokens]. Prefer this
  /// over [totalTokens] when comparing runs across harnesses.
  int get effectiveTokens => computeEffectiveTokens(
    inputTokens: inputTokens,
    outputTokens: outputTokens,
    cacheReadTokens: cacheReadTokens,
    cacheWriteTokens: cacheWriteTokens,
  );

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
    this.toolCalls = const [],
    required this.completedAt,
    this.loopDetection,
  });
}
