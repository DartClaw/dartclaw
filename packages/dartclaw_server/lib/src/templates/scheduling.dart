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
  bool signalEnabled = false,
}) {
  final navItems = buildSystemNavItems(activePage: 'Scheduling', signalEnabled: signalEnabled);

  final sidebar = sidebarTemplate(
    mainSession: sidebarData.main,
    channelSessions: sidebarData.channels,
    sessionEntries: sidebarData.entries,
    navItems: navItems,
  );

  final topbar = pageTopbarTemplate(title: 'Scheduling Status');

  final jobRows = jobs.map((job) {
    final delivery = job['delivery']?.toString() ?? 'none';
    final jobStatus = job['status']?.toString() ?? 'active';

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
      'name': job['name']?.toString() ?? '',
      'schedule': job['schedule']?.toString() ?? '',
      'delivery': delivery,
      'status': jobStatus,
      'deliveryBadgeClass': deliveryBadgeClass,
      'statusDotClass': statusDotClass,
      'rowClass': jobStatus == 'error' ? 'row-error' : '',
      'isActive': jobStatus == 'active',
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
    'jobs': jobRows,
  });

  return layoutTemplate(title: 'Scheduling', body: body);
}
