import 'helpers.dart';
import 'layout.dart';
import 'loader.dart';
import 'sidebar.dart';
import 'topbar.dart';

/// Renders the settings hub page.
String settingsTemplate({
  required SidebarData sidebarData,
  required int uptimeSeconds,
  required int sessionCount,
  required int dbSizeBytes,
  required String workerState,
  required String version,
  bool whatsAppEnabled = false,
  bool signalEnabled = false,
  String? signalPhone,
  String signalStatus = 'not configured',
  bool guardsEnabled = false,
  List<String> activeGuards = const [],
  int scheduledJobsCount = 0,
  bool heartbeatEnabled = false,
  int heartbeatIntervalMinutes = 30,
  String? workspacePath,
  bool gitSyncEnabled = false,
}) {
  final uptimeStr = formatUptime(uptimeSeconds);

  final healthStatus = switch (workerState) {
    'running' || 'idle' => ('Healthy', 'status-badge-success'),
    'crashed' => ('Degraded', 'status-badge-warning'),
    _ => ('Unhealthy', 'status-badge-error'),
  };

  final guardsActive = guardsEnabled && activeGuards.isNotEmpty;
  final schedulingActive = scheduledJobsCount > 0 || heartbeatEnabled;

  final navItems = buildSystemNavItems(activePage: 'Settings', signalEnabled: signalEnabled);

  final sidebar = sidebarTemplate(
    mainSession: sidebarData.main,
    channelSessions: sidebarData.channels,
    sessionEntries: sidebarData.entries,
    navItems: navItems,
  );

  final topbar = pageTopbarTemplate(title: 'Settings');

  final body = templateLoader.trellis.render(templateLoader.source('settings'), {
    'sidebar': sidebar,
    'topbar': topbar,
    'whatsAppEnabled': whatsAppEnabled,
    'signalEnabled': signalEnabled,
    'signalConnected': signalStatus == 'connected',
    'signalDisconnected': signalStatus == 'disconnected',
    'signalNotConfigured': signalStatus == 'not configured',
    'signalPhone': signalPhone ?? '-',
    'guardsActive': guardsActive,
    'activeGuardCount': activeGuards.length,
    'activeGuards': activeGuards,
    'schedulingActive': schedulingActive,
    'scheduledJobsCount': scheduledJobsCount,
    'heartbeatDisplay': heartbeatEnabled ? 'every ${heartbeatIntervalMinutes}m' : 'disabled',
    'healthBadgeClass': healthStatus.$2,
    'healthLabel': healthStatus.$1,
    'uptimeStr': uptimeStr,
    'sessionCount': sessionCount,
    'version': version,
    'gitSyncEnabled': gitSyncEnabled,
    'workspacePathDisplay': workspacePath ?? '~/.dartclaw/workspace/',
    'gitSyncDisplay': gitSyncEnabled ? 'Enabled' : 'Disabled',
  });

  return layoutTemplate(title: 'Settings', body: body);
}
