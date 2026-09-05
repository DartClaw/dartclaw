import '../health/health_service.dart';
import '../web/channel_status.dart';
import '../web/settings/settings_sections.dart';
import 'components.dart';
import 'guard_config_summary.dart';
import 'helpers.dart';
import 'layout.dart';
import 'loader.dart';
import 'sidebar.dart';
import 'topbar.dart';

/// Renders the settings hub page.
///
/// Editable config fields arrive already rendered in [sectionHtml], keyed by
/// panel id — one entry per [settingsPanels] form panel, produced from the
/// config field registry. The remaining sections (channels, providers, guards,
/// health, auth, workspace) are server-rendered from the template vars below.
String settingsTemplate({
  required SidebarData sidebarData,
  required List<NavItem> navItems,
  required int uptimeSeconds,
  required int sessionCount,
  required String status,
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
  Map<String, String> sectionHtml = const {},
  Map<String, Object?> guardEditorState = const {},
  String guardFieldsHtml = '',
}) {
  final uptimeStr = formatUptime(uptimeSeconds);

  final healthLabel = titleCase(status);
  final healthVariant = healthStatusBadgeVariant(status);

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
    'tabs': [
      for (final tab in settingsTabs)
        {
          'label': tab.label,
          'href': '#${tab.id}',
          'controlId': 'tab-${tab.id}',
          'panelIds': settingsPanels.where((panel) => panel.tab == tab.id).map((panel) => panel.elementId).join(' '),
        },
    ],
    'formPanels': [
      for (final panel in settingsPanels)
        if (panel.isForm)
          {
            'elementId': panel.elementId,
            'tab': panel.tab,
            'tabControlId': 'tab-${panel.tab}',
            'title': panel.title,
            'formHtml': sectionHtml[panel.id] ?? _unavailableSectionHtml,
            'linkHref': panel.linkHref,
            'linkLabel': panel.linkLabel,
          },
    ],
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
    'guardEditorHtml': guardEditorFragment(guardEditorState),
    'guardFieldsHtml': guardFieldsHtml,
    'hasGuardFields': guardFieldsHtml.isNotEmpty,
    'healthBadgeHtml': healthBadgeHtml,
    'uptimeStr': uptimeStr,
    'sessionCount': sessionCount,
    'version': resolvedVersion.value ?? '',
    'versionClass': resolvedVersion.isAbsent ? 'value-absent' : '',
    'workspacePathDisplay': workspacePath ?? '~/.dartclaw/workspace/',
  });

  return layoutTemplate(title: 'Settings', body: body, appName: appName, scripts: standardShellScripts());
}

String guardEditorFragment(
  Map<String, Object?> state, {
  String activeGuard = 'command',
  String? error,
  String value = '',
}) {
  final groups =
      (state['guards'] as List?)?.whereType<Map<Object?, Object?>>().map(Map<String, Object?>.from).toList() ??
      const [];
  final active = groups.firstWhere(
    (group) => group['guard'] == activeGuard,
    orElse: () => groups.isEmpty ? <String, Object?>{} : groups.first,
  );
  final guard = active['guard']?.toString() ?? activeGuard;
  final fields = active['fields'] is Map ? Map<String, Object?>.from(active['fields'] as Map) : <String, Object?>{};
  final rows = <Map<String, Object?>>[];
  for (final field in fields.entries) {
    final entries = field.value is List ? field.value as List : const [];
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      rows.add({
        'number': index + 1,
        'field': field.key,
        'fieldLabel': _guardFieldLabel(field.key),
        'display': _guardEntryDisplay(entry),
        'value': entry is Map ? entry['pattern']?.toString() ?? '' : entry?.toString() ?? '',
        'level': entry is Map ? entry['level']?.toString() ?? 'no_access' : 'no_access',
        'isFile': guard == 'file',
        'index': index,
        'deleteAction': '/settings/guards/$guard/${field.key}/$index/delete',
        'updateAction': '/settings/guards/$guard/${field.key}/$index/update',
        'editAction': '/settings/guards/$guard/${field.key}/$index/edit',
      });
    }
  }
  return templateLoader.trellis.renderFragment(
    templateLoader.source('guard_editor'),
    fragment: 'guardEditor',
    context: {
      'activeGuard': guard,
      'tabs': [
        for (final group in groups)
          {
            'guard': group['guard'],
            'label': titleCase(group['guard']?.toString() ?? ''),
            'active': group['guard'] == guard,
            'href': '/settings/guards/${group['guard']}',
            'id': 'guard-editor-tab-${group['guard']}',
          },
      ],
      'rows': rows.isEmpty ? null : rows,
      'fields': [
        for (final field in fields.keys) {'value': field, 'label': _guardFieldLabel(field)},
      ],
      'addAction': '/settings/guards/$guard/add',
      'guardError': error,
      'guardValue': value,
      'showLevel': guard == 'file',
      'pendingRestart': (state['pendingRestart'] as List?)?.whereType<String>().join(', ') ?? '',
      'hasPendingRestart': (state['pendingRestart'] as List?)?.isNotEmpty ?? false,
      'displayedLayer': state['displayedLayer']?.toString() ?? 'persisted-config',
      'hasError': false,
      'error': null,
      'verdict': '',
      'reason': '',
      'guardFamily': '',
      'evaluatedLayer': '',
    },
  );
}

String guardEditDialogFragment({
  required String guard,
  required String field,
  required int index,
  required String display,
  required String value,
  required String level,
  required bool isFile,
  String? error,
}) => templateLoader.trellis.renderFragment(
  templateLoader.source('guard_editor'),
  fragment: 'guardEditDialog',
  context: {
    'fieldLabel': _guardFieldLabel(field),
    'display': display,
    'value': value,
    'level': level,
    'isFile': isFile,
    'error': error,
    'updateAction': '/settings/guards/$guard/$field/$index/update',
  },
);

String _guardFieldLabel(String field) => switch (field) {
  'extra_blocked_patterns' => 'Blocked pattern',
  'extra_blocked_pipe_targets' => 'Blocked pipe target',
  'extra_rules' => 'File rule',
  'extra_allowed_domains' => 'Allowed domain',
  'extra_exfil_patterns' => 'Exfiltration pattern',
  _ => field,
};

String _guardEntryDisplay(Object? entry) {
  if (entry is Map) {
    return '${entry['pattern'] ?? ''} · ${entry['level'] ?? ''}';
  }
  return entry?.toString() ?? '';
}

/// What a form panel shows when this server has no config file to edit.
///
/// The card is still rendered so its tab's `aria-controls` keeps resolving; an
/// empty container would leave the strip pointing at nothing.
String get _unavailableSectionHtml => emptyStateTemplate(
  title: 'Configuration editing unavailable',
  body: 'This server was started without a writable dartclaw.yaml, so settings can only be read.',
);

/// Renders a channel summary badge from the shared [ChannelStatus] presentation.
///
/// The dot suffix is the record's own field, never derived from the badge
/// variant — three statuses share the warning badge with different dots.
String _channelStatusBadge(ChannelStatus status) {
  final presentation = status.presentation;
  return statusBadgeTemplate(variant: status.badgeVariant, text: presentation.label, dot: presentation.dotVariant);
}
