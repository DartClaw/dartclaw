import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

final _log = Logger('AlertClassifier');

/// Severity classification for alert events (D17).
enum AlertSeverity { info, warning, critical }

/// Alert classification result: type identifier + severity.
typedef AlertClassification = ({String alertType, AlertSeverity severity});

/// Maps a [DartclawEvent] to an [AlertClassification], or `null` if the event
/// is not alertable.
///
/// Mapping per D16/D17:
/// - [GuardBlockEvent]               → `guard_block` / warning
/// - [ContainerCrashedEvent]         → `container_crash` / critical
/// - [TaskStatusChangedEvent] failed → `task_failure` / warning
/// - [ScheduledJobFailedEvent]       → `job_failure` / critical
/// - [BudgetWarningEvent]            → `budget_warning` / warning
/// - [WorkflowBudgetWarningEvent]    → `budget_warning` / warning
/// - [CompactionCompletedEvent]      → `compaction` / info
/// - [LoopDetectedEvent]             → `loop_detected` / critical
/// - [EmergencyStopEvent]            → `emergency_stop` / critical
/// - [AdvisorInsightEvent]           → `advisor_insight` / warning|critical by status
AlertClassification? classifyAlert(DartclawEvent event) {
  return switch (event) {
    GuardBlockEvent() => (alertType: 'guard_block', severity: AlertSeverity.warning),
    ContainerCrashedEvent() => (alertType: 'container_crash', severity: AlertSeverity.critical),
    TaskStatusChangedEvent(newStatus: TaskStatus.failed) => (
      alertType: 'task_failure',
      severity: AlertSeverity.warning,
    ),
    ScheduledJobFailedEvent() => (alertType: 'job_failure', severity: AlertSeverity.critical),
    BudgetWarningEvent() => (alertType: 'budget_warning', severity: AlertSeverity.warning),
    WorkflowBudgetWarningEvent() => (alertType: 'budget_warning', severity: AlertSeverity.warning),
    CompactionCompletedEvent() => (alertType: 'compaction', severity: AlertSeverity.info),
    LoopDetectedEvent() => (alertType: 'loop_detected', severity: AlertSeverity.critical),
    EmergencyStopEvent() => (alertType: 'emergency_stop', severity: AlertSeverity.critical),
    AdvisorInsightEvent(status: 'stuck') => (alertType: 'advisor_insight', severity: AlertSeverity.warning),
    AdvisorInsightEvent(status: 'concerning') => (alertType: 'advisor_insight', severity: AlertSeverity.critical),
    AdvisorInsightEvent(status: final status) => _logUnknownAdvisorStatus(status),
    TaskStatusChangedEvent() => null,
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
}

AlertClassification? _logUnknownAdvisorStatus(String status) {
  _log.fine('AdvisorInsightEvent unrecognised status: $status — no alert');
  return null;
}

/// Returns `true` if a failed task with the given [configJson] should generate
/// an alert (D19 non-channel filter).
///
/// Suppresses alerts for tasks that originated from a DM or group channel
/// session — these are already notified via [TaskNotificationSubscriber].
/// Tasks with no [TaskOrigin] (web/cron/API origin) are always alerted.
///
/// On [SessionKey.parse] failure (malformed sessionKey), fails open: returns
/// `true` so the alert is delivered rather than silently dropped.
bool shouldAlertTaskFailure(Map<String, dynamic> configJson) {
  final origin = TaskOrigin.fromConfigJson(configJson);
  if (origin == null) return true;

  try {
    final key = SessionKey.parse(origin.sessionKey);
    return key.scope != 'dm' && key.scope != 'group';
  } on FormatException {
    return true; // fail-open: malformed key → alert
  }
}
