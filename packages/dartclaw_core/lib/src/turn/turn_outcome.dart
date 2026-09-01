import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'tool_call_record.dart';
import 'turn_trace.dart' show computeEffectiveTokens;
import 'turn_status.dart';

/// Turn budget whose enforcement cancelled a provider turn.
enum TurnLimitBreach {
  /// The provider emitted no progress within the configured liveness budget.
  stall('stall'),

  /// The turn exceeded its configured wall-clock budget.
  turnTimeout('turn_timeout');

  /// Stable wire representation.
  final String jsonName;

  new(this.jsonName);

  /// Parses a serialized breach value.
  static TurnLimitBreach? fromJson(String value) {
    for (final breach in values) {
      if (breach.jsonName == value) return breach;
    }
    return null;
  }
}

/// Result of a completed turn including status and optional error.
class TurnOutcome {
  final String turnId;
  final String sessionId;
  final TurnStatus status;

  /// Failure detail, or the breached budget for a limit-attributed cancellation.
  final String? errorMessage;
  final String? responseText; // non-null when completed

  /// Budget breach that caused cancellation, if any.
  final TurnLimitBreach? limitBreach;

  /// Provider-enforced payload from a completed turn whose output passed guards.
  final Map<String, dynamic>? structuredOutput;

  /// Provider-native session identity reported for this turn.
  final String? providerSessionId;

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

  new({
    required this.turnId,
    required this.sessionId,
    required this.status,
    this.errorMessage,
    this.responseText,
    this.limitBreach,
    this.structuredOutput,
    this.providerSessionId,
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
