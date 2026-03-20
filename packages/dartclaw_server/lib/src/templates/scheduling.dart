import 'package:dartclaw_core/dartclaw_core.dart';

import '../scheduling/cron_parser.dart';
import 'layout.dart';
import 'loader.dart';
import 'sidebar.dart';
import 'topbar.dart';

/// Renders the scheduling status page.
String schedulingTemplate({
  required SidebarData sidebarData,
  required List<NavItem> navItems,
  bool heartbeatEnabled = false,
  int heartbeatIntervalMinutes = 30,
  List<Map<String, dynamic>> jobs = const [],
  List<String> systemJobNames = const [],
  List<ScheduledTaskDefinition> scheduledTasks = const [],
  String bannerHtml = '',
  String appName = 'DartClaw',
}) {
  final sidebar = buildSidebar(sidebarData: sidebarData, navItems: navItems, appName: appName);

  final topbar = pageTopbarTemplate(title: 'Scheduling Status');

  final jobRows = jobs.map((job) {
    final name = job['name']?.toString() ?? '';
    final schedule = job['schedule']?.toString() ?? '';
    final delivery = job['delivery']?.toString() ?? 'none';
    final jobStatus = job['status']?.toString() ?? 'active';
    final isSystem = systemJobNames.contains(name);

    // Cron human-readable description
    String cronHuman = '';
    try {
      cronHuman = CronExpression.parse(schedule).describe();
    } catch (_) {}

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

    final statusBadgeClass = switch (jobStatus) {
      'active' => 'status-badge-success',
      'error' => 'status-badge-error',
      _ => 'status-badge-muted',
    };

    return <String, dynamic>{
      'name': name,
      'schedule': schedule,
      'delivery': delivery,
      'status': jobStatus,
      'deliveryBadgeClass': deliveryBadgeClass,
      'statusDotClass': statusDotClass,
      'statusBadgeClass': statusBadgeClass,
      'rowClass': isSystem ? 'row-system' : (jobStatus == 'error' ? 'row-error' : ''),
      'isActive': jobStatus == 'active',
      'isSystem': isSystem,
      'hasActions': !isSystem,
      'cronHuman': cronHuman,
    };
  }).toList();

  // Build scheduled task rows for the automation section
  final taskRows = scheduledTasks.map((def) {
    String cronHuman = '';
    try {
      cronHuman = CronExpression.parse(def.cronExpression).describe();
    } catch (_) {}

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
    'pulseClass': heartbeatEnabled ? '' : 'paused',
    'badgeClass': heartbeatEnabled ? '' : 'paused',
    'badgeText': heartbeatEnabled ? 'Active' : 'Disabled',
    'intervalDisplay': heartbeatEnabled ? 'every $heartbeatIntervalMinutes min' : '\u2014',
    'heartbeatOn': heartbeatEnabled,
    'hasJobs': jobs.isNotEmpty,
    'hasUserJobs': jobRows.any((j) => j['isSystem'] != true),
    'jobs': jobRows,
    'hasScheduledTasks': scheduledTasks.isNotEmpty,
    'scheduledTasks': taskRows,
    'taskTypes': TaskType.values.map((t) => t.name).toList(),
    'bannerHtml': bannerHtml.isNotEmpty ? bannerHtml : null,
  });

  return layoutTemplate(title: 'Scheduling', body: body, appName: appName);
}
