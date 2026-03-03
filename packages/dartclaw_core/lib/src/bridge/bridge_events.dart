import 'package:collection/collection.dart' show MapEquality;

/// Base type for events received from the claude binary over the JSONL bridge.
sealed class BridgeEvent {}

final class DeltaEvent extends BridgeEvent {
  final String text;

  DeltaEvent(this.text);

  @override
  bool operator ==(Object other) => identical(this, other) || other is DeltaEvent && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'DeltaEvent(text: $text)';
}

final class ToolUseEvent extends BridgeEvent {
  final String toolName;
  final String toolId;
  final Map<String, dynamic> input;

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

final class ToolResultEvent extends BridgeEvent {
  final String toolId;
  final String output;
  final bool isError;

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

final class SystemInitEvent extends BridgeEvent {
  final int contextWindow;

  SystemInitEvent({required this.contextWindow});

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is SystemInitEvent && other.contextWindow == contextWindow;

  @override
  int get hashCode => contextWindow.hashCode;

  @override
  String toString() => 'SystemInitEvent(contextWindow: $contextWindow)';
}
