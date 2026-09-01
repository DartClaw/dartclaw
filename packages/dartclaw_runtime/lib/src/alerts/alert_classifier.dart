import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';

/// Severity classification for alert events (D17).
enum AlertSeverity { info, warning, critical }

/// Alert classification result: type identifier, severity, and the
/// operator-facing content the alert carries.
///
/// [body] is the message text; [details] are the named fields a structured
/// channel renders beside it, or `null` when the alert has none.
typedef AlertClassification = ({String alertType, AlertSeverity severity, String body, Map<String, String>? details});

/// Maps a [DartclawEvent] to an [AlertClassification], or `null` if the event
/// is not alertable (D16/D17).
///
/// This is the only place an alert's identity, severity and content are
/// decided: an event that classifies to `null` has no renderable alert form at
/// all. The switch below is the mapping – it names every [DartclawEvent]
/// subtype explicitly and carries no wildcard arm, so adding an event type
/// fails the build until it is classified (ADR-057).
AlertClassification? classifyAlert(DartclawEvent event) {
  return switch (event) {
    GuardBlockEvent() => (
      alertType: 'guard_block',
      severity: AlertSeverity.warning,
      body:
          '${event.guardName} (${event.guardCategory}): ${event.verdict}'
          '${event.verdictMessage != null ? " — ${event.verdictMessage}" : ""}',
      details: {'Hook': event.hookPoint, if (event.sessionKey != null) 'Session': event.sessionKey!},
    ),
    ContainerCrashedEvent() => (
      alertType: 'container_crash',
      severity: AlertSeverity.critical,
      body: '${event.containerName}: ${event.error}',
      details: null,
    ),
    TaskStatusChangedEvent(newStatus: TaskStatus.failed) => (
      alertType: 'task_failure',
      severity: AlertSeverity.warning,
      body: 'Task ${event.taskId} failed (trigger: ${event.trigger})',
      details: {'Task ID': event.taskId, 'Trigger': event.trigger},
    ),
    ScheduledJobFailedEvent() => (
      alertType: 'job_failure',
      severity: AlertSeverity.critical,
      body: 'Job ${event.jobId}: ${event.error}',
      details: {'Job ID': event.jobId},
    ),
    BudgetWarningEvent() => (
      alertType: 'budget_warning',
      severity: AlertSeverity.warning,
      body:
          'Task ${event.taskId}: ${event.consumed}/${event.limit} tokens '
          '(${(event.consumedPercent * 100).toStringAsFixed(0)}%)',
      details: {'Task ID': event.taskId},
    ),
    WorkflowBudgetWarningEvent() => (
      alertType: 'budget_warning',
      severity: AlertSeverity.warning,
      body:
          'Workflow run ${event.runId}: ${event.consumed}/${event.limit} tokens '
          '(${(event.consumedPercent * 100).toStringAsFixed(0)}%)',
      details: {'Run ID': event.runId, 'Workflow': event.definitionName},
    ),
    CompactionCompletedEvent() => (
      alertType: 'compaction',
      severity: AlertSeverity.info,
      body:
          'Session ${event.sessionId} compacted (trigger: ${event.trigger}'
          '${event.preTokens != null ? ", pre: ${event.preTokens} tokens" : ""})',
      details: {'Session ID': event.sessionId, 'Trigger': event.trigger},
    ),
    LoopDetectedEvent() => (
      alertType: 'loop_detected',
      severity: AlertSeverity.critical,
      body: 'Loop detected in session ${event.sessionId} (mechanism: ${event.mechanism}, action: ${event.action})',
      details: {'Session': event.sessionId, 'Mechanism': event.mechanism, 'Action': event.action},
    ),
    EmergencyStopEvent() => (
      alertType: 'emergency_stop',
      severity: AlertSeverity.critical,
      body:
          'Emergency stop by ${event.stoppedBy} — ${event.turnsCancelled} turn(s), '
          '${event.tasksCancelled} task(s) cancelled',
      details: {
        'Stopped by': event.stoppedBy,
        'Turns cancelled': '${event.turnsCancelled}',
        'Tasks cancelled': '${event.tasksCancelled}',
      },
    ),
    CredentialHealthChangedEvent(state: CredentialHealthState.nearingExpiry) => _credentialAlert(
      event,
      'credential_expiry',
      AlertSeverity.warning,
    ),
    CredentialHealthChangedEvent(state: CredentialHealthState.refreshFailure) => _credentialAlert(
      event,
      'credential_refresh_failure',
      AlertSeverity.warning,
    ),
    CredentialHealthChangedEvent(state: CredentialHealthState.reauthRequired) => _credentialAlert(
      event,
      'credential_reauth_required',
      AlertSeverity.critical,
    ),
    CredentialHealthChangedEvent(state: CredentialHealthState.contractBreak) => _credentialAlert(
      event,
      'credential_contract_break',
      AlertSeverity.critical,
    ),
    // Healthy and unknown are recorded and rendered, never alerted: a recovery
    // message is noise and an uncheckable credential is not a fault.
    CredentialHealthChangedEvent() => null,
    TaskStatusChangedEvent() => null,
    ProjectStatusChangedEvent() => null,
    FailedAuthEvent() => null,
    ToolPermissionDeniedEvent() => null,
    ConfigChangedEvent() => null,
    ContainerStartedEvent() => null,
    ContainerStoppedEvent() => null,
    TaskReviewReadyEvent() => null,
    TaskEventCreatedEvent() => null,
    TurnWaitStateChangedEvent() => null,
    SessionCreatedEvent() => null,
    SessionEndedEvent() => null,
    SessionErrorEvent() => null,
    CompactionStartingEvent() => null,
    WorkflowRunStatusChangedEvent() => null,
    WorkflowStepCompletedEvent() => null,
    WorkflowCliStallEvent() => null,
    WorkflowCliTurnProgressEvent() => null,
    ParallelGroupCompletedEvent() => null,
    LoopIterationCompletedEvent() => null,
    MapIterationCompletedEvent() => null,
    WorkflowApprovalRequestedEvent() => null,
    WorkflowApprovalResolvedEvent() => null,
    MapStepCompletedEvent() => null,
    WorkflowSerializationEnactedEvent() => null,
    StepSkippedEvent() => null,
    RunnerStateChangedEvent() => null,
    AgentExecutionStatusChangedEvent() => null,
    OutboundMcpGovernanceEvent() => null,
    ContextResearchMetricsEvent() => null,
  };
}

/// The four degraded credential states share one body and one detail map; only
/// the alert type and severity differ per state.
AlertClassification _credentialAlert(CredentialHealthChangedEvent event, String alertType, AlertSeverity severity) => (
  alertType: alertType,
  severity: severity,
  body:
      "Provider '${event.providerId}': ${event.detail}"
      '${event.remediation == null ? "" : " Remediation: ${event.remediation}"}',
  details: {
    'Provider': event.providerId,
    'State': event.state.jsonName,
    if (event.remediation != null) 'Remediation': event.remediation!,
    if (event.expiry != null)
      'Expires': '${event.expiry!.expiresAt.toIso8601String()}${event.expiry!.derived ? " (estimated)" : ""}',
  },
);

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
