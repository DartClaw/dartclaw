import 'package:dartclaw_core/dartclaw_core.dart' show TaskType;

import 'layout.dart';
import 'loader.dart';
import 'sidebar.dart';
import 'topbar.dart';

/// Renders the channel detail page for a specific channel type.
///
/// Shows DM access mode + allowlist, group access mode + allowlist,
/// and mention gating toggle. Mode changes are restart-required;
/// DM allowlist changes are live.
String channelDetailTemplate({
  required String channelType,
  required String channelLabel,
  required String statusLabel,
  required String statusClass,
  String? phone,
  required String dmAccessMode,
  required List<String> dmAccessModes,
  required List<String> dmAllowlist,
  required String groupAccessMode,
  required List<String> groupAccessModes,
  required List<String> groupAllowlist,
  required bool requireMention,
  bool taskTriggerEnabled = false,
  String taskTriggerPrefix = 'task:',
  String taskTriggerDefaultType = 'research',
  bool taskTriggerAutoStart = true,
  required String entryPlaceholder,
  required String groupPlaceholder,
  required SidebarData sidebarData,
  required List<NavItem> navItems,
  List<Map<String, dynamic>> pendingPairings = const [],
  String bannerHtml = '',
  String appName = 'DartClaw',
}) {
  final sidebar = buildSidebar(sidebarData: sidebarData, navItems: navItems, appName: appName);
  final topbar = pageTopbarTemplate(
    title: '$channelLabel Channel',
    backHref: '/settings#channels',
    backLabel: 'Settings',
  );

  final pairingHref = switch (channelType) {
    'whatsapp' => '/whatsapp/pairing',
    'signal' => '/signal/pairing',
    _ => null,
  };
  final disconnectHref = pairingHref != null ? '$pairingHref/disconnect' : null;
  final isConnected = statusLabel == 'Connected';
  final heroTitle = channelLabel;
  final heroSubtitle = switch (channelType) {
    'whatsapp' => 'Channel access rules, pairing approvals, and session routing.',
    'signal' => 'Access policy, group controls, and conversation scoping for Signal traffic.',
    'google_chat' => 'Access policy, group controls, and session routing for Google Chat.',
    _ => 'Channel configuration and access controls.',
  };
  final dmCards = _buildModeCards(['pairing', 'allowlist', 'open', 'disabled'], dmAccessMode, _dmModeHelp);
  final groupCards = _buildModeCards(['allowlist', 'open', 'disabled'], groupAccessMode, _groupModeHelp);
  final groupAccessDisabled = groupAccessMode == 'disabled';
  final taskTriggerTypes = _taskTriggerTypeOptions(taskTriggerDefaultType);

  final body = templateLoader.trellis.render(templateLoader.source('channel_detail'), {
    'sidebar': sidebar,
    'topbar': topbar,
    'channelType': channelType,
    'channelLabel': channelLabel,
    'statusLabel': statusLabel,
    'statusClass': statusClass,
    'phone': phone,
    'pairingHref': pairingHref,
    'disconnectHref': disconnectHref,
    'showDisconnectAction': isConnected && pairingHref != null,
    'heroTitle': heroTitle,
    'heroSubtitle': heroSubtitle,
    'dmAccessMode': dmAccessMode,
    'dmAccessModes': dmAccessModes,
    'dmModeCards': dmCards,
    'dmAllowlist': dmAllowlist,
    'dmAllowlistCount': dmAllowlist.length,
    'groupAccessMode': groupAccessMode,
    'groupAccessModes': groupAccessModes,
    'groupModeCards': groupCards,
    'groupAllowlist': groupAllowlist,
    'groupAllowlistCount': groupAllowlist.length,
    'requireMention': requireMention,
    'taskTriggerEnabled': taskTriggerEnabled,
    'taskTriggerPrefix': taskTriggerPrefix,
    'taskTriggerDefaultType': taskTriggerDefaultType,
    'taskTriggerAutoStart': taskTriggerAutoStart,
    'taskTriggerTypes': taskTriggerTypes,
    'groupAccessDisabled': groupAccessDisabled,
    'entryPlaceholder': entryPlaceholder,
    'groupPlaceholder': groupPlaceholder,
    'showPairingSection': dmAccessMode == 'pairing',
    'pendingPairings': pendingPairings.isNotEmpty ? pendingPairings : null,
    'bannerHtml': bannerHtml.isNotEmpty ? bannerHtml : null,
  });

  return layoutTemplate(title: '$channelLabel Channel', body: body, appName: appName);
}

const _dmModeHelp = <String, String>{
  'pairing': 'Unknown senders must request approval before a direct session is opened.',
  'allowlist': 'Only known senders can start direct conversations.',
  'open': 'Any sender may start a direct conversation.',
  'disabled': 'All direct messages are blocked for this channel.',
};

const _groupModeHelp = <String, String>{
  'allowlist': 'Only approved groups may create or resume conversations.',
  'open': 'Any group on this channel can reach the agent.',
  'disabled': 'All group conversations are blocked for this channel.',
};

List<Map<String, dynamic>> _buildModeCards(List<String> modes, String activeMode, Map<String, String> helpMap) {
  return modes.map((mode) {
    final label = switch (mode) {
      'pairing' => 'Pairing',
      'allowlist' => 'Allowlist',
      'open' => 'Open',
      'disabled' => 'Disabled',
      _ => mode,
    };
    return <String, dynamic>{'value': mode, 'label': label, 'help': helpMap[mode] ?? '', 'active': mode == activeMode};
  }).toList();
}

List<String> _taskTriggerTypeOptions(String selectedType) {
  final options = TaskType.values.map((type) => type.name).toList();
  if (!options.contains(selectedType)) {
    options.add(selectedType);
  }
  return options;
}
