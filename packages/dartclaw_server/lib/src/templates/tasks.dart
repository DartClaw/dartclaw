import 'layout.dart';
import 'loader.dart';
import 'sidebar.dart';
import 'task_form.dart';
import 'topbar.dart';

/// Renders the tasks page with filterable task list grouped by status.
String tasksPageTemplate({
  required SidebarData sidebarData,
  required List<NavItem> navItems,
  required List<Map<String, dynamic>> tasks,
  String? statusFilter,
  String? typeFilter,
  int reviewCount = 0,
  String bannerHtml = '',
  String appName = 'DartClaw',
  List<Map<String, dynamic>>? agentRunners,
  Map<String, dynamic>? agentPool,
  List<Map<String, String>> goalOptions = const [],
}) {
  final sidebar = buildSidebar(sidebarData: sidebarData, navItems: navItems, appName: appName);
  final topbar = pageTopbarTemplate(title: 'Tasks');
  const knownStatuses = [
    'draft',
    'queued',
    'running',
    'interrupted',
    'review',
    'accepted',
    'rejected',
    'cancelled',
    'failed',
  ];

  // Group tasks by status for sectioned display.
  final statusOrder = [
    'running',
    'review',
    'queued',
    'interrupted',
    'draft',
    'accepted',
    'rejected',
    'cancelled',
    'failed',
  ];
  final grouped = <String, List<Map<String, dynamic>>>{};
  for (final task in tasks) {
    final status = task['status']?.toString() ?? 'draft';
    (grouped[status] ??= []).add(task);
  }

  // Build status group data for template.
  final statusGroups = <Map<String, dynamic>>[];
  final orderedStatuses = [...statusOrder, ...grouped.keys.where((status) => !statusOrder.contains(status))];
  for (final status in orderedStatuses) {
    final groupTasks = grouped[status];
    if (groupTasks == null || groupTasks.isEmpty) continue;
    statusGroups.add({
      'status': status,
      'statusLabel': _titleCase(status),
      'count': groupTasks.length,
      'isRunning': status == 'running',
      'tasks': groupTasks.map((t) {
        final statusName = t['status']?.toString() ?? 'draft';
        return {
          ...t,
          'typeLabel': _titleCase(t['type']?.toString() ?? ''),
          'statusBadgeClass': 'status-badge-$statusName',
          'createdAtDisplay': _formatRelativeTime(t['createdAt']?.toString()),
          'detailHref': '/tasks/${t['id']}',
        };
      }).toList(),
    });
  }

  // Status filter options.
  final statusOptions = [
    {'value': '', 'label': 'All Statuses', 'selected': statusFilter == null || statusFilter.isEmpty},
    ...knownStatuses.map((s) => {'value': s, 'label': _titleCase(s), 'selected': statusFilter == s}),
  ];

  // Type filter options.
  final typeOptions = [
    {'value': '', 'label': 'All Types', 'selected': typeFilter == null || typeFilter.isEmpty},
    ...[
      'coding',
      'research',
      'writing',
      'analysis',
      'automation',
      'custom',
    ].map((t) => {'value': t, 'label': t[0].toUpperCase() + t.substring(1), 'selected': typeFilter == t}),
  ];

  // Agent overview section data.
  final hasAgentPool = agentRunners != null && agentPool != null;
  final isSingleRunner = hasAgentPool && (agentPool['maxConcurrentTasks'] as int? ?? 0) == 0;

  final body = templateLoader.trellis.render(templateLoader.source('tasks'), {
    'sidebar': sidebar,
    'topbar': topbar,
    'bannerHtml': bannerHtml.isNotEmpty ? bannerHtml : null,
    'hasTasks': tasks.isNotEmpty,
    'statusGroups': statusGroups,
    'statusOptions': statusOptions,
    'typeOptions': typeOptions,
    'reviewCount': reviewCount,
    'hasReviewBadge': reviewCount > 0,
    'newTaskDialogHtml': newTaskFormDialogHtml(goalOptions: goalOptions),
    'hasAgentPool': hasAgentPool,
    'isSingleRunner': isSingleRunner,
    'agentRunners': agentRunners,
    'agentPool': agentPool,
    'agentPoolBarHtml': hasAgentPool && !isSingleRunner ? _buildPoolBarHtml(agentPool) : null,
    'agentOverviewHtml': hasAgentPool ? _buildAgentOverviewHtml(agentRunners, agentPool, isSingleRunner) : null,
  });

  return layoutTemplate(title: 'Tasks', body: body, appName: appName);
}

String _titleCase(String value) {
  if (value.isEmpty) return value;
  return value[0].toUpperCase() + value.substring(1);
}

String _buildPoolBarHtml(Map<String, dynamic> pool) {
  final size = pool['size'] as int? ?? 1;
  final active = pool['activeCount'] as int? ?? 0;
  final activePercent = size > 0 ? (active / size * 100).round() : 0;
  final idlePercent = 100 - activePercent;
  return '<div class="agent-pool-bar">'
      '<div class="bar-segment bar-active" style="width:$activePercent%"></div>'
      '<div class="bar-segment bar-idle" style="width:$idlePercent%"></div>'
      '</div>'
      '<div class="agent-pool-label">$active/$size runners active</div>';
}

String _buildAgentOverviewHtml(List<Map<String, dynamic>>? runners, Map<String, dynamic> pool, bool isSingleRunner) {
  if (isSingleRunner) {
    return '<div class="agent-overview" id="agent-overview">'
        '<h3>Agent Pool</h3>'
        '<div class="empty-state-text">'
        'Single runner mode. Primary runner handles all sessions sequentially.<br>'
        '<small>Configure max_concurrent in tasks config to enable parallel execution.</small>'
        '</div>'
        '</div>';
  }

  final buf = StringBuffer()
    ..write('<div class="agent-overview" id="agent-overview">')
    ..write('<h3>Agent Pool</h3>')
    ..write(_buildPoolBarHtml(pool))
    ..write('<div class="agent-runner-cards">');

  for (final runner in runners ?? <Map<String, dynamic>>[]) {
    final runnerId = runner['runnerId'] as int? ?? 0;
    final role = runner['role']?.toString() ?? 'task';
    final state = runner['state']?.toString() ?? 'idle';
    final taskId = runner['currentTaskId']?.toString();
    final tokens = runner['tokensConsumed'] as int? ?? 0;
    final turns = runner['turnsCompleted'] as int? ?? 0;
    final errors = runner['errorCount'] as int? ?? 0;
    final label = role == 'primary' ? 'Primary (#$runnerId)' : 'Runner #$runnerId';

    buf
      ..write('<div class="card agent-runner-card" data-runner-id="$runnerId">')
      ..write('<div class="runner-label">$label</div>')
      ..write('<span class="status-badge agent-state-$state">${_titleCase(state)}</span>');

    if (state == 'busy' && taskId != null) {
      buf.write('<div class="runner-metric"><a href="/tasks/$taskId">Task: ${_truncateId(taskId)}</a></div>');
    }

    buf
      ..write('<div class="runner-metric">$turns turns</div>')
      ..write('<div class="runner-metric">${_formatTokens(tokens)} tokens</div>');
    if (errors > 0) {
      buf.write('<div class="runner-metric runner-metric-error">$errors error${errors == 1 ? '' : 's'}</div>');
    }

    buf.write('</div>');
  }

  buf
    ..write('</div>')
    ..write('</div>');
  return buf.toString();
}

String _formatTokens(int tokens) {
  if (tokens >= 1000000) return '${(tokens / 1000000).toStringAsFixed(1)}M';
  if (tokens >= 1000) return '${(tokens / 1000).toStringAsFixed(1)}K';
  return tokens.toString();
}

String _truncateId(String id) {
  return id.length > 8 ? '${id.substring(0, 8)}...' : id;
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
  } catch (_) {
    return '';
  }
}
