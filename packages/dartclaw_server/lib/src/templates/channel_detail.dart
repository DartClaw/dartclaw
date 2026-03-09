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
  required String entryPlaceholder,
  required String groupPlaceholder,
  required SidebarData sidebarData,
  List<Map<String, dynamic>> pendingPairings = const [],
  String bannerHtml = '',
  String appName = 'DartClaw',
}) {
  final navItems = buildSystemNavItems(activePage: 'Settings');
  final sidebar = buildSidebar(sidebarData: sidebarData, navItems: navItems, appName: appName);
  final topbar = pageTopbarTemplate(
    title: '$channelLabel Channel',
    backHref: '/settings#channels',
    backLabel: 'Settings',
  );

  final pairingHref = channelType == 'whatsapp' ? '/whatsapp/pairing' : '/signal/pairing';
  final disconnectHref = '$pairingHref/disconnect';
  final isConnected = statusLabel == 'Connected';
  final heroTitle = channelLabel;
  final heroSubtitle = channelType == 'whatsapp'
      ? 'Channel access rules, pairing approvals, and session routing.'
      : 'Access policy, group controls, and conversation scoping for Signal traffic.';
  final dmCards = _buildModeCards(['pairing', 'allowlist', 'open', 'disabled'], dmAccessMode, _dmModeHelp);
  final groupCards = _buildModeCards(['allowlist', 'open', 'disabled'], groupAccessMode, _groupModeHelp);
  final groupAccessDisabled = groupAccessMode == 'disabled';

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
    'showDisconnectAction': isConnected,
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
