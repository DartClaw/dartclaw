import 'package:collection/collection.dart' show MapEquality;

/// Base type for events received from the claude binary over the JSONL bridge.
sealed class BridgeEvent {}

/// Incremental text output from the agent.
final class DeltaEvent extends BridgeEvent {
  /// Newly emitted text delta from the agent runtime.
  final String text;

  /// Creates a text delta event.
  DeltaEvent(this.text);

  @override
  bool operator ==(Object other) => identical(this, other) || other is DeltaEvent && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'DeltaEvent(text: $text)';
}

/// Agent requested a tool invocation.
final class ToolUseEvent extends BridgeEvent {
  /// Tool name requested by the agent.
  final String toolName;

  /// Stable tool invocation identifier assigned by the runtime.
  final String toolId;

  /// JSON input payload supplied to the tool.
  final Map<String, dynamic> input;

  /// Creates a tool-use event.
  ToolUseEvent({required this.toolName, required this.toolId, required this.input});

  static const _mapEq = MapEquality<String, dynamic>();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ToolUseEvent &&
          other.toolName == toolName &&
          other.toolId == toolId &&
          _mapEq.equals(other.input, input);

  @override
  int get hashCode => Object.hash(toolName, toolId, _mapEq.hash(input));

  @override
  String toString() => 'ToolUseEvent(toolName: $toolName, toolId: $toolId, input: $input)';
}

/// Result returned from a tool invocation.
final class ToolResultEvent extends BridgeEvent {
  /// Tool invocation identifier this result corresponds to.
  final String toolId;

  /// Serialized tool output returned to the agent.
  final String output;

  /// Whether the tool result represents an error.
  final bool isError;

  /// Creates a tool-result event.
  ToolResultEvent({required this.toolId, required this.output, required this.isError});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ToolResultEvent && other.toolId == toolId && other.output == output && other.isError == isError;

  @override
  int get hashCode => Object.hash(toolId, output, isError);

  @override
  String toString() => 'ToolResultEvent(toolId: $toolId, output: $output, isError: $isError)';
}

/// Provider requested host-side approval before continuing a turn.
final class ToolApprovalWaitEvent extends BridgeEvent {
  /// Provider-specific approval request identifier.
  final String requestId;

  /// Tool name requiring approval.
  final String toolName;

  /// Creates a tool-approval wait event.
  ToolApprovalWaitEvent({required this.requestId, required this.toolName});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ToolApprovalWaitEvent && other.requestId == requestId && other.toolName == toolName;

  @override
  int get hashCode => Object.hash(requestId, toolName);

  @override
  String toString() => 'ToolApprovalWaitEvent(requestId: $requestId, toolName: $toolName)';
}

/// Provider approval request has been answered by the host.
final class ToolApprovalResolvedEvent extends BridgeEvent {
  /// Provider-specific approval request identifier.
  final String requestId;

  /// Creates a tool-approval resolved event.
  ToolApprovalResolvedEvent({required this.requestId});

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ToolApprovalResolvedEvent && other.requestId == requestId;

  @override
  int get hashCode => requestId.hashCode;

  @override
  String toString() => 'ToolApprovalResolvedEvent(requestId: $requestId)';
}

/// Non-response progress emitted by an agent provider.
final class ProviderProgressBridgeEvent extends BridgeEvent {
  /// Provider-specific progress kind.
  final String kind;

  /// Human-readable progress text.
  final String text;

  /// Creates a provider progress event.
  ProviderProgressBridgeEvent({required this.kind, required this.text});

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ProviderProgressBridgeEvent && other.kind == kind && other.text == text;

  @override
  int get hashCode => Object.hash(kind, text);

  @override
  String toString() => 'ProviderProgressBridgeEvent(kind: $kind, text: $text)';
}

/// Initialization metadata from the agent subprocess.
final class SystemInitEvent extends BridgeEvent {
  /// Maximum context window reported by the runtime.
  final int contextWindow;

  /// Creates an initialization event from the runtime handshake.
  SystemInitEvent({required this.contextWindow});

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is SystemInitEvent && other.contextWindow == contextWindow;

  @override
  int get hashCode => contextWindow.hashCode;

  @override
  String toString() => 'SystemInitEvent(contextWindow: $contextWindow)';
}

/// Codex context compaction has started (item/started with contextCompaction type).
/// Note: Codex compaction items carry no token count or summary — unlike Claude Code's compact_boundary.
final class CompactionStartingBridgeEvent extends BridgeEvent {
  @override
  bool operator ==(Object other) => identical(this, other) || other is CompactionStartingBridgeEvent;

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() => 'CompactionStartingBridgeEvent()';
}

/// Codex context compaction has completed (item/completed with contextCompaction type).
/// Note: Codex compaction items carry no token count or summary — unlike Claude Code's compact_boundary.
final class CompactionCompletedBridgeEvent extends BridgeEvent {
  @override
  bool operator ==(Object other) => identical(this, other) || other is CompactionCompletedBridgeEvent;

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() => 'CompactionCompletedBridgeEvent()';
}
