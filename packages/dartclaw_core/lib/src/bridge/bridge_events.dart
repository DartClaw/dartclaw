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
