import 'package:dartclaw_core/dartclaw_core.dart' show humanizeSpan;

import 'helpers.dart';
import 'layout.dart';
import 'loader.dart';
import 'sidebar.dart';
import 'topbar.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        WorkflowRun,
        WorkflowRunStatus,
        workflowCanApprove,
        workflowCanReject,
        workflowCanResume,
        workflowCanRetry,
        workflowStatusBadgeClass,
        workflowStatusLabel;

/// Renders the workflow run detail page with vertical pipeline,
/// progress bar, context viewer, and action buttons.
String workflowDetailPageTemplate({
  required SidebarData sidebarData,
  required List<NavItem> navItems,
  required Map<String, dynamic> run,
  required List<Map<String, dynamic>> steps,
  required List<Map<String, dynamic>> contextEntries,
  required List<Map<String, dynamic>> loopInfo,
  String bannerHtml = '',
  String appName = 'DartClaw',
}) {
  final sidebar = buildSidebar(sidebarData: sidebarData, navItems: navItems, appName: appName);
  final definitionName = run['definitionName']?.toString() ?? 'Workflow';
  final topbar = pageTopbarTemplate(
    title: 'Workflow: $definitionName',
    backHref: '/workflows',
    backLabel: 'Back to Workflows',
  );
  final statusName = run['status']?.toString() ?? 'pending';

  // Compute progress.
  final totalSteps = steps.length;
  final completedSteps = steps.where((s) {
    final status = s['status'];
    return status == 'completed' || status == 'skipped';
  }).length;
  final progressPercent = totalSteps > 0 ? (completedSteps * 100 ~/ totalSteps) : 0;

  // Determine which actions are available.
  final runStatus = switch (statusName) {
    'pending' => WorkflowRunStatus.pending,
    'running' => WorkflowRunStatus.running,
    'paused' => WorkflowRunStatus.paused,
    'awaitingApproval' => WorkflowRunStatus.awaitingApproval,
    'completed' => WorkflowRunStatus.completed,
    'failed' => WorkflowRunStatus.failed,
    'cancelled' => WorkflowRunStatus.cancelled,
    _ => WorkflowRunStatus.pending,
  };
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
    s['isActiveStep'] = s['status'] == 'running';
    s['isApprovalStep'] = s['type'] == 'approval';
    s['isAwaitingApproval'] = s['status'] == 'awaiting_approval';
    s['isApprovalCompleted'] = s['type'] == 'approval' && s['status'] == 'completed';
    s['isApprovalRejected'] = s['status'] == 'rejected';
    // Approval sub-object (may be null for non-approval or pre-request steps).
    final approval = s['approval'] as Map<String, dynamic>?;
    s['hasApproval'] = approval != null;
    s['approvalMessage'] = approval?['message']?.toString() ?? '';
    s['approvalFeedback'] = approval?['feedback']?.toString() ?? '';
    s['hasApprovalFeedback'] = approval?['feedback'] != null;
    s['statusLabel'] = switch (s['status']?.toString()) {
      'awaiting_approval' => 'Awaiting Approval',
      'rejected' => 'Rejected',
      _ => titleCase(s['status']?.toString() ?? 'pending'),
    };
    s['statusIcon'] = switch (s['status']?.toString()) {
      'completed' => '&#x2713;',
      'running' => '&#x2022;',
      'failed' || 'rejected' => '&#x2717;',
      'awaiting_approval' => '&#x25CF;',
      'queued' => '&#x25CB;',
      _ => '&#x25CB;',
    };
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

  final body = templateLoader.trellis.render(templateLoader.source('workflow_detail'), {
    'sidebar': sidebar,
    'topbar': topbar,
    'bannerHtml': bannerHtml.isNotEmpty ? bannerHtml : null,
    'runId': run['id'],
    'definitionName': definitionName,
    'status': statusName,
    'statusLabel': workflowStatusLabel(runStatus),
    'statusBadgeClass': workflowStatusBadgeClass(runStatus),
    'startedAtDisplay': _formatTimeAgo(run['startedAt']),
    'updatedAtDisplay': _formatTimeAgo(run['updatedAt']),
    'hasCompletedAt': run['completedAt'] != null,
    'completedAtDisplay': run['completedAt'] != null ? _formatTimeAgo(run['completedAt']) : null,
    'totalTokens': formatNumber((run['totalTokens'] as num?)?.toInt() ?? 0),
    'durationDisplay': durationDisplay,
    // A pause banner already surfaces the errorMessage (approval hold or pause
    // reason); suppress the red error block so the same event isn't rendered
    // twice with contradictory severity.
    'hasError': run['errorMessage'] != null && pauseBanner == null,
    'errorMessage': run['errorMessage'],
    'progressPercent': progressPercent,
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
      'durationDisplay': durationDisplay ?? '--',
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

String _formatDuration(Object? startedAt, Object? completedAt) {
  if (startedAt == null) return '--';
  try {
    final start = startedAt is DateTime ? startedAt : DateTime.parse(startedAt.toString());
    final end = completedAt != null
        ? (completedAt is DateTime ? completedAt : DateTime.parse(completedAt.toString()))
        : null;
    return humanizeSpan(start, end, true);
  } catch (_) {
    return '--'; // Unparseable timestamp or null end time — fall back to placeholder.
  }
}
