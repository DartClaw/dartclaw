import 'channel_feedback.dart';

/// Structured progress events emitted by [TurnRunner] during turn execution.
///
/// Consumers subscribe to a single `Stream<TurnProgressEvent>` instead of
/// raw harness events, eliminating duplicated counters, timers, and state.
sealed class TurnProgressEvent {
  /// Snapshot of turn progress at the time this event was emitted.
  final TurnProgressSnapshot snapshot;

  const TurnProgressEvent({required this.snapshot});
}

/// A tool invocation was requested by the agent.
final class ToolStartedProgressEvent extends TurnProgressEvent {
  final String toolName;
  final int toolCallCount;

  const ToolStartedProgressEvent({required super.snapshot, required this.toolName, required this.toolCallCount});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ToolStartedProgressEvent && other.toolName == toolName && other.toolCallCount == toolCallCount;

  @override
  int get hashCode => Object.hash(toolName, toolCallCount);

  @override
  String toString() => 'ToolStartedProgressEvent(toolName: $toolName, toolCallCount: $toolCallCount)';
}

/// A tool invocation completed (successfully or with error).
final class ToolCompletedProgressEvent extends TurnProgressEvent {
  final String toolName;
  final bool isError;

  const ToolCompletedProgressEvent({required super.snapshot, required this.toolName, required this.isError});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ToolCompletedProgressEvent && other.toolName == toolName && other.isError == isError;

  @override
  int get hashCode => Object.hash(toolName, isError);

  @override
  String toString() => 'ToolCompletedProgressEvent(toolName: $toolName, isError: $isError)';
}

/// Incremental text output from the agent.
final class TextDeltaProgressEvent extends TurnProgressEvent {
  final String text;

  const TextDeltaProgressEvent({required super.snapshot, required this.text});

  @override
  bool operator ==(Object other) => identical(this, other) || other is TextDeltaProgressEvent && other.text == text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'TextDeltaProgressEvent(text: $text)';
}

/// Periodic status tick emitted at a configurable interval.
final class StatusTickProgressEvent extends TurnProgressEvent {
  const StatusTickProgressEvent({required super.snapshot});

  @override
  String toString() => 'StatusTickProgressEvent()';
}

/// The turn has stalled (no progress for the configured timeout).
final class TurnStallProgressEvent extends TurnProgressEvent {
  final Duration stallTimeout;
  final String action;

  const TurnStallProgressEvent({required super.snapshot, required this.stallTimeout, required this.action});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TurnStallProgressEvent && other.stallTimeout == stallTimeout && other.action == action;

  @override
  int get hashCode => Object.hash(stallTimeout, action);

  @override
  String toString() => 'TurnStallProgressEvent(stallTimeout: $stallTimeout, action: $action)';
}
