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

  String _body(DartclawEvent event) => switch (event) {
    GuardBlockEvent() =>
      '${event.guardName} (${event.guardCategory}): ${event.verdict}'
          '${event.verdictMessage != null ? " — ${event.verdictMessage}" : ""}',
    ContainerCrashedEvent() => '${event.containerName}: ${event.error}',
    TaskStatusChangedEvent() => 'Task ${event.taskId} failed (trigger: ${event.trigger})',
    ScheduledJobFailedEvent() => 'Job ${event.jobId}: ${event.error}',
    BudgetWarningEvent() =>
      'Task ${event.taskId}: ${event.consumed}/${event.limit} tokens '
          '(${(event.consumedPercent * 100).toStringAsFixed(0)}%)',
    WorkflowBudgetWarningEvent() =>
      'Workflow run ${event.runId}: ${event.consumed}/${event.limit} tokens '
          '(${(event.consumedPercent * 100).toStringAsFixed(0)}%)',
    CompactionCompletedEvent() =>
      'Session ${event.sessionId} compacted (trigger: ${event.trigger}'
          '${event.preTokens != null ? ", pre: ${event.preTokens} tokens" : ""})',
    LoopDetectedEvent() =>
      'Loop detected in session ${event.sessionId} (mechanism: ${event.mechanism}, action: ${event.action})',
    EmergencyStopEvent() =>
      'Emergency stop by ${event.stoppedBy} — ${event.turnsCancelled} turn(s), ${event.tasksCancelled} task(s) cancelled',
    AdvisorInsightEvent() => 'Advisor flagged status "${event.status}" — ${event.observation}',
    ProjectStatusChangedEvent() => event.runtimeType.toString(),
    FailedAuthEvent() => event.runtimeType.toString(),
    ToolPermissionDeniedEvent() => event.runtimeType.toString(),
    ConfigChangedEvent() => event.runtimeType.toString(),
    ContainerStartedEvent() => event.runtimeType.toString(),
    ContainerStoppedEvent() => event.runtimeType.toString(),
    TaskReviewReadyEvent() => event.runtimeType.toString(),
    TaskEventCreatedEvent() => event.runtimeType.toString(),
    SessionCreatedEvent() => event.runtimeType.toString(),
    SessionEndedEvent() => event.runtimeType.toString(),
    SessionErrorEvent() => event.runtimeType.toString(),
    AdvisorMentionEvent() => event.runtimeType.toString(),
    CompactionStartingEvent() => event.runtimeType.toString(),
    WorkflowRunStatusChangedEvent() => event.runtimeType.toString(),
    WorkflowStepCompletedEvent() => event.runtimeType.toString(),
    WorkflowCliTurnProgressEvent() => event.runtimeType.toString(),
    ParallelGroupCompletedEvent() => event.runtimeType.toString(),
    LoopIterationCompletedEvent() => event.runtimeType.toString(),
    MapIterationCompletedEvent() => event.runtimeType.toString(),
    WorkflowApprovalRequestedEvent() => event.runtimeType.toString(),
    WorkflowApprovalResolvedEvent() => event.runtimeType.toString(),
    MapStepCompletedEvent() => event.runtimeType.toString(),
    WorkflowSerializationEnactedEvent() => event.runtimeType.toString(),
    StepSkippedEvent() => event.runtimeType.toString(),
    AgentStateChangedEvent() => event.runtimeType.toString(),
    AgentExecutionStatusChangedEvent() => event.runtimeType.toString(),
  };

  Map<String, String>? _details(DartclawEvent event) => switch (event) {
    GuardBlockEvent() => {'Hook': event.hookPoint, if (event.sessionKey != null) 'Session': event.sessionKey!},
    TaskStatusChangedEvent() => {'Task ID': event.taskId, 'Trigger': event.trigger},
    ScheduledJobFailedEvent() => {'Job ID': event.jobId},
    BudgetWarningEvent() => {'Task ID': event.taskId},
    WorkflowBudgetWarningEvent() => {'Run ID': event.runId, 'Workflow': event.definitionName},
    CompactionCompletedEvent() => {'Session ID': event.sessionId, 'Trigger': event.trigger},
    LoopDetectedEvent() => {'Session': event.sessionId, 'Mechanism': event.mechanism, 'Action': event.action},
    EmergencyStopEvent() => {
      'Stopped by': event.stoppedBy,
      'Turns cancelled': '${event.turnsCancelled}',
      'Tasks cancelled': '${event.tasksCancelled}',
    },
    AdvisorInsightEvent() => {
      'Status': event.status,
      'Observation': event.observation,
      if (event.suggestion != null) 'Suggestion': event.suggestion!,
      'Trigger': event.triggerType,
      'Tasks': event.taskIds.join(', '),
      'Session': event.sessionKey,
    },
    ContainerCrashedEvent() => null, // alerts without additional detail fields
    ProjectStatusChangedEvent() => null,
    FailedAuthEvent() => null,
    ToolPermissionDeniedEvent() => null,
    ConfigChangedEvent() => null,
    ContainerStartedEvent() => null,
    ContainerStoppedEvent() => null,
    TaskReviewReadyEvent() => null,
    TaskEventCreatedEvent() => null,
    SessionCreatedEvent() => null,
    SessionEndedEvent() => null,
    SessionErrorEvent() => null,
    AdvisorMentionEvent() => null,
    CompactionStartingEvent() => null,
    WorkflowRunStatusChangedEvent() => null,
    WorkflowStepCompletedEvent() => null,
    WorkflowCliTurnProgressEvent() => null,
    ParallelGroupCompletedEvent() => null,
    LoopIterationCompletedEvent() => null,
    MapIterationCompletedEvent() => null,
    WorkflowApprovalRequestedEvent() => null,
    WorkflowApprovalResolvedEvent() => null,
    MapStepCompletedEvent() => null,
    WorkflowSerializationEnactedEvent() => null,
    StepSkippedEvent() => null,
    AgentStateChangedEvent() => null,
    AgentExecutionStatusChangedEvent() => null,
  };

  static String _timeLabel(Duration cooldown) {
    final minutes = cooldown.inMinutes;
    if (minutes > 0 && cooldown.inSeconds % 60 == 0) {
      return '$minutes minute${minutes == 1 ? '' : 's'}';
    }
    return '${cooldown.inSeconds} seconds';
  }
}
