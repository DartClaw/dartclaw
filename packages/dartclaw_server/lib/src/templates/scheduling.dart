import 'package:dartclaw_config/dartclaw_config.dart' show ScheduledTaskDefinition;
import 'package:dartclaw_core/dartclaw_core.dart' show TaskType;
import 'package:logging/logging.dart';

import '../scheduling/cron_parser.dart';
import 'components.dart';
import 'layout.dart';
import 'loader.dart';
import 'sidebar.dart';
import 'topbar.dart';

final _log = Logger('scheduling_template');

/// Renders the scheduling status page.
String schedulingTemplate({
  required SidebarData sidebarData,
  required List<NavItem> navItems,
  bool heartbeatEnabled = false,
  int heartbeatIntervalMinutes = 30,
  List<Map<String, dynamic>> jobs = const [],
  List<String> systemJobNames = const [],
  List<ScheduledTaskDefinition> scheduledTasks = const [],
  String restartBannerHtml = '',
  String appName = 'DartClaw',
}) {
  final sidebar = buildSidebar(sidebarData: sidebarData, navItems: navItems, appName: appName);

  final topbar = pageTopbarTemplate(title: 'Scheduling Status', restartBannerHtml: restartBannerHtml);

  // Task-type entries share the unified `scheduling.jobs` list but belong in the
  // Scheduled Tasks table below; exclude them here so they don't render as a
  // blank, actionable phantom row in Scheduled Jobs.
  final jobRows = jobs.where((job) => job['type']?.toString() != 'task').map((job) {
    final name = job['name']?.toString() ?? '';
    final schedule = job['schedule']?.toString() ?? '';
    final delivery = job['delivery']?.toString() ?? 'none';
    final jobStatus = job['status']?.toString() ?? 'active';
    final isSystem = systemJobNames.contains(name);
    final canRun = !isSystem || job['runnable'] == true;

    // Cron human-readable description
    String cronHuman = '';
    try {
      cronHuman = CronExpression.parse(schedule).describe();
    } catch (e) {
      _log.fine('Could not parse cron expression "$schedule": $e');
    }

    final deliveryBadgeClass = switch (delivery) {
      'announce' => 'announce',
      'webhook' => 'webhook',
      _ => '',
    };

    final statusDotClass = switch (jobStatus) {
      'active' => 'status-dot--live',
      'error' => 'status-dot--error',
      _ => 'status-dot--idle',
    };

    return <String, dynamic>{
      'name': name,
      'schedule': schedule,
      'delivery': delivery,
      'status': jobStatus,
      'deliveryBadgeClass': deliveryBadgeClass,
      'statusDotClass': statusDotClass,
      'rowClass': isSystem ? 'row-system' : (jobStatus == 'error' ? 'row-error' : ''),
      'isActive': jobStatus == 'active',
      'isSystem': isSystem,
      'canRun': canRun,
      'hasActions': !isSystem || canRun,
      'cronHuman': cronHuman,
    };
  }).toList();

  // Build scheduled task rows for the automation section
  final taskRows = scheduledTasks.map((def) {
    String cronHuman = '';
    try {
      cronHuman = CronExpression.parse(def.cronExpression).describe();
    } catch (e) {
      _log.fine('Could not parse task cron expression "${def.cronExpression}": $e');
    }

    return <String, dynamic>{
      'id': def.id,
      'title': def.title,
      'schedule': def.cronExpression,
      'type': def.type.name,
      'enabled': def.enabled,
      'statusDotClass': def.enabled ? 'status-dot--live' : 'status-dot--idle',
      'statusText': def.enabled ? 'enabled' : 'disabled',
      'cronHuman': cronHuman,
      'description': def.description,
      'acceptanceCriteria': def.acceptanceCriteria,
      'autoStart': def.autoStart,
    };
  }).toList();

  final body = templateLoader.trellis.render(templateLoader.source('scheduling'), {
    'sidebar': sidebar,
    'topbar': topbar,
    'pageHeaderHtml': pageHeaderTemplate(
      subtitle: 'Recurring jobs and scheduled tasks, plus the heartbeat that drives them.',
    ),
    'jobsEmptyStateHtml': emptyStateTemplate(
      title: 'No scheduled jobs',
      body: 'Add a job to have the agent run a prompt on a cron schedule.',
    ),
    'tasksEmptyStateHtml': emptyStateTemplate(
      title: 'No scheduled tasks',
      body: 'Add a scheduled task to automate recurring work.',
    ),
    'pulseClass': heartbeatEnabled ? '' : 'paused',
    'heartbeatBadgeHtml': statusBadgeTemplate(
      variant: heartbeatEnabled ? 'success' : 'muted',
      text: heartbeatEnabled ? 'Active' : 'Disabled',
    ),
    // The interval is the block's only numeric KPI, so it is the only thing that
    // earns the metric tier. Status is already stated once by the header badge —
    // a second copy at 32px said "Disabled" in the size reserved for numbers.
    'hasHeartbeatMetrics': heartbeatEnabled,
    'heartbeatMetricCardsHtml': heartbeatEnabled
        ? metricCardTemplate(color: 'info', value: '$heartbeatIntervalMinutes', label: 'Interval (min)')
        : null,
    'heartbeatOn': heartbeatEnabled,
    'hasJobs': jobRows.isNotEmpty,
    'hasUserJobs': jobRows.any((j) => j['isSystem'] != true),
    'jobs': jobRows,
    'hasScheduledTasks': scheduledTasks.isNotEmpty,
    'scheduledTasks': taskRows,
    'taskTypes': TaskType.values.map((t) => t.name).toList(),
  });

  return layoutTemplate(title: 'Scheduling', body: body, appName: appName, scripts: standardShellScripts());
}
