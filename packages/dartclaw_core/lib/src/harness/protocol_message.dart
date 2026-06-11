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

/// Non-response progress or thought text from the provider.
final class ProgressMessage extends ProtocolMessage {
  final String text;
  final String kind;

  const ProgressMessage({required this.text, required this.kind});

  @override
  String toString() => 'ProgressMessage(kind: $kind, text: ${text.length > 80 ? '${text.substring(0, 80)}...' : text})';
}

/// Session metadata update from the provider.
final class SessionMetadataUpdate extends ProtocolMessage {
  final String? title;
  final Map<String, dynamic> metadata;

  const SessionMetadataUpdate({this.title, this.metadata = const <String, dynamic>{}});

  @override
  String toString() => 'SessionMetadataUpdate(title: $title, metadata: $metadata)';
}

/// Diagnostic for skipped or malformed provider protocol input.
final class ProtocolDiagnostic extends ProtocolMessage {
  final String message;
  final String? method;
  final String? updateType;

  const ProtocolDiagnostic({required this.message, this.method, this.updateType});

  @override
  String toString() => 'ProtocolDiagnostic(method: $method, updateType: $updateType, message: $message)';
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
  final int? cacheReadTokens;
  final int? cacheWriteTokens;

  const TurnComplete({
    this.stopReason,
    this.costUsd,
    this.durationMs,
    this.inputTokens,
    this.outputTokens,
    this.cacheReadTokens,
    this.cacheWriteTokens,
  });

  @override
  String toString() =>
      'TurnComplete(stopReason: $stopReason, costUsd: $costUsd, durationMs: $durationMs, '
      'inputTokens: $inputTokens, outputTokens: $outputTokens, '
      'cacheReadTokens: $cacheReadTokens, cacheWriteTokens: $cacheWriteTokens)';
}

/// Context compaction completed signal from the provider.
final class CompactBoundary extends ProtocolMessage {
  /// Trigger source: `"auto"` or `"manual"`.
  final String trigger;

  /// Token count before compaction. May be null if omitted by the provider.
  final int? preTokens;

  const CompactBoundary({required this.trigger, this.preTokens});

  @override
  String toString() => 'CompactBoundary(trigger: $trigger, preTokens: $preTokens)';
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

/// Codex context compaction starting (item/started with contextCompaction type).
final class CompactionStarted extends ProtocolMessage {
  /// Optional item id from the Codex protocol item.
  final String? id;

  const CompactionStarted({this.id});

  @override
  String toString() => 'CompactionStarted(id: $id)';
}

/// Codex context compaction completed (item/completed with contextCompaction type).
final class CompactionCompleted extends ProtocolMessage {
  /// Optional item id from the Codex protocol item.
  final String? id;

  const CompactionCompleted({this.id});

  @override
  String toString() => 'CompactionCompleted(id: $id)';
}
