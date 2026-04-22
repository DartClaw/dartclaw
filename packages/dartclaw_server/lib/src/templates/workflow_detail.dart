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
    'hasError': run['errorMessage'] != null,
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
  required List<Map<String, dynamic>> contextInputs,
  required List<Map<String, dynamic>> contextOutputs,
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
      'hasContextInputs': contextInputs.isNotEmpty,
      'contextInputs': contextInputs,
      'hasContextOutputs': contextOutputs.isNotEmpty,
      'contextOutputs': contextOutputs,
      'hasMetrics': hasTokens || hasDuration,
      'tokenCount': tokenCount != null ? formatNumber(tokenCount) : '0',
      'hasDuration': hasDuration,
      'durationDisplay': durationDisplay ?? '--',
    },
  );
}

String _formatTimeAgo(Object? value) {
  if (value == null) return '';
  try {
    final dt = value is DateTime ? value : DateTime.parse(value.toString());
    return formatRelativeTime(dt);
  } catch (_) {
    return value.toString();
  }
}

String _formatDuration(Object? startedAt, Object? completedAt) {
  if (startedAt == null) return '--';
  try {
    final start = startedAt is DateTime ? startedAt : DateTime.parse(startedAt.toString());
    final end = completedAt != null
        ? (completedAt is DateTime ? completedAt : DateTime.parse(completedAt.toString()))
        : DateTime.now();
    final diff = end.difference(start);
    if (diff.inHours > 0) {
      final mins = diff.inMinutes % 60;
      return '${diff.inHours}h ${mins}m';
    }
    if (diff.inMinutes > 0) {
      return '${diff.inMinutes}m';
    }
    return '${diff.inSeconds}s';
  } catch (_) {
    return '--';
  }
}
