import '../web/channel_status.dart';
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
  ChannelStatus whatsAppStatus = ChannelStatus.disabled,
  String? whatsAppPhone,
  int whatsAppPendingCount = 0,
  bool signalEnabled = false,
  String? signalPhone,
  ChannelStatus signalStatus = ChannelStatus.disabled,
  int signalPendingCount = 0,
  bool googleChatEnabled = false,
  ChannelStatus googleChatStatus = ChannelStatus.disabled,
  int googleChatPendingCount = 0,
  bool guardsEnabled = false,
  bool guardFailOpen = false,
  List<GuardConfigSummary> guardConfigs = const [],
  String? workspacePath,
  String restartBannerHtml = '',
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
  // Channel badges come from the shared presentation record, so the summary
  // card and the channel detail page never disagree about a status.
  final whatsAppStatusBadgeHtml = _channelStatusBadge(whatsAppStatus);
  final signalStatusBadgeHtml = _channelStatusBadge(signalStatus);
  final googleChatStatusBadgeHtml = _channelStatusBadge(googleChatStatus);

  // Pre-render provider health badges.
  const badgePrefix = 'status-badge-';
  final providersWithBadges = providers.map((p) {
    final badgeClass = p['healthBadgeClass']?.toString() ?? 'status-badge-muted';
    final badgeVariant = badgeClass.startsWith(badgePrefix) ? badgeClass.substring(badgePrefix.length) : 'muted';
    final badgeLabel = p['healthLabel']?.toString() ?? '';
    return {
      ...p,
      'statusBadgeHtml': statusBadgeTemplate(variant: badgeVariant, text: badgeLabel),
      'credentialStateBadgeHtml': p['hasCredentialState'] == true
          ? statusBadgeTemplate(
              variant: p['credentialStateVariant']?.toString() ?? 'muted',
              text: p['credentialStateLabel']?.toString() ?? '',
            )
          : '',
    };
  }).toList();

  final sidebar = buildSidebar(sidebarData: sidebarData, navItems: navItems, appName: appName);

  final topbar = pageTopbarTemplate(title: 'Settings', restartBannerHtml: restartBannerHtml);

  // The topbar owns the page's only <h1>; the head carries the description.
  final pageHeaderHtml = pageHeaderTemplate(subtitle: 'Configuration and system status');

  final resolvedVersion = absentValue(version);

  final body = templateLoader.trellis.render(templateLoader.source('settings'), {
    'sidebar': sidebar,
    'topbar': topbar,
    'pageHeaderHtml': pageHeaderHtml,
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
    'version': resolvedVersion.value ?? '',
    'versionClass': resolvedVersion.isAbsent ? 'value-absent' : '',
    'workspacePathDisplay': workspacePath ?? '~/.dartclaw/workspace/',
  });

  return layoutTemplate(title: 'Settings', body: body, appName: appName, scripts: standardShellScripts());
}

/// Renders a channel summary badge from the shared [ChannelStatus] presentation.
///
/// The dot suffix is the record's own field, never derived from the badge
/// variant — three statuses share the warning badge with different dots.
String _channelStatusBadge(ChannelStatus status) {
  final presentation = status.presentation;
  return statusBadgeTemplate(variant: status.badgeVariant, text: presentation.label, dot: presentation.dotVariant);
}
