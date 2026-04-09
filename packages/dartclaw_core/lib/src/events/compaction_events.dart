part of 'dartclaw_event.dart';

/// Intermediate sealed type for compaction lifecycle events.
sealed class CompactionLifecycleEvent extends DartclawEvent {
  /// Identifier of the SDK session experiencing compaction.
  String get sessionId;

  /// Trigger source: `"auto"` or `"manual"`.
  String get trigger;

  @override
  DateTime get timestamp;
}

/// Fired when context compaction is about to begin.
///
/// Emitted from the `PreCompact` hook callback before the compaction occurs.
/// Downstream systems can use this to flush pending state before the context
/// is reduced.
final class CompactionStartingEvent extends CompactionLifecycleEvent {
  @override
  final String sessionId;

  @override
  final String trigger;

  @override
  final DateTime timestamp;

  CompactionStartingEvent({
    required this.sessionId,
    required this.trigger,
    required this.timestamp,
  });

  @override
  String toString() =>
      'CompactionStartingEvent(session: $sessionId, trigger: $trigger)';
}

/// Fired when context compaction has completed.
///
/// Emitted on receipt of the `compact_boundary` system message from the Claude
/// binary. When an active task exists in the session, a `TaskEvent` with kind
/// `Compaction` is also recorded.
final class CompactionCompletedEvent extends CompactionLifecycleEvent {
  @override
  final String sessionId;

  @override
  final String trigger;

  /// Token count before compaction, from `compact_boundary`. May be null if
  /// the wire format omits `pre_tokens`.
  final int? preTokens;

  /// Reserved for future `PostCompact` hook data. Always null in 0.16 —
  /// `PostCompact` is not available via JSONL.
  final String? summary;

  @override
  final DateTime timestamp;

  CompactionCompletedEvent({
    required this.sessionId,
    required this.trigger,
    this.preTokens,
    this.summary,
    required this.timestamp,
  });

  @override
  String toString() =>
      'CompactionCompletedEvent(session: $sessionId, trigger: $trigger, preTokens: $preTokens)';
}
