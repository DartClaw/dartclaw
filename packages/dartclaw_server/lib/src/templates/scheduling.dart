import '../scheduling/cron_parser.dart';
import 'layout.dart';
import 'loader.dart';
import 'sidebar.dart';
import 'topbar.dart';

/// Renders the scheduling status page.
String schedulingTemplate({
  required SidebarData sidebarData,
  bool heartbeatEnabled = false,
  int heartbeatIntervalMinutes = 30,
  List<Map<String, dynamic>> jobs = const [],
  List<String> systemJobNames = const [],
  String bannerHtml = '',
  String appName = 'DartClaw',
}) {
  final navItems = buildSystemNavItems(activePage: 'Scheduling');

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
      'active' => 'active',
      'error' => 'error',
      'paused' => 'paused',
      _ => '',
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
      'hasActions': !isSystem,
      'cronHuman': cronHuman,
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
    'bannerHtml': bannerHtml.isNotEmpty ? bannerHtml : null,
  });

  return layoutTemplate(title: 'Scheduling', body: body, appName: appName);
}
