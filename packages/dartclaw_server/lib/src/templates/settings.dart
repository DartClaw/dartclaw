import 'components.dart';
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
  required List<NavItem> navItems,
  required int uptimeSeconds,
  required int sessionCount,
  required String workerState,
  required String version,
  List<Map<String, Object?>> providers = const [],
  int providerConfiguredCount = 0,
  int providerHealthyCount = 0,
  int providerDegradedCount = 0,
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
  bool googleChatEnabled = false,
  String googleChatStatusLabel = 'Disabled',
  String googleChatStatusClass = 'status-badge-muted',
  int googleChatPendingCount = 0,
  bool guardsEnabled = false,
  bool guardFailOpen = false,
  List<GuardConfigSummary> guardConfigs = const [],
  String? workspacePath,
  String bannerHtml = '',
  String appName = 'DartClaw',
}) {
  final uptimeStr = formatUptime(uptimeSeconds);

  final (healthLabel, healthVariant) = switch (workerState) {
    'running' || 'idle' => ('Healthy', 'success'),
    'crashed' => ('Degraded', 'warning'),
    _ => ('Unhealthy', 'error'),
  };

  // Pre-render status badges.
  final healthBadgeHtml = statusBadgeTemplate(variant: healthVariant, text: healthLabel);
  final whatsAppBadgeVariant = _badgeVariantFromClass(whatsAppStatusClass);
  final whatsAppStatusBadgeHtml = statusBadgeTemplate(
    variant: whatsAppBadgeVariant,
    text: whatsAppStatusLabel,
  );
  final signalBadgeVariant = _badgeVariantFromClass(signalStatusClass);
  final signalStatusBadgeHtml = statusBadgeTemplate(
    variant: signalBadgeVariant,
    text: signalStatusLabel,
  );
  final googleChatBadgeVariant = _badgeVariantFromClass(googleChatStatusClass);
  final googleChatStatusBadgeHtml = statusBadgeTemplate(
    variant: googleChatBadgeVariant,
    text: googleChatStatusLabel,
  );

  // Pre-render provider health badges.
  final providersWithBadges = providers.map((p) {
    final badgeClass = p['healthBadgeClass']?.toString() ?? 'status-badge-muted';
    final badgeLabel = p['healthLabel']?.toString() ?? '';
    return {
      ...p,
      'statusBadgeHtml': statusBadgeTemplate(
        variant: _badgeVariantFromClass(badgeClass),
        text: badgeLabel,
      ),
    };
  }).toList();

  final sidebar = buildSidebar(sidebarData: sidebarData, navItems: navItems, appName: appName);

  final topbar = pageTopbarTemplate(title: 'Settings');

  final body = templateLoader.trellis.render(templateLoader.source('settings'), {
    'sidebar': sidebar,
    'topbar': topbar,
    'providers': providersWithBadges,
    'hasProviders': providers.isNotEmpty,
    'providerConfiguredCount': providerConfiguredCount,
    'providerHealthyCount': providerHealthyCount,
    'providerDegradedCount': providerDegradedCount,
    'whatsAppEnabled': whatsAppEnabled,
    'whatsAppStatusBadgeHtml': whatsAppStatusBadgeHtml,
    'whatsAppPhone': whatsAppPhone,
    'whatsAppPendingCount': whatsAppPendingCount,
    'whatsAppHasPending': whatsAppPendingCount > 0,
    'signalEnabled': signalEnabled,
    'signalStatusBadgeHtml': signalStatusBadgeHtml,
    'signalPhone': signalPhone,
    'signalPendingCount': signalPendingCount,
    'signalHasPending': signalPendingCount > 0,
    'googleChatEnabled': googleChatEnabled,
    'googleChatStatusBadgeHtml': googleChatStatusBadgeHtml,
    'googleChatPendingCount': googleChatPendingCount,
    'googleChatHasPending': googleChatPendingCount > 0,
    'guardsEnabled': guardsEnabled,
    'activeGuardCount': guardConfigs.where((g) => g.enabled).length,
    'guardFailOpen': guardFailOpen,
    'guardConfigs': guardConfigs.map((g) => g.toTemplateMap()).toList(),
    'healthBadgeHtml': healthBadgeHtml,
    'uptimeStr': uptimeStr,
    'sessionCount': sessionCount,
    'version': version,
    'workspacePathDisplay': workspacePath ?? '~/.dartclaw/workspace/',
    'bannerHtml': bannerHtml.isNotEmpty ? bannerHtml : null,
  });

  return layoutTemplate(title: 'Settings', body: body, appName: appName);
}

/// Extracts the variant suffix from a `status-badge-{variant}` class string.
/// Returns `'muted'` as a safe fallback.
String _badgeVariantFromClass(String badgeClass) {
  const prefix = 'status-badge-';
  if (badgeClass.startsWith(prefix)) return badgeClass.substring(prefix.length);
  return 'muted';
}
