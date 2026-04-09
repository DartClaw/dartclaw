import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';

import 'alert_classifier.dart';

/// Produces channel-appropriate [ChannelResponse]s for alert events.
///
/// - Google Chat (`googlechat`): Cards v2 with severity-colored header via
///   [ChatCardBuilder.alertNotification], plus plain text fallback.
/// - All other channels (WhatsApp, Signal, unknown): plain text only.
///
/// Stateless — safe to share across threads.
class AlertFormatter {
  final ChatCardBuilder _cardBuilder;

  const AlertFormatter({ChatCardBuilder cardBuilder = const ChatCardBuilder()}) : _cardBuilder = cardBuilder;

  /// Formats [event] into a [ChannelResponse] appropriate for [channelType].
  ///
  /// [alertType] and [severity] must come from [classifyAlert].
  ChannelResponse format({
    required DartclawEvent event,
    required String alertType,
    required AlertSeverity severity,
    required String channelType,
  }) {
    final title = _title(alertType);
    final body = _body(event);
    final severityPrefix = '[${severity.name.toUpperCase()}]';
    final plainText = '$severityPrefix $title: $body';

    if (channelType == 'googlechat') {
      final card = _cardBuilder.alertNotification(
        title: title,
        severity: severity.name,
        body: body,
        details: _details(event),
      );
      return ChannelResponse(text: plainText, structuredPayload: card);
    }

    return ChannelResponse(text: plainText);
  }

  /// Formats a burst summary into a [ChannelResponse] appropriate for [channelType].
  ChannelResponse formatSummary({
    required String alertType,
    required AlertSeverity severity,
    required String channelType,
    required int count,
    required Duration cooldown,
  }) {
    final title = '${_title(alertType)} Summary';
    final timeLabel = _timeLabel(cooldown);
    final body = '$count alert${count == 1 ? '' : 's'} in last $timeLabel';
    final severityPrefix = '[${severity.name.toUpperCase()}]';
    final plainText = '$severityPrefix $title: $body';

    if (channelType == 'googlechat') {
      final card = _cardBuilder.alertNotification(
        title: title,
        severity: severity.name,
        body: body,
        details: {'Count': '$count', 'Window': timeLabel},
      );
      return ChannelResponse(text: plainText, structuredPayload: card);
    }

    return ChannelResponse(text: plainText);
  }

  String _title(String alertType) => switch (alertType) {
    'guard_block' => 'Guard Block',
    'container_crash' => 'Container Crash',
    'task_failure' => 'Task Failure',
    'job_failure' => 'Scheduled Job Failure',
    'budget_warning' => 'Budget Warning',
    'compaction' => 'Context Compaction',
    _ => alertType,
  };

  String _body(DartclawEvent event) {
    if (event is GuardBlockEvent) {
      return '${event.guardName} (${event.guardCategory}): ${event.verdict}'
          '${event.verdictMessage != null ? " — ${event.verdictMessage}" : ""}';
    }
    if (event is ContainerCrashedEvent) {
      return '${event.containerName}: ${event.error}';
    }
    if (event is TaskStatusChangedEvent) {
      return 'Task ${event.taskId} failed (trigger: ${event.trigger})';
    }
    if (event is ScheduledJobFailedEvent) {
      return 'Job ${event.jobId}: ${event.error}';
    }
    if (event is BudgetWarningEvent) {
      return 'Task ${event.taskId}: ${event.consumed}/${event.limit} tokens '
          '(${(event.consumedPercent * 100).toStringAsFixed(0)}%)';
    }
    if (event is WorkflowBudgetWarningEvent) {
      return 'Workflow run ${event.runId}: ${event.consumed}/${event.limit} tokens '
          '(${(event.consumedPercent * 100).toStringAsFixed(0)}%)';
    }
    if (event is CompactionCompletedEvent) {
      return 'Session ${event.sessionId} compacted (trigger: ${event.trigger}'
          '${event.preTokens != null ? ", pre: ${event.preTokens} tokens" : ""})';
    }
    return event.toString();
  }

  Map<String, String>? _details(DartclawEvent event) {
    if (event is GuardBlockEvent) {
      return {'Hook': event.hookPoint, if (event.sessionKey != null) 'Session': event.sessionKey!};
    }
    if (event is TaskStatusChangedEvent) {
      return {'Task ID': event.taskId, 'Trigger': event.trigger};
    }
    if (event is ScheduledJobFailedEvent) {
      return {'Job ID': event.jobId};
    }
    if (event is BudgetWarningEvent) {
      return {'Task ID': event.taskId};
    }
    if (event is WorkflowBudgetWarningEvent) {
      return {'Run ID': event.runId, 'Workflow': event.definitionName};
    }
    if (event is CompactionCompletedEvent) {
      return {'Session ID': event.sessionId, 'Trigger': event.trigger};
    }
    return null;
  }

  static String _timeLabel(Duration cooldown) {
    final minutes = cooldown.inMinutes;
    if (minutes > 0 && cooldown.inSeconds % 60 == 0) {
      return '$minutes minute${minutes == 1 ? '' : 's'}';
    }
    return '${cooldown.inSeconds} seconds';
  }
}
