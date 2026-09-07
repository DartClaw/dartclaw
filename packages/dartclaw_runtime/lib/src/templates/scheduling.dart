import 'dart:convert';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import '../scheduling/cron_parser.dart';
import '../scheduling/pending_schedule_change.dart';
import 'components.dart';
import 'helpers.dart';
import 'layout.dart';
import 'loader.dart';
import 'sidebar.dart';
import 'topbar.dart';

typedef JobFormValues = ({String name, String schedule, String at, String prompt, String delivery});
typedef TaskFormValues = ({
  String id,
  String schedule,
  String title,
  String description,
  String acceptanceCriteria,
  bool enabled,
});

const emptyJobFormValues = (name: '', schedule: '', at: '', prompt: '', delivery: 'announce');
const emptyTaskFormValues = (id: '', schedule: '', title: '', description: '', acceptanceCriteria: '', enabled: true);

String schedulingTemplate({
  required SidebarData sidebarData,
  required List<NavItem> navItems,
  bool heartbeatEnabled = false,
  int heartbeatIntervalMinutes = 30,
  List<Map<String, dynamic>> jobs = const [],
  List<String> systemJobNames = const [],
  List<ScheduledTaskDefinition> scheduledTasks = const [],
  List<PendingScheduleChange> pendingChanges = const [],
  String restartBannerHtml = '',
  String appName = 'DartClaw',
}) {
  final body = templateLoader.trellis.renderFragment(
    templateLoader.source('scheduling'),
    fragment: 'scheduling',
    context: {
      'sidebar': buildSidebar(sidebarData: sidebarData, navItems: navItems, appName: appName),
      'topbar': pageTopbarTemplate(title: 'Scheduling Status', restartBannerHtml: restartBannerHtml),
      'contentHtml': schedulingContentFragment(
        heartbeatEnabled: heartbeatEnabled,
        heartbeatIntervalMinutes: heartbeatIntervalMinutes,
        jobs: jobs,
        systemJobNames: systemJobNames,
        scheduledTasks: scheduledTasks,
        pendingChanges: pendingChanges,
      ),
    },
  );
  return layoutTemplate(title: 'Scheduling', body: body, appName: appName, scripts: standardShellScripts());
}

String schedulingContentFragment({
  required bool heartbeatEnabled,
  required int heartbeatIntervalMinutes,
  required List<Map<String, dynamic>> jobs,
  required List<String> systemJobNames,
  required List<ScheduledTaskDefinition> scheduledTasks,
  List<PendingScheduleChange> pendingChanges = const [],
}) => templateLoader.trellis.renderFragment(
  templateLoader.source('scheduling'),
  fragment: 'schedulingContent',
  context: {
    'pageHeaderHtml': pageHeaderTemplate(
      subtitle: 'Recurring jobs and scheduled tasks, plus the heartbeat that drives them.',
    ),
    'pulseClass': heartbeatEnabled ? '' : 'paused',
    'heartbeatBadgeHtml': statusBadgeTemplate(
      variant: heartbeatEnabled ? 'success' : 'muted',
      text: heartbeatEnabled ? 'Active' : 'Disabled',
    ),
    'hasHeartbeatMetrics': heartbeatEnabled,
    'heartbeatMetricCardsHtml': heartbeatEnabled
        ? metricCardTemplate(color: 'info', value: '$heartbeatIntervalMinutes', label: 'Interval (min)')
        : null,
    'heartbeatOn': heartbeatEnabled,
    'jobFormHtml': schedulingJobFormFragment(),
    'jobsTableHtml': schedulingJobsFragment(jobs: jobs, systemJobNames: systemJobNames),
    'pendingChangesHtml': schedulingPendingChangesFragment(changes: pendingChanges),
    'taskFormHtml': schedulingTaskFormFragment(),
    'tasksTableHtml': schedulingTasksFragment(tasks: scheduledTasks),
  },
);

String schedulingJobsFragment({
  required List<Map<String, dynamic>> jobs,
  required List<String> systemJobNames,
  bool outOfBand = false,
}) {
  final rows = jobs.where((job) => job['type']?.toString() != 'task').map((job) {
    final name = (job['name'] ?? job['id'])?.toString() ?? '';
    final status = job['status']?.toString() ?? 'active';
    final system = systemJobNames.contains(name);
    // A shell job is file-only: it runs on demand like any other row, but it is
    // written and removed by editing dartclaw.yaml, so the seam would refuse an
    // Edit or Delete posted from here.
    final shell = job['jobType']?.toString() == 'shell';
    final canRun = !system || job['runnable'] == true;
    final running = status == 'running';
    final schedule = job['schedule']?.toString() ?? '';
    return <String, dynamic>{
      'name': name,
      'schedule': schedule,
      'delivery': job['delivery']?.toString() ?? 'none',
      'status': status,
      'deliveryBadgeClass': switch (job['delivery']?.toString()) {
        'announce' => 'announce',
        'webhook' => 'webhook',
        _ => '',
      },
      'statusDotClass': switch (status) {
        'active' || 'running' => 'status-dot--live',
        'succeeded' => 'status-dot--success',
        'conflicted' => 'status-dot--attention',
        'error' || 'failed' => 'status-dot--error',
        'unknown' => 'status-dot--warning',
        _ => 'status-dot--idle',
      },
      'rowClass': system ? 'row-system' : (status == 'error' || status == 'failed' ? 'row-error' : ''),
      'isSystem': system,
      'isShell': shell,
      'canEdit': !system && !shell,
      'canStart': canRun && !running,
      'runDisabled': canRun && running,
      'hasActions': !system || canRun,
      'cronHuman': _describe(schedule),
      'editUrl': '/scheduling/jobs/${Uri.encodeComponent(name)}/form',
      'runUrl': '/scheduling/jobs/${Uri.encodeComponent(name)}/run',
      'deleteUrl': '/scheduling/jobs/${Uri.encodeComponent(name)}/delete',
      'deleteMessage': "Delete '$name'?",
    };
  }).toList();
  return templateLoader.trellis.renderFragment(
    templateLoader.source('scheduling'),
    fragment: 'jobsTable',
    context: {
      'hasJobs': rows.isNotEmpty,
      'jobs': rows,
      'outOfBand': outOfBand ? 'true' : null,
      'emptyStateHtml': emptyStateTemplate(
        title: 'No scheduled jobs',
        body: 'Add a job to have the agent run a prompt on a cron schedule.',
      ),
    },
  );
}

/// The parked `schedule_upsert` writes awaiting an operator.
///
/// Every value but the change id and timestamp came from a model turn, so each
/// reaches the markup through `tl:text` / `tl:attr` only. The root renders even
/// when empty — hidden — so a settle response has a target to swap.
String schedulingPendingChangesFragment({required List<PendingScheduleChange> changes}) {
  final rows = changes
      .map(
        (change) => <String, dynamic>{
          'jobId': change.jobId,
          'summary': _pendingSummary(change.job),
          'details': _pendingDetails(change.job),
          'kind': change.kind.name,
          'schedule': _pendingScheduleText(change.job['schedule']),
          'requester': change.requester,
          'requestedAt': formatRelativeTime(change.requestedAt),
          'requestedAtIso': change.requestedAt.toUtc().toIso8601String(),
          'approveUrl': '/scheduling/pending/${Uri.encodeComponent(change.changeId)}/approve',
          'rejectUrl': '/scheduling/pending/${Uri.encodeComponent(change.changeId)}/reject',
          'rejectMessage': "Reject the pending change to '${change.jobId}'?",
        },
      )
      .toList();
  return templateLoader.trellis.renderFragment(
    templateLoader.source('scheduling'),
    fragment: 'pendingChanges',
    context: {'hasPending': rows.isNotEmpty, 'changes': rows},
  );
}

/// What kind of job the body declares and where it delivers — the two words
/// that tell an operator whether approving it reaches a channel.
String _pendingSummary(Map<String, dynamic> job) {
  final type = job['type'] as String;
  final delivery = job['delivery'];
  return delivery == null ? type : '$type · $delivery';
}

/// Every model-supplied field the approved write can commit.
List<Map<String, String>> _pendingDetails(Map<String, dynamic> job) {
  final details = <Map<String, String>>[
    {'label': 'Schedule', 'value': _pendingScheduleText(job['schedule'])},
  ];
  switch (job) {
    case {'type': 'prompt', 'prompt': final Object prompt}:
      details.add({'label': 'Prompt', 'value': '$prompt'});
    case {'type': 'task', 'task': final Map<String, dynamic> task}:
      const labels = {
        'title': 'Task title',
        'description': 'Description',
        'acceptance_criteria': 'Acceptance criteria',
        'auto_start': 'Auto-start',
      };
      for (final field in task.entries) {
        details.add({'label': labels[field.key] ?? field.key, 'value': _pendingDetailValue(field.value)});
      }
  }
  for (final field in const [('delivery', 'Delivery'), ('model', 'Model'), ('effort', 'Effort')]) {
    if (job.containsKey(field.$1)) details.add({'label': field.$2, 'value': '${job[field.$1]}'});
  }
  return details;
}

String _pendingDetailValue(Object? value) => value is String ? value : jsonEncode(value);

String _pendingScheduleText(Object? schedule) => switch (schedule) {
  {'type': 'once', 'at': final Object at} => 'once at $at',
  _ => schedule?.toString() ?? '',
};

String schedulingTasksFragment({required List<ScheduledTaskDefinition> tasks, bool outOfBand = false}) {
  final rows = tasks
      .map(
        (task) => <String, dynamic>{
          'id': task.id,
          'title': task.title,
          'schedule': task.cronExpression,
          'enabled': task.enabled,
          'statusDotClass': task.enabled ? 'status-dot--live' : 'status-dot--idle',
          'statusText': task.enabled ? 'enabled' : 'disabled',
          'cronHuman': _describe(task.cronExpression),
          'editUrl': '/scheduling/tasks/${Uri.encodeComponent(task.id)}/form',
          'toggleUrl': '/scheduling/tasks/${Uri.encodeComponent(task.id)}/toggle',
          'deleteUrl': '/scheduling/tasks/${Uri.encodeComponent(task.id)}/delete',
          'deleteMessage': "Delete scheduled task '${task.title}'?",
        },
      )
      .toList();
  return templateLoader.trellis.renderFragment(
    templateLoader.source('scheduling'),
    fragment: 'tasksTable',
    context: {
      'hasTasks': rows.isNotEmpty,
      'tasks': rows,
      'outOfBand': outOfBand ? 'true' : null,
      'emptyStateHtml': emptyStateTemplate(
        title: 'No scheduled tasks',
        body: 'Add a scheduled task to automate recurring work.',
      ),
    },
  );
}

String schedulingJobFormFragment({JobFormValues? values, String? editName, String? error, String? errorField}) {
  final form = values ?? emptyJobFormValues;
  return templateLoader.trellis.renderFragment(
    templateLoader.source('scheduling'),
    fragment: 'jobForm',
    context: {
      'open': values != null,
      'title': editName == null ? 'Add New Job' : 'Edit Job: $editName',
      'submitUrl': editName == null
          ? '/scheduling/jobs/create'
          : '/scheduling/jobs/${Uri.encodeComponent(editName)}/update',
      'submitLabel': editName == null ? 'Save Job' : 'Update Job',
      'name': form.name,
      'nameDisabled': editName == null ? null : '',
      'schedule': form.schedule,
      'at': form.at,
      'prompt': form.prompt,
      'promptPlaceholder': editName == null
          ? 'Describe the task for the agent...'
          : 'Leave empty to keep current prompt',
      'cronHuman': _describe(form.schedule),
      'announceSelected': form.delivery == 'announce' ? '' : null,
      'webhookSelected': form.delivery == 'webhook' ? '' : null,
      'noneSelected': form.delivery == 'none' ? '' : null,
      'nameError': errorField == 'name' ? error ?? '' : '',
      'nameInvalid': errorField == 'name' ? 'true' : null,
      'scheduleError': errorField == 'schedule' ? error ?? '' : '',
      'scheduleInvalid': errorField == 'schedule' ? 'true' : null,
      'atError': errorField == 'at' ? error ?? '' : '',
      'atInvalid': errorField == 'at' ? 'true' : null,
      'promptError': errorField == 'prompt' ? error ?? '' : '',
      'promptInvalid': errorField == 'prompt' ? 'true' : null,
      'formError': errorField == null ? error ?? '' : '',
    },
  );
}

String schedulingTaskFormFragment({TaskFormValues? values, String? editId, String? error, String? errorField}) {
  final form = values ?? emptyTaskFormValues;
  return templateLoader.trellis.renderFragment(
    templateLoader.source('scheduling'),
    fragment: 'taskForm',
    context: {
      'open': values != null,
      'title': editId == null ? 'Add Scheduled Task' : 'Edit Scheduled Task',
      'submitUrl': editId == null
          ? '/scheduling/tasks/create'
          : '/scheduling/tasks/${Uri.encodeComponent(editId)}/update',
      'submitLabel': editId == null ? 'Save Task' : 'Update Task',
      'id': form.id,
      'idDisabled': editId == null ? null : '',
      'schedule': form.schedule,
      'titleValue': form.title,
      'description': form.description,
      'acceptance': form.acceptanceCriteria,
      'enabled': form.enabled ? '' : null,
      'cronHuman': _describe(form.schedule),
      'idError': errorField == 'id' ? error ?? '' : '',
      'idInvalid': errorField == 'id' ? 'true' : null,
      'scheduleError': errorField == 'schedule' ? error ?? '' : '',
      'scheduleInvalid': errorField == 'schedule' ? 'true' : null,
      'titleError': errorField == 'title' ? error ?? '' : '',
      'titleInvalid': errorField == 'title' ? 'true' : null,
      'descriptionError': errorField == 'description' ? error ?? '' : '',
      'descriptionInvalid': errorField == 'description' ? 'true' : null,
      'formError': errorField == null ? error ?? '' : '',
    },
  );
}

String _describe(String expression) {
  if (expression.isEmpty) return '';
  try {
    return CronExpression.parse(expression).describe();
  } catch (_) {
    return '';
  }
}
