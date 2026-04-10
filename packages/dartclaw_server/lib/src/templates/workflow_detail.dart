import 'helpers.dart';
import 'layout.dart';
import 'loader.dart';
import 'sidebar.dart';
import 'topbar.dart';

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
    backHref: '/tasks',
    backLabel: 'Back to Tasks',
  );
  final statusName = run['status']?.toString() ?? 'pending';

  // Compute progress.
  final totalSteps = steps.length;
  final completedSteps = steps.where((s) => s['status'] == 'completed').length;
  final progressPercent = totalSteps > 0 ? (completedSteps * 100 ~/ totalSteps) : 0;

  // Determine which actions are available.
  final isApprovalPaused = run['isApprovalPaused'] == true;
  final canPause = statusName == 'running';
  final canResume = statusName == 'paused';
  final canCancel = statusName == 'running' || statusName == 'paused';
  // Approval-paused runs show Approve/Reject instead of generic Resume/Cancel.
  final canApprove = isApprovalPaused;
  final canReject = isApprovalPaused;

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
    s['typeLabel'] = s['type']?.toString() ?? '';
    s['isParallel'] = s['parallel'] == true;
    return s;
  }).toList();

  final body = templateLoader.trellis.render(
    templateLoader.source('workflow_detail'),
    {
      'sidebar': sidebar,
      'topbar': topbar,
      'bannerHtml': bannerHtml.isNotEmpty ? bannerHtml : null,
      'runId': run['id'],
      'definitionName': definitionName,
      'status': statusName,
      'statusLabel': titleCase(statusName),
      'statusBadgeClass': 'status-badge-$statusName',
      'startedAtDisplay': _formatTimeAgo(run['startedAt']),
      'updatedAtDisplay': _formatTimeAgo(run['updatedAt']),
      'hasCompletedAt': run['completedAt'] != null,
      'completedAtDisplay': run['completedAt'] != null ? _formatTimeAgo(run['completedAt']) : null,
      'totalTokens': formatNumber((run['totalTokens'] as num?)?.toInt() ?? 0),
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
      'canResume': canResume && !isApprovalPaused,
      'canCancel': canCancel && !isApprovalPaused,
      'isApprovalPaused': isApprovalPaused,
      'canApprove': canApprove,
      'canReject': canReject,
    },
  );

  return layoutTemplate(
    title: 'Workflow: $definitionName',
    body: body,
    appName: appName,
  );
}

/// Renders the step detail partial fragment for a workflow step.
String workflowStepDetailFragment({
  required String? messagesHtml,
  required List<Map<String, dynamic>> artifacts,
  required List<Map<String, dynamic>> contextInputs,
  required List<Map<String, dynamic>> contextOutputs,
  int? tokenCount,
}) {
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
      'hasMetrics': tokenCount != null && tokenCount > 0,
      'tokenCount': tokenCount != null ? formatNumber(tokenCount) : '0',
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
