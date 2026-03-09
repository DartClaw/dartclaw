import 'guard_config_summary.dart';
import 'helpers.dart';
import 'layout.dart';
import 'loader.dart';
import 'sidebar.dart';
import 'topbar.dart';

/// Renders the settings hub page.
///
/// Editable config fields (Agent, Server, Sessions, Memory, Scheduling) are
/// populated client-side from `GET /api/config`. Server-rendered sections
/// (channels, guards, health, auth, workspace) still receive template vars.
String settingsTemplate({
  required SidebarData sidebarData,
  required int uptimeSeconds,
  required int sessionCount,
  required String workerState,
  required String version,
  bool whatsAppEnabled = false,
  String whatsAppStatusLabel = 'Disabled',
  String whatsAppStatusClass = 'status-badge-muted',
  String? whatsAppPhone,
  int whatsAppPendingCount = 0,
  bool signalEnabled = false,
  String? signalPhone,
  String signalStatusLabel = 'Disabled',
  String signalStatusClass = 'status-badge-muted',
  int signalPendingCount = 0,
  bool guardsEnabled = false,
  bool guardFailOpen = false,
  List<GuardConfigSummary> guardConfigs = const [],
  String? workspacePath,
  String bannerHtml = '',
  String appName = 'DartClaw',
}) {
  final uptimeStr = formatUptime(uptimeSeconds);

  final healthStatus = switch (workerState) {
    'running' || 'idle' => ('Healthy', 'status-badge-success'),
    'crashed' => ('Degraded', 'status-badge-warning'),
    _ => ('Unhealthy', 'status-badge-error'),
  };

  final navItems = buildSystemNavItems(activePage: 'Settings');

  final sidebar = buildSidebar(sidebarData: sidebarData, navItems: navItems, appName: appName);

  final topbar = pageTopbarTemplate(title: 'Settings');

  final body = templateLoader.trellis.render(templateLoader.source('settings'), {
    'sidebar': sidebar,
    'topbar': topbar,
    'whatsAppEnabled': whatsAppEnabled,
    'whatsAppStatusLabel': whatsAppStatusLabel,
    'whatsAppStatusClass': whatsAppStatusClass,
    'whatsAppPhone': whatsAppPhone,
    'whatsAppPendingCount': whatsAppPendingCount,
    'whatsAppHasPending': whatsAppPendingCount > 0,
    'signalEnabled': signalEnabled,
    'signalStatusLabel': signalStatusLabel,
    'signalStatusClass': signalStatusClass,
    'signalPhone': signalPhone,
    'signalPendingCount': signalPendingCount,
    'signalHasPending': signalPendingCount > 0,
    'guardsEnabled': guardsEnabled,
    'activeGuardCount': guardConfigs.where((g) => g.enabled).length,
    'guardFailOpen': guardFailOpen,
    'guardConfigs': guardConfigs.map((g) => g.toTemplateMap()).toList(),
    'healthBadgeClass': healthStatus.$2,
    'healthLabel': healthStatus.$1,
    'uptimeStr': uptimeStr,
    'sessionCount': sessionCount,
    'version': version,
    'workspacePathDisplay': workspacePath ?? '~/.dartclaw/workspace/',
    'bannerHtml': bannerHtml.isNotEmpty ? bannerHtml : null,
  });

  return layoutTemplate(title: 'Settings', body: body, appName: appName);
}
