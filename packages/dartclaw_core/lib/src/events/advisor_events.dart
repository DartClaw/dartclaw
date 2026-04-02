part of 'dartclaw_event.dart';

/// Fired when a channel user explicitly invokes `@advisor`.
final class AdvisorMentionEvent extends DartclawEvent {
  /// Sender identifier from the originating channel.
  final String senderJid;

  /// Originating channel type.
  final String channelType;

  /// Channel recipient used to route advisor responses.
  final String recipientId;

  /// Thread or group identifier for the originating conversation.
  final String? threadId;

  /// Full user message that invoked the advisor.
  final String messageText;

  /// Session key associated with the originating conversation.
  final String sessionKey;

  /// Bound task id when the mention occurred inside a routed task context.
  final String? taskId;

  @override
  final DateTime timestamp;

  AdvisorMentionEvent({
    required this.senderJid,
    required this.channelType,
    required this.recipientId,
    this.threadId,
    required this.messageText,
    required this.sessionKey,
    this.taskId,
    required this.timestamp,
  });

  @override
  String toString() =>
      'AdvisorMentionEvent(sender: $senderJid, channel: $channelType, recipient: $recipientId, session: $sessionKey)';
}

/// Fired when the advisor agent produces a structured insight.
final class AdvisorInsightEvent extends DartclawEvent {
  /// Advisor assessment (for example `on_track` or `stuck`).
  final String status;

  /// Primary observation produced by the advisor.
  final String observation;

  /// Optional suggestion produced by the advisor.
  final String? suggestion;

  /// Trigger type that caused the advisor to fire.
  final String triggerType;

  /// Task ids referenced by the advisor.
  final List<String> taskIds;

  /// Session key observed by the advisor.
  final String sessionKey;

  @override
  final DateTime timestamp;

  AdvisorInsightEvent({
    required this.status,
    required this.observation,
    this.suggestion,
    required this.triggerType,
    required this.taskIds,
    required this.sessionKey,
    required this.timestamp,
  });

  @override
  String toString() =>
      'AdvisorInsightEvent(status: $status, trigger: $triggerType, session: $sessionKey, tasks: $taskIds)';
}
