part of 'dartclaw_event.dart';

/// Intermediate sealed type for compaction lifecycle events.
sealed class CompactionLifecycleEvent extends DartclawEvent {
  /// Identifier of the SDK session experiencing compaction.
  final String sessionId;

  /// Trigger source: `"auto"` or `"manual"`.
  final String trigger;

  @override
  final DateTime timestamp;

  /// Creates a compaction lifecycle event.
  CompactionLifecycleEvent({required this.sessionId, required this.trigger, required this.timestamp});
}

/// Fired when context compaction is about to begin.
///
/// Emitted from the `PreCompact` hook callback before the compaction occurs.
/// Downstream systems can use this to flush pending state before the context
/// is reduced.
// NOT_ALERTABLE: lifecycle telemetry — surfaced via SSE only
final class CompactionStartingEvent extends CompactionLifecycleEvent {
  CompactionStartingEvent({required super.sessionId, required super.trigger, required super.timestamp});

  @override
  String toString() => 'CompactionStartingEvent(session: $sessionId, trigger: $trigger)';
}

/// Fired when context compaction has completed.
///
/// Emitted on receipt of the `compact_boundary` system message from the Claude
/// binary. When an active task exists in the session, a `TaskEvent` with kind
/// `Compaction` is also recorded.
final class CompactionCompletedEvent extends CompactionLifecycleEvent {
  /// Token count before compaction, from `compact_boundary`. May be null if
  /// the wire format omits `pre_tokens`.
  final int? preTokens;

  /// Reserved for future `PostCompact` hook data. Always null because
  /// `PostCompact` is not available via JSONL.
  final String? summary;

  CompactionCompletedEvent({
    required super.sessionId,
    required super.trigger,
    this.preTokens,
    this.summary,
    required super.timestamp,
  });

  @override
  String toString() => 'CompactionCompletedEvent(session: $sessionId, trigger: $trigger, preTokens: $preTokens)';
}
