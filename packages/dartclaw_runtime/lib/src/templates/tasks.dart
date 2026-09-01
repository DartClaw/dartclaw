import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show TaskEvent, TaskEventKind;
import 'package:dartclaw_core/dartclaw_core.dart' show TaskEventService;

import '../task/tool_call_summary.dart';
import '../task/task_progress_tracker.dart';
import 'components.dart';
import 'helpers.dart';
import 'layout.dart';
import 'loader.dart';
import 'sidebar.dart';
import 'task_event_display.dart';
import 'task_status_display.dart';
import 'topbar.dart';
import 'workflow_list.dart';

String taskCreateDialogFragment({
  required List<Map<String, String>> goalOptions,
  required List<Map<String, String>> projectOptions,
  required List<Map<String, dynamic>> workflowDefinitions,
}) {
  return templateLoader.trellis.renderFragment(
    templateLoader.source('tasks'),
    fragment: 'taskCreateDialog',
    context: {
      'taskPanelHtml': taskCreatePanelFragment(goalOptions: goalOptions, projectOptions: projectOptions),
      'workflowDefinitionsHtml': workflowDefinitionsFragment(
        definitions: workflowDefinitions,
        projectOptions: [
          for (final project in projectOptions.where((project) => project['value'] != '_local'))
            {'value': project['value'], 'label': project['label']},
        ],
      ),
    },
  );
}

String taskCreatePanelFragment({
  required List<Map<String, String>> goalOptions,
  required List<Map<String, String>> projectOptions,
  Map<String, Object?> values = const {},
  String? errorField,
  String? errorMessage,
}) {
  final externalProjects = projectOptions.where((project) => project['value'] != '_local').toList();
  return templateLoader.trellis.renderFragment(
    templateLoader.source('tasks'),
    fragment: 'taskCreatePanel',
    context: {
      'values': values,
      'goalOptions': [
        {'value': '', 'label': 'No goal', 'selected': _formValue(values, 'goalId').isEmpty},
        ...goalOptions.map(
          (goal) => {
            'value': goal['value'] ?? '',
            'label': goal['label'] ?? goal['value'] ?? 'Goal',
            'selected': _formValue(values, 'goalId') == goal['value'],
          },
        ),
      ],
      'hasProjects': externalProjects.isNotEmpty,
      'projectOptions': projectOptions.map((project) {
        final status = project['status'] ?? 'ready';
        final label = project['label'] ?? '';
        final suffix = switch (status) {
          'ready' => ' ✓',
          'cloning' => ' (cloning)',
          'error' => ' (error)',
          'stale' => ' ⚠',
          _ => '',
        };
        return {
          'value': project['value'] ?? '',
          'label': '$label$suffix',
          'selected': _formValue(values, 'projectId').isEmpty
              ? project['isDefault'] == 'true'
              : _formValue(values, 'projectId') == project['value'],
          'disabled': status != 'ready',
        };
      }).toList(),
      'toolOptions': [
        for (final tool in const {
          'shell': 'Shell',
          'file_read': 'File Read',
          'file_write': 'File Write',
          'file_edit': 'File Edit',
          'web_fetch': 'Web Fetch',
          'web_search': 'Web Search',
          'mcp_call': 'MCP Call',
        }.entries)
          {
            'value': tool.key,
            'label': tool.value,
            'checked': (values['allowedTools'] as List? ?? const []).contains(tool.key),
          },
      ],
      'reviewOptions': [
        {'value': '', 'label': 'Default', 'selected': _formValue(values, 'reviewMode').isEmpty},
        for (final mode in const ['auto-accept', 'mandatory', 'worktree-only'])
          {'value': mode, 'label': titleCase(mode), 'selected': _formValue(values, 'reviewMode') == mode},
      ],
      'titleInvalid': errorField == 'title',
      'descriptionInvalid': errorField == 'description',
      'projectInvalid': errorField == 'projectId',
      'tokenBudgetInvalid': errorField == 'tokenBudget',
      'formInvalid':
          errorMessage != null && !const {'title', 'description', 'projectId', 'tokenBudget'}.contains(errorField),
      'errorMessage': errorMessage,
    },
  );
}

String _formValue(Map<String, Object?> values, String key) => values[key]?.toString() ?? '';

/// Renders the tasks page with filterable task list grouped by status.
String tasksPageTemplate({
  required SidebarData sidebarData,
  required List<NavItem> navItems,
  required List<Map<String, dynamic>> tasks,
  String? statusFilter,
  int reviewCount = 0,
  String restartBannerHtml = '',
  String appName = 'DartClaw',
  List<Map<String, dynamic>>? runners,
  Map<String, dynamic>? executionCapacity,
  String defaultProvider = 'claude',
  Map<String, String> projectNames = const {},
  bool showProjectColumn = false,
  TaskProgressTracker? progressTracker,
  TaskEventService? taskEventService,
  bool showWorkflowReviewToggle = false,
  bool includeWorkflowOwned = false,
  String workflowReviewToggleHref = '/tasks?status=review&include=workflow',
  String activeListQuery = '',
}) {
  final sidebar = buildSidebar(sidebarData: sidebarData, navItems: navItems, appName: appName);
  final topbar = pageTopbarTemplate(title: 'Tasks', restartBannerHtml: restartBannerHtml);
  final normalizedDefaultProvider = ProviderIdentity.normalize(defaultProvider);
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
    (grouped[taskStatusKey(task['status'])] ??= []).add(task);
  }

  // Build status group data for template.
  final statusGroups = <Map<String, dynamic>>[];
  final orderedStatuses = [...statusOrder, ...grouped.keys.where((status) => !statusOrder.contains(status))];
  for (final status in orderedStatuses) {
    final groupTasks = grouped[status];
    if (groupTasks == null || groupTasks.isEmpty) continue;
    final isRunningGroup = status == 'running';
    statusGroups.add({
      'status': status,
      'statusLabel': taskStatusPresentations[status]!.label,
      'count': groupTasks.length,
      'isRunning': isRunningGroup,
      'tasks': groupTasks.map((t) {
        final presentation = taskStatusPresentation(t['status']);
        final provider = ProviderIdentity.normalize(t['provider']?.toString(), fallback: normalizedDefaultProvider);
        final projectId = t['projectId']?.toString();
        final projectName = projectId != null && projectId != '_local' ? projectNames[projectId] : null;
        final taskId = t['id']?.toString() ?? '';

        // Running task enhancements: runner badge, progress, token display, recent events.
        String? runnerLabel;
        int progressPct = 0;
        bool isIndeterminate = true;
        String tokenDisplay = '0 tokens';
        List<Map<String, dynamic>> recentEvents = const [];
        bool hasEvents = false;
        String? finalTokenDisplay;

        if (isRunningGroup) {
          // Runner assignment lookup.
          if (runners != null) {
            for (final runner in runners) {
              if (runner['currentTaskId']?.toString() == taskId) {
                final runnerId = runner['runnerId'] as int? ?? 0;
                final role = runner['role']?.toString() ?? 'worker';
                runnerLabel = role == 'primary' ? 'Primary (#$runnerId)' : 'Worker #$runnerId';
                break;
              }
            }
          }
          // Progress state.
          final snapshot = progressTracker?.currentSnapshot(taskId);
          if (snapshot != null) {
            final pct = snapshot.progress;
            if (pct != null) {
              progressPct = pct;
              isIndeterminate = false;
              tokenDisplay =
                  '${_formatTokens(snapshot.tokensUsed)} / '
                  '${_formatTokens(snapshot.tokenBudget ?? 0)} tokens ($pct%)';
            } else {
              tokenDisplay = '${_formatTokens(snapshot.tokensUsed)} tokens';
            }
          }
          // Recent events (last 3, most recent first).
          // listForTask returns ASC; take last 3 in reverse for most-recent-first.
          final allEvents = taskEventService?.listForTask(taskId) ?? const <TaskEvent>[];
          final recentSlice = allEvents.length > 3 ? allEvents.sublist(allEvents.length - 3) : allEvents;
          recentEvents = recentSlice.reversed.map(_buildCompactEventViewModel).toList();
          hasEvents = recentEvents.isNotEmpty;
        } else {
          // Non-running: compute final token total from tokenUpdate events.
          final tokenEvents =
              taskEventService?.listForTask(taskId, kind: TaskEventKind.tokenUpdate) ?? const <TaskEvent>[];
          int total = 0;
          for (final e in tokenEvents) {
            total +=
                ((e.details['inputTokens'] as num?)?.toInt() ?? 0) +
                ((e.details['outputTokens'] as num?)?.toInt() ?? 0);
          }
          finalTokenDisplay = total > 0 ? _formatTokens(total) : null;
        }

        return {
          ...t,
          'provider': provider,
          'providerLabel': ProviderIdentity.displayName(provider),
          'statusPillHtml': statusPillTemplate(
            variant: presentation.pill,
            text: presentation.label,
            dot: presentation.dot,
          ),
          'cardTintClass': switch (taskStatusKey(t['status'])) {
            'running' => 'card-tint-accent',
            'queued' || 'draft' => 'card-tint-info',
            'failed' || 'cancelled' => 'card-tint-error',
            'review' || 'interrupted' => 'card-tint-warning',
            _ => '',
          },
          'createdAtDisplay': formatRelativeTimeIso(t['createdAt']?.toString()),
          'createdAtIso': isoTitle(t['createdAt']?.toString()),
          'createdByDisplay': absentValue(t['createdBy']?.toString()).value,
          'createdByAbsent': absentValue(t['createdBy']?.toString()).isAbsent,
          'detailHref': '/tasks/${t['id']}${activeListQuery.isEmpty ? '' : '?$activeListQuery'}',
          'projectName': projectName,
          'projectDisplay': absentValue(projectName).value,
          'projectAbsent': absentValue(projectName).isAbsent,
          'runnerLabel': runnerLabel,
          'progressPct': progressPct,
          'isIndeterminate': isIndeterminate,
          'tokenDisplay': tokenDisplay,
          'recentEvents': recentEvents,
          'hasEvents': hasEvents,
          'finalTokenDisplay': finalTokenDisplay,
        };
      }).toList(),
    });
  }

  // Status filter options.
  final statusOptions = [
    {'value': '', 'label': 'All Statuses', 'selected': statusFilter == null || statusFilter.isEmpty},
    ...knownStatuses.map((s) => {'value': s, 'label': titleCase(s), 'selected': statusFilter == s}),
  ];

  final hasExecutionCapacity = runners != null && executionCapacity != null;
  final isPrimaryOnly = hasExecutionCapacity && (executionCapacity['configured'] as int? ?? 0) == 0;

  final body = templateLoader.trellis.renderFragment(
    templateLoader.source('tasks'),
    fragment: 'tasks',
    context: {
      'sidebar': sidebar,
      'topbar': topbar,
      'pageHeaderHtml': pageHeaderTemplate(
        subtitle: 'Agent work items, grouped by lifecycle status.',
        actionsHtml:
            '<button class="btn btn-primary" type="button" hx-get="/tasks/new" '
            'hx-target="#new-task-dialog-host" hx-swap="innerHTML" data-icon="plus">New Task</button>',
      ),
      'emptyStateHtml': emptyStateTemplate(
        title: 'No tasks yet',
        body: 'Create a task to hand a piece of work to an agent.',
        actionHtml:
            '<button class="btn btn-primary" type="button" hx-get="/tasks/new" '
            'hx-target="#new-task-dialog-host" hx-swap="innerHTML" data-icon="plus">New Task</button>',
      ),
      'hasTasks': tasks.isNotEmpty,
      'statusGroups': statusGroups,
      'statusOptions': statusOptions,
      'includeFilter': includeWorkflowOwned ? 'workflow' : null,
      'reviewCount': reviewCount,
      'hasReviewBadge': reviewCount > 0,
      'showWorkflowReviewToggle': showWorkflowReviewToggle,
      'includeWorkflowOwned': includeWorkflowOwned,
      'workflowReviewToggleHref': workflowReviewToggleHref,
      'hasExecutionCapacity': hasExecutionCapacity,
      'isPrimaryOnly': isPrimaryOnly,
      'runners': runners,
      'executionCapacity': executionCapacity,
      'executionCapacityBarHtml': hasExecutionCapacity && !isPrimaryOnly
          ? _buildCapacityBarHtml(executionCapacity)
          : null,
      'executionOverviewHtml': hasExecutionCapacity
          ? _buildExecutionOverviewHtml(
              runners,
              executionCapacity,
              isPrimaryOnly,
              defaultProvider: normalizedDefaultProvider,
            )
          : null,
      'showProjectColumn': showProjectColumn,
    },
  );

  return layoutTemplate(title: 'Tasks', body: body, appName: appName, scripts: standardShellScripts());
}

String _classSuffix(String value) {
  final sanitized = value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]'), '-');
  return sanitized.isEmpty ? 'claude' : sanitized;
}

String _buildCapacityBarHtml(Map<String, dynamic> capacity) {
  final size = capacity['effective'] as int? ?? 0;
  final active = capacity['active'] as int? ?? 0;
  final activePercent = size > 0 ? (active / size * 100).round() : 0;
  // A full-strength track at 0% reads as a solid rule asserting a measurement,
  // so nothing-active takes canon's unfilled treatment.
  final emptyClass = active == 0 ? ' meter--empty' : '';
  return '<div class="meter-label"><span>$active/$size workers active</span></div>'
      '<div class="meter$emptyClass" role="progressbar" aria-valuemin="0" aria-valuemax="100" '
      'aria-valuenow="$activePercent" aria-label="Workers active">'
      '<div class="meter-fill" style="width:$activePercent%"></div>'
      '</div>';
}

/// Runner lifecycle state to its canon dot and pill variants. Every runner state
/// reads from a glyph as well as a colour.
({String dot, String pill}) _runnerStatePresentation(String state) {
  return switch (state) {
    'busy' => (dot: 'live', pill: 'live'),
    'stopped' => (dot: 'warning', pill: 'warning'),
    'crashed' => (dot: 'error', pill: 'error'),
    _ => (dot: 'idle', pill: 'info'),
  };
}

String _buildExecutionOverviewHtml(
  List<Map<String, dynamic>>? runners,
  Map<String, dynamic> capacity,
  bool isPrimaryOnly, {
  String defaultProvider = 'claude',
}) {
  if (isPrimaryOnly) {
    return '<div class="execution-overview" id="execution-overview">'
        '<h2 class="t-heading">Execution Capacity</h2>'
        '<div class="text-muted">'
        'Primary-only mode. Interactive execution is serialized.<br>'
        '<small>Configure providers.&lt;id&gt;.pool_size to enable worker execution.</small>'
        '</div>'
        '</div>';
  }

  final buf = StringBuffer()
    ..write('<div class="execution-overview" id="execution-overview">')
    ..write('<h2 class="t-heading">Execution Capacity</h2>')
    ..write(_buildCapacityBarHtml(capacity))
    ..write(_buildCapacityDetailsHtml(capacity))
    ..write('<div class="execution-runners">');

  for (final runner in runners ?? <Map<String, dynamic>>[]) {
    final runnerId = runner['runnerId'] as int? ?? 0;
    final role = runner['role']?.toString() ?? 'worker';
    final state = runner['state']?.toString() ?? 'idle';
    final taskId = runner['currentTaskId']?.toString();
    final providerId = ProviderIdentity.normalize(runner['providerId']?.toString(), fallback: defaultProvider);
    final providerLabel = ProviderIdentity.displayName(providerId);
    final tokens = runner['tokensConsumed'] as int? ?? 0;
    final turns = runner['turnsCompleted'] as int? ?? 0;
    final errors = runner['errorCount'] as int? ?? 0;
    final label = role == 'primary' ? 'Primary (#$runnerId)' : 'Worker #$runnerId';
    final presentation = _runnerStatePresentation(state);

    buf
      ..write('<div class="card run-card" data-runner-id="$runnerId">')
      ..write('<div class="card-header card-header--sm">')
      ..write('<span class="status-dot status-dot--${presentation.dot}" aria-hidden="true"></span>')
      ..write('<span class="runner-label">${escapeHtml(label)}</span>')
      ..write('</div>')
      ..write('<div class="card-body run-card-metrics">');

    if (state == 'busy' && taskId != null) {
      final escapedTaskId = escapeHtml(taskId);
      buf.write('<div><a href="/tasks/$escapedTaskId">Task: ${escapeHtml(_truncateId(taskId))}</a></div>');
    }

    buf
      ..write('<div>$turns turns</div>')
      ..write('<div>${_formatTokens(tokens)} tokens</div>');
    if (errors > 0) {
      buf.write('<div class="text-error">$errors error${errors == 1 ? '' : 's'}</div>');
    }

    buf
      ..write('</div>')
      ..write('<div class="card-footer">')
      ..write(
        '<span class="provider-badge provider-badge-${_classSuffix(providerId)}">'
        '${escapeHtml(providerLabel)}</span>',
      )
      ..write('<span class="status-pill status-pill--${presentation.pill}">${titleCase(state)}</span>')
      ..write('</div>')
      ..write('</div>');
  }

  buf
    ..write('</div>')
    ..write('</div>');
  return buf.toString();
}

String _buildCapacityDetailsHtml(Map<String, dynamic> capacity) {
  final queued = capacity['queued'] as int? ?? 0;
  final cached = capacity['cached'] as int? ?? 0;
  final quarantined = capacity['quarantined'] as int? ?? 0;
  return '<div class="text-muted"><small>'
      '$queued queued · $cached warm · $quarantined quarantined'
      '</small></div>';
}

String _formatTokens(int tokens) {
  if (tokens >= 1000000) return '${(tokens / 1000000).toStringAsFixed(1)}M';
  if (tokens >= 1000) return '${(tokens / 1000).toStringAsFixed(1)}K';
  return tokens.toString();
}

String _truncateId(String id) {
  return id.length > 8 ? '${id.substring(0, 8)}...' : id;
}

/// A status-change event with no recorded target status still happened, so it
/// says so rather than naming an unknown destination.
String _statusChangedText(Object? newStatus) {
  final status = absentValue(newStatus);
  return status.isAbsent ? 'Status changed' : 'Status \u2192 ${status.value}';
}

/// Builds a compact event view-model for dashboard preview.
Map<String, dynamic> _buildCompactEventViewModel(TaskEvent event) {
  final kind = event.kind;
  final details = event.details;
  final text = switch (kind) {
    TaskEventKind.statusChanged => truncate(_statusChangedText(details['newStatus']), 80),
    TaskEventKind.toolCalled => formatToolEventText(
      details['name']?.toString() ?? '(tool)',
      context: details['context']?.toString(),
      maxLength: 80,
    ),
    TaskEventKind.artifactCreated => truncate(details['name']?.toString() ?? '(artifact)', 80),
    TaskEventKind.structuredOutputFinalizerUsed => truncate(
      'Structured envelope: ${details['outputKey']?.toString() ?? '(output)'}',
      80,
    ),
    TaskEventKind.structuredOutputInlineUsed => truncate(
      'Structured inline: ${details['outputKey']?.toString() ?? '(output)'}',
      80,
    ),
    TaskEventKind.structuredOutputFallbackUsed => truncate(
      'Structured fallback: ${details['outputKey']?.toString() ?? '(output)'}',
      80,
    ),
    TaskEventKind.structuredOutputValidationFailed => truncate(
      'Structured validation failed: ${details['outputKey']?.toString() ?? '(output)'}',
      80,
    ),
    TaskEventKind.pushBack => truncate(details['comment']?.toString() ?? 'Push-back', 80),
    TaskEventKind.tokenUpdate => () {
      final input = (details['inputTokens'] as num?)?.toInt() ?? 0;
      final output = (details['outputTokens'] as num?)?.toInt() ?? 0;
      return '${_formatTokens(input + output)} tokens';
    }(),
    TaskEventKind.taskError => truncate(details['message']?.toString() ?? 'Error', 80),
    TaskEventKind.compaction => truncate('Compaction (trigger: ${details['trigger'] ?? 'auto'})', 80),
  };
  // The compact path carries both: the colour class it always had, plus the mask
  // class the timeline already used. `eventIconClass` has no newStatus here, so
  // statusChanged resolves through its default — the same glyph both paths show.
  return {'iconClass': compactEventIconClass(kind), 'maskClass': eventIconClass(kind), 'text': text};
}
