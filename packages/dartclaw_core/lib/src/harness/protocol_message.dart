/// Provider-agnostic protocol message returned by a [ProtocolAdapter].
sealed class ProtocolMessage {
  const ProtocolMessage();
}

/// Streaming text delta from the agent.
final class TextDelta extends ProtocolMessage {
  final String text;

  const TextDelta(this.text);

  @override
  String toString() => 'TextDelta(text: ${text.length > 80 ? '${text.substring(0, 80)}...' : text})';
}

/// Tool invocation by the agent.
final class ToolUse extends ProtocolMessage {
  final String name;
  final String id;
  final Map<String, dynamic> input;

  const ToolUse({required this.name, required this.id, required this.input});

  @override
  String toString() => 'ToolUse(name: $name, id: $id)';
}

/// Tool execution result.
final class ToolResult extends ProtocolMessage {
  final String toolId;
  final String output;
  final bool isError;

  const ToolResult({required this.toolId, required this.output, this.isError = false});

  @override
  String toString() => 'ToolResult(toolId: $toolId, isError: $isError)';
}

/// Control request from the provider.
final class ControlRequest extends ProtocolMessage {
  final String requestId;
  final String subtype;
  final Map<String, dynamic> data;

  const ControlRequest({required this.requestId, required this.subtype, required this.data});

  @override
  String toString() => 'ControlRequest(requestId: $requestId, subtype: $subtype)';
}

/// Turn completion with result metadata.
final class TurnComplete extends ProtocolMessage {
  final String? stopReason;
  final double? costUsd;
  final int? durationMs;
  final int? inputTokens;
  final int? outputTokens;
  final int? cachedInputTokens;

  const TurnComplete({
    this.stopReason,
    this.costUsd,
    this.durationMs,
    this.inputTokens,
    this.outputTokens,
    this.cachedInputTokens,
  });

  @override
  String toString() =>
      'TurnComplete(stopReason: $stopReason, costUsd: $costUsd, durationMs: $durationMs, '
      'inputTokens: $inputTokens, outputTokens: $outputTokens, cachedInputTokens: $cachedInputTokens)';
}

/// System/session initialization metadata.
final class SystemInit extends ProtocolMessage {
  final String? sessionId;
  final int toolCount;
  final int? contextWindow;

  const SystemInit({this.sessionId, required this.toolCount, this.contextWindow});

  @override
  String toString() => 'SystemInit(sessionId: $sessionId, toolCount: $toolCount, contextWindow: $contextWindow)';
}
