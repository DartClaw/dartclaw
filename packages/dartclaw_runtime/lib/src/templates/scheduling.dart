import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import '../scheduling/cron_parser.dart';
import '../scheduling/scheduled_task_runner.dart';
import 'components.dart';
import 'layout.dart';
import 'loader.dart';
import 'sidebar.dart';
import 'topbar.dart';

typedef JobFormValues = ({String name, String schedule, String prompt, String delivery});
typedef TaskFormValues = ({
  String id,
  String schedule,
  String title,
  String description,
  String acceptanceCriteria,
  bool enabled,
});

const emptyJobFormValues = (name: '', schedule: '', prompt: '', delivery: 'announce');
const emptyTaskFormValues = (id: '', schedule: '', title: '', description: '', acceptanceCriteria: '', enabled: true);

String schedulingTemplate({
  required SidebarData sidebarData,
  required List<NavItem> navItems,
  bool heartbeatEnabled = false,
  int heartbeatIntervalMinutes = 30,
  List<Map<String, dynamic>> jobs = const [],
  List<String> systemJobNames = const [],
  List<ScheduledTaskDefinition> scheduledTasks = const [],
  Set<String> loadedJobIds = const {},
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
        loadedJobIds: loadedJobIds,
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
  required Set<String> loadedJobIds,
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
    'jobsTableHtml': schedulingJobsFragment(jobs: jobs, systemJobNames: systemJobNames, loadedJobIds: loadedJobIds),
    'taskFormHtml': schedulingTaskFormFragment(),
    'tasksTableHtml': schedulingTasksFragment(tasks: scheduledTasks, loadedJobIds: loadedJobIds),
  },
);

String schedulingJobsFragment({
  required List<Map<String, dynamic>> jobs,
  required List<String> systemJobNames,
  required Set<String> loadedJobIds,
  bool outOfBand = false,
}) {
  final rows = jobs.where((job) => job['type']?.toString() != 'task').map((job) {
    final name = (job['name'] ?? job['id'])?.toString() ?? '';
    final status = job['status']?.toString() ?? 'active';
    final system = systemJobNames.contains(name);
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
      'canStart': canRun && !running,
      'runDisabled': canRun && running,
      'hasActions': !system || canRun,
      'cronHuman': _describe(schedule),
      'notRunning': !loadedJobIds.contains(name),
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

String schedulingTasksFragment({
  required List<ScheduledTaskDefinition> tasks,
  required Set<String> loadedJobIds,
  bool outOfBand = false,
}) {
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
          'notRunning': !loadedJobIds.contains(ScheduledTaskRunner.jobIdForDefinition(task.id)),
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
