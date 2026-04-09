import 'package:dartclaw_core/dartclaw_core.dart';

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
AlertClassification? classifyAlert(DartclawEvent event) {
  if (event is GuardBlockEvent) {
    return (alertType: 'guard_block', severity: AlertSeverity.warning);
  }
  if (event is ContainerCrashedEvent) {
    return (alertType: 'container_crash', severity: AlertSeverity.critical);
  }
  if (event is TaskStatusChangedEvent && event.newStatus == TaskStatus.failed) {
    return (alertType: 'task_failure', severity: AlertSeverity.warning);
  }
  if (event is ScheduledJobFailedEvent) {
    return (alertType: 'job_failure', severity: AlertSeverity.critical);
  }
  if (event is BudgetWarningEvent) {
    return (alertType: 'budget_warning', severity: AlertSeverity.warning);
  }
  if (event is WorkflowBudgetWarningEvent) {
    return (alertType: 'budget_warning', severity: AlertSeverity.warning);
  }
  if (event is CompactionCompletedEvent) {
    return (alertType: 'compaction', severity: AlertSeverity.info);
  }
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
