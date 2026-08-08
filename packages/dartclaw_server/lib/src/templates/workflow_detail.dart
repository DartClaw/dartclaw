import 'package:dartclaw_core/dartclaw_core.dart' show humanizeSpan;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show WorkflowRun, WorkflowRunStatus, workflowCanApprove, workflowCanReject, workflowCanResume, workflowCanRetry;

import 'components.dart';
import 'helpers.dart';
import 'layout.dart';
import 'loader.dart';
import 'sidebar.dart';
import 'topbar.dart';

typedef WorkflowRunPresentation = ({
  String label,
  String badgeClass,
  bool terminal,
  int? progressOverride,
  String meterFillClass,
  String percentageClass,
  String dotClass,
  bool attention,
});

WorkflowRunPresentation workflowRunPresentation(WorkflowRunStatus status) => switch (status) {
  WorkflowRunStatus.pending => (
    label: 'Pending',
    badgeClass: 'status-badge-pending',
    terminal: false,
    progressOverride: null,
    meterFillClass: '',
    percentageClass: '',
    dotClass: 'status-dot--idle',
    attention: false,
  ),
  WorkflowRunStatus.running => (
    label: 'Running',
    badgeClass: 'status-badge-running',
    terminal: false,
    progressOverride: null,
    meterFillClass: '',
    percentageClass: '',
    dotClass: 'status-dot--live',
    attention: false,
  ),
  WorkflowRunStatus.paused => (
    label: 'Paused',
    badgeClass: 'status-badge-paused',
    terminal: false,
    progressOverride: null,
    meterFillClass: 'meter-fill--warning',
    percentageClass: 'text-warning',
    dotClass: 'status-dot--warning',
    attention: false,
  ),
  WorkflowRunStatus.awaitingApproval => (
    label: 'Awaiting approval',
    badgeClass: 'status-badge-awaiting-approval',
    terminal: false,
    progressOverride: null,
    meterFillClass: 'meter-fill--warning',
    percentageClass: 'text-warning',
    dotClass: 'status-dot--attention',
    attention: true,
  ),
  WorkflowRunStatus.completed => (
    label: 'Completed',
    badgeClass: 'status-badge-completed',
    terminal: true,
    progressOverride: 100,
    meterFillClass: '',
    percentageClass: 'text-success',
    dotClass: 'status-dot--success',
    attention: false,
  ),
  WorkflowRunStatus.failed => (
    label: 'Failed',
    badgeClass: 'status-badge-failed',
    terminal: true,
    progressOverride: null,
    meterFillClass: 'meter-fill--error',
    percentageClass: 'text-error',
    dotClass: 'status-dot--error',
    attention: false,
  ),
  WorkflowRunStatus.cancelled => (
    label: 'Cancelled',
    badgeClass: 'status-badge-cancelled',
    terminal: true,
    progressOverride: null,
    meterFillClass: 'meter-fill--warning',
    percentageClass: 'text-warning',
    dotClass: 'status-dot--warning',
    attention: false,
  ),
};

String normalizeWorkflowState(String? value) => (value ?? '')
    .trim()
    .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (match) => '${match[1]}_${match[2]}')
    .toLowerCase()
    .replaceAll(RegExp(r'[\s-]+'), '_')
    .replaceAll(RegExp('_+'), '_');

({String className, String label, String icon}) workflowStepPresentation(String? value) {
  return switch (normalizeWorkflowState(value)) {
    'completed' || 'skipped' => (className: 'pipeline-step--done', label: 'Done', icon: '✓'),
    'running' => (className: 'pipeline-step--running', label: 'Running', icon: '•'),
    'failed' ||
    'rejected' ||
    'interrupted' ||
    'cancelled' ||
    'timed_out' => (className: 'pipeline-step--failed', label: 'Failed', icon: '✗'),
    'awaiting_approval' || 'review' => (className: 'pipeline-step--blocked', label: 'Blocked', icon: '!'),
    'queued' || 'pending' => (className: 'pipeline-step--pending', label: 'Pending', icon: '○'),
    _ => (className: 'pipeline-step--failed', label: 'Unknown status', icon: '!'),
  };
}

({String className, String label, bool resolved}) workflowApprovalPresentation(String? value) {
  return switch (normalizeWorkflowState(value)) {
    'pending' ||
    'waiting' ||
    'awaiting_approval' => (className: 'approval-card--waiting', label: 'Waiting for approval', resolved: false),
    'approved' || 'completed' => (className: 'approval-card--approved', label: 'Approved', resolved: true),
    'rejected' => (className: 'approval-card--rejected', label: 'Rejected', resolved: true),
    'expired' || 'timed_out' => (className: 'approval-card--expired', label: 'Expired', resolved: true),
    _ => (className: 'approval-card--rejected', label: 'Unknown approval status', resolved: true),
  };
}

/// Renders the workflow run detail page with vertical pipeline,
/// progress bar, context viewer, and action buttons.
String workflowDetailPageTemplate({
  required SidebarData sidebarData,
  required List<NavItem> navItems,
  required Map<String, dynamic> run,
  required List<Map<String, dynamic>> steps,
  required List<Map<String, dynamic>> contextEntries,
  required List<Map<String, dynamic>> loopInfo,
  String restartBannerHtml = '',
  String appName = 'DartClaw',
}) {
  final sidebar = buildSidebar(sidebarData: sidebarData, navItems: navItems, appName: appName);
  final definitionName = run['definitionName']?.toString() ?? 'Workflow';
  final topbar = pageTopbarTemplate(
    title: 'Workflow: $definitionName',
    backHref: '/workflows',
    backLabel: 'Back to Workflows',
    restartBannerHtml: restartBannerHtml,
  );
  final runStatus = run['statusValue'] as WorkflowRunStatus;
  final statusName = runStatus.name;
  final presentation = workflowRunPresentation(runStatus);

  // Compute progress.
  final totalSteps = steps.length;
  final completedSteps = steps.where((s) {
    final status = s['status'];
    return status == 'completed' || status == 'skipped';
  }).length;
  final hasStepCount = run['hasStepCount'] == true;
  final computedProgress = totalSteps > 0 ? (completedSteps * 100 ~/ totalSteps) : 0;
  final progressPercent = presentation.progressOverride ?? computedProgress;

  // Determine which actions are available.
  final workflowRun = WorkflowRun(
    id: run['id']?.toString() ?? '',
    definitionName: definitionName,
    status: runStatus,
    contextJson: Map<String, dynamic>.from(run['contextJson'] as Map? ?? const {}),
    variablesJson: const {},
    startedAt: DateTime.now(),
    updatedAt: DateTime.now(),
  );
  final canPause = statusName == 'running';
  final canResume = workflowCanResume(workflowRun);
  final canRetry = workflowCanRetry(workflowRun);
  final canCancel = statusName == 'running' || statusName == 'paused' || statusName == 'awaitingApproval';
  final canApprove = workflowCanApprove(workflowRun);
  final canReject = workflowCanReject(workflowRun);
  final hasActions = canPause || canResume || canRetry || (canCancel && !canApprove) || canApprove || canReject;

  // Annotate steps with loop/parallel info and display labels.
  final annotatedSteps = steps.map((step) {
    final s = Map<String, dynamic>.from(step);
    final stepId = s['id']?.toString() ?? '';

    final loopEntry = loopInfo.cast<Map<String, dynamic>>().firstWhere(
      (l) => (l['stepIds'] as List).contains(stepId),
      orElse: () => <String, dynamic>{},
    );
    s['isLoopStep'] = loopEntry.isNotEmpty;
    if (loopEntry.isNotEmpty) {
      s['loopId'] = loopEntry['loopId'];
      s['loopIteration'] = loopEntry['currentIteration'];
      s['loopMaxIterations'] = loopEntry['maxIterations'];
    }
    final stepPresentation = workflowStepPresentation(s['status']?.toString());
    s['pipelineClass'] = stepPresentation.className;
    s['statusLabel'] = stepPresentation.label;
    s['statusIcon'] = stepPresentation.icon;
    s['isApprovalStep'] = s['type'] == 'approval';
    // Approval sub-object (may be null for non-approval or pre-request steps).
    final approval = s['approval'] as Map<String, dynamic>?;
    s['hasApproval'] = approval != null;
    s['approvalMessage'] = approval?['message']?.toString() ?? '';
    s['approvalFeedback'] = approval?['feedback']?.toString() ?? '';
    s['hasApprovalFeedback'] = approval?['feedback'] != null;
    final approvalPresentation = workflowApprovalPresentation(
      approval?['status']?.toString() ?? s['status']?.toString(),
    );
    s['approvalClass'] = approvalPresentation.className;
    s['approvalStatusLabel'] = approvalPresentation.label;
    s['approvalResolved'] = approvalPresentation.resolved;
    s['typeLabel'] = s['type']?.toString() ?? '';
    s['isParallel'] = s['parallel'] == true;
    return s;
  }).toList();

  // Why-paused banner: reuses fields the run already carries (approval-pause
  // metadata or the generic pause reason) — no new API surface.
  final pauseBanner = _pauseBanner(statusName, run, annotatedSteps);

  // Compute duration.
  final startedAt = run['startedAt'];
  final durationDisplay = _formatDuration(startedAt, run['completedAt']);
  final metricsHtml = [
    metricCardTemplate(color: 'accent', value: presentation.label, label: 'Status'),
    metricCardTemplate(color: 'info', value: _formatTimeAgo(run['startedAt']), label: 'Started'),
    metricCardTemplate(
      color: 'warning',
      value: formatNumber((run['totalTokens'] as num?)?.toInt() ?? 0),
      label: 'Tokens',
    ),
    metricCardTemplate(color: 'error', value: durationDisplay, label: 'Duration'),
  ].join();

  final body = templateLoader.trellis.render(templateLoader.source('workflow_detail'), {
    'sidebar': sidebar,
    'topbar': topbar,
    'runId': run['id'],
    'definitionName': definitionName,
    'status': statusName,
    'statusLabel': presentation.label,
    'statusBadgeClass': presentation.badgeClass,
    'startedAtDisplay': _formatTimeAgo(run['startedAt']),
    'startedAtIso': isoTitle(run['startedAt']?.toString()),
    'updatedAtDisplay': _formatTimeAgo(run['updatedAt']),
    'hasCompletedAt': run['completedAt'] != null,
    'completedAtDisplay': run['completedAt'] != null ? _formatTimeAgo(run['completedAt']) : null,
    'totalTokens': formatNumber((run['totalTokens'] as num?)?.toInt() ?? 0),
    'durationDisplay': durationDisplay,
    'metricsHtml': metricsHtml,
    // A complete pause banner owns the hold reason. Preserve the error fallback
    // for malformed approval records that cannot produce that banner.
    'hasError':
        run['errorMessage'] != null &&
        (statusName == 'failed' || (statusName == 'awaitingApproval' && pauseBanner == null)),
    'errorMessage': run['errorMessage'],
    'progressPercent': progressPercent,
    'meterFillClass': presentation.meterFillClass,
    'percentageClass': presentation.percentageClass,
    'hasStepCount': hasStepCount,
    'completedSteps': completedSteps,
    'totalSteps': totalSteps,
    'hasSteps': annotatedSteps.isNotEmpty,
    'steps': annotatedSteps,
    'contextEntries': contextEntries,
    'hasContext': contextEntries.isNotEmpty,
    'canPause': canPause,
    'canResume': canResume,
    'canRetry': canRetry,
    'canCancel': canCancel && !canApprove,
    'canApprove': canApprove,
    'canReject': canReject,
    'hasActions': hasActions,
    'emptyStepsHtml': emptyStateTemplate(
      title: 'No steps defined',
      body: 'This run has no pipeline steps to display.',
      actionHtml: '<a class="btn btn-primary" href="/workflows">View workflow runs</a>',
    ),
    'hasPauseBanner': pauseBanner != null,
    'pauseBannerClass': pauseBanner?.cssClass,
    'pauseBannerLabel': pauseBanner?.label,
    'pauseBannerText': pauseBanner?.text,
  });

  return layoutTemplate(
    title: 'Workflow: $definitionName',
    body: body,
    appName: appName,
    scripts: standardShellScripts(),
  );
}

/// Renders the step detail partial fragment for a workflow step.
String workflowStepDetailFragment({
  required String? messagesHtml,
  required String stepName,
  required List<Map<String, dynamic>> artifacts,
  required List<Map<String, dynamic>> inputs,
  required List<Map<String, dynamic>> outputKeys,
  int? tokenCount,
  String? durationDisplay,
}) {
  final hasTokens = tokenCount != null && tokenCount > 0;
  final hasDuration = durationDisplay != null && durationDisplay.isNotEmpty;
  return templateLoader.trellis.renderFragment(
    templateLoader.source('workflow_step_detail'),
    fragment: 'stepDetail',
    context: {
      'hasSession': messagesHtml != null,
      'messagesHtml': messagesHtml,
      'stepName': stepName,
      'noSessionText': 'No session started yet.',
      'hasArtifacts': artifacts.isNotEmpty,
      'artifacts': artifacts,
      'hasInputs': inputs.isNotEmpty,
      'inputs': inputs,
      'hasOutputKeys': outputKeys.isNotEmpty,
      'outputKeys': outputKeys,
      'hasMetrics': hasTokens || hasDuration,
      'tokenCount': tokenCount != null ? formatNumber(tokenCount) : '0',
      'hasDuration': hasDuration,
      'durationDisplay': durationDisplay,
      'durationAbsent': absentValue(durationDisplay).isAbsent,
    },
  );
}

/// Why-paused banner content, or null when the run is not paused.
class _PauseBanner {
  final String cssClass;
  final String label;
  final String text;
  const _PauseBanner({required this.cssClass, required this.label, required this.text});
}

/// Derives the why-paused banner from fields the run already carries: approval
/// (and needsInput) holds surface the pending step name (+ its request/needs-input
/// message, read from the flat context key `<stepId>.approval.message` the model
/// writes for both); a generic `paused` run surfaces its pause reason
/// (`errorMessage`) or a resume hint.
_PauseBanner? _pauseBanner(String statusName, Map<String, dynamic> run, List<Map<String, dynamic>> steps) {
  if (statusName == 'awaitingApproval') {
    final pendingStepId = run['pendingApprovalStepId']?.toString();
    if (pendingStepId == null || pendingStepId.isEmpty) return null;
    final pendingStep = steps.firstWhere(
      (s) => s['id']?.toString() == pendingStepId,
      orElse: () => const <String, dynamic>{},
    );
    final stepLabel = (pendingStep['name']?.toString().isNotEmpty ?? false)
        ? pendingStep['name'].toString()
        : pendingStepId;
    final contextJson = (run['contextJson'] as Map?) ?? const {};
    final message = contextJson['$pendingStepId.approval.message']?.toString() ?? '';
    final text = message.isNotEmpty
        ? 'Step "$stepLabel" needs a decision: $message Use Approve or Reject below.'
        : 'Step "$stepLabel" needs a decision. Use Approve or Reject below.';
    return _PauseBanner(cssClass: 'banner-warning', label: 'Awaiting approval', text: text);
  }
  if (statusName == 'paused') {
    final reason = run['errorMessage']?.toString();
    final text = (reason != null && reason.isNotEmpty)
        ? '$reason Use Resume below to continue.'
        : 'This run is paused. Use Resume below to continue.';
    return _PauseBanner(cssClass: 'banner-info', label: 'Paused', text: text);
  }
  return null;
}

String _formatTimeAgo(Object? value) {
  if (value == null) return '';
  try {
    final dt = value is DateTime ? value : DateTime.parse(value.toString());
    return formatRelativeTime(dt);
  } catch (_) {
    return value.toString(); // Unparseable timestamp — fall back to raw string.
  }
}

String? _formatDuration(Object? startedAt, Object? completedAt) {
  if (startedAt == null) return null;
  try {
    final start = startedAt is DateTime ? startedAt : DateTime.parse(startedAt.toString());
    final end = completedAt != null
        ? (completedAt is DateTime ? completedAt : DateTime.parse(completedAt.toString()))
        : null;
    return humanizeSpan(start, end, true);
  } catch (_) {
    return null; // Unparseable timestamp or null end time — renders as absent.
  }
}
