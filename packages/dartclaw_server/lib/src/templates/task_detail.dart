import 'layout.dart';
import 'loader.dart';
import 'sidebar.dart';
import 'topbar.dart';

/// Renders the task detail page with embedded chat view, artifacts, and review controls.
String taskDetailPageTemplate({
  required SidebarData sidebarData,
  required List<NavItem> navItems,
  required Map<String, dynamic> task,
  required List<Map<String, dynamic>> artifacts,
  Map<String, dynamic>? conflictData,
  String? messagesHtml,
  String bannerHtml = '',
  String appName = 'DartClaw',
}) {
  final sidebar = buildSidebar(sidebarData: sidebarData, navItems: navItems, appName: appName);
  final title = task['title']?.toString() ?? 'Task';
  final topbar = pageTopbarTemplate(title: 'Task: $title', backHref: '/tasks', backLabel: 'Back to Tasks');
  final statusName = task['status']?.toString() ?? 'draft';
  final isDraft = statusName == 'draft';
  final isQueued = statusName == 'queued';
  final isReview = statusName == 'review';
  final isRunning = statusName == 'running';
  final isInterrupted = statusName == 'interrupted';
  final isCancellable = switch (statusName) {
    'draft' || 'queued' || 'running' || 'interrupted' => true,
    _ => false,
  };
  final hasSession = task['sessionId'] != null && (task['sessionId'] as String).isNotEmpty;
  final pushBackCount = (task['pushBackCount'] as num?)?.toInt() ?? 0;
  final showPushBackWarning = pushBackCount >= 3;
  final conflictingFiles =
      (conflictData?['conflictingFiles'] as List?)?.map((entry) => entry.toString()).toList(growable: false) ??
      const <String>[];
  final conflictDetails = conflictData?['details']?.toString();
  final noSessionTitle = switch (statusName) {
    'queued' => 'Task queued',
    'running' => 'Session starting',
    'interrupted' => 'Task interrupted',
    _ => 'Session not started',
  };
  final noSessionText = switch (statusName) {
    'queued' => 'Waiting for an available runner. Session messages will appear automatically.',
    'running' => 'The task is starting up. Session messages will appear automatically.',
    'interrupted' => 'The previous run stopped unexpectedly. You can cancel or re-queue this task.',
    _ => 'This task has not been started yet. No session messages to display.',
  };

  // Build artifact items for template.
  final artifactItems = artifacts.map((a) {
    final kind = a['kind']?.toString() ?? 'data';
    return {
      ...a,
      'kindLabel': kind[0].toUpperCase() + kind.substring(1),
      'isDiff': kind == 'diff',
      'isDocument': kind == 'document',
      'isData': kind == 'data',
      'content': a['content']?.toString(),
      'hasContent': a['content'] != null && (a['content'] as String).isNotEmpty,
      'renderedHtml': a['renderedHtml']?.toString(),
      'hasRenderedHtml': a['renderedHtml'] != null && (a['renderedHtml'] as String).isNotEmpty,
    };
  }).toList();

  final body = templateLoader.trellis.render(templateLoader.source('task_detail'), {
    'sidebar': sidebar,
    'topbar': topbar,
    'bannerHtml': bannerHtml.isNotEmpty ? bannerHtml : null,
    'taskId': task['id'],
    'title': title,
    'typeLabel': _titleCase(task['type']?.toString() ?? ''),
    'status': statusName,
    'statusLabel': _titleCase(statusName),
    'statusBadgeClass': 'status-badge-$statusName',
    'goalTitle': task['goalTitle']?.toString(),
    'description': task['description']?.toString() ?? '',
    'acceptanceCriteria': task['acceptanceCriteria']?.toString(),
    'pushBackCount': pushBackCount,
    'hasPushBacks': pushBackCount > 0,
    'showPushBackWarning': showPushBackWarning,
    'createdAtDisplay': _formatRelativeTime(task['createdAt']?.toString()),
    'createdByDisplay': task['createdBy']?.toString() ?? '—',
    'startedAtDisplay': _formatRelativeTime(task['startedAt']?.toString()),
    'completedAtDisplay': _formatRelativeTime(task['completedAt']?.toString()),
    'startedAtIso': task['startedAt']?.toString(),
    'hasStartedAt': task['startedAt'] != null,
    'hasCompletedAt': task['completedAt'] != null,
    'isDraft': isDraft,
    'isQueued': isQueued,
    'isReview': isReview,
    'isRunning': isRunning,
    'isInterrupted': isInterrupted,
    'isCancellable': isCancellable,
    'hasSession': hasSession,
    'messagesHtml': messagesHtml,
    'noSessionTitle': noSessionTitle,
    'noSessionText': noSessionText,
    'hasArtifacts': artifactItems.isNotEmpty,
    'artifacts': artifactItems,
    'hasConflict': conflictingFiles.isNotEmpty,
    'conflictingFiles': conflictingFiles,
    'conflictDetails': conflictDetails,
  });

  return layoutTemplate(title: 'Task: $title', body: body, appName: appName);
}

String _titleCase(String value) {
  if (value.isEmpty) return value;
  return value[0].toUpperCase() + value.substring(1);
}

String _formatRelativeTime(String? iso) {
  if (iso == null) return '';
  try {
    final dt = DateTime.parse(iso);
    final diff = DateTime.now().difference(dt);
    if (diff.inDays > 0) return '${diff.inDays}d ago';
    if (diff.inHours > 0) return '${diff.inHours}h ago';
    if (diff.inMinutes > 0) return '${diff.inMinutes}m ago';
    return 'just now';
  } catch (e) {
    return '';
  }
}
