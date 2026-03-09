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

  final body = templateLoader.trellis.render(templateLoader.source('channel_detail'), {
    'sidebar': sidebar,
    'topbar': topbar,
    'channelType': channelType,
    'channelLabel': channelLabel,
    'statusLabel': statusLabel,
    'statusClass': statusClass,
    'phone': phone,
    'pairingHref': pairingHref,
    'dmAccessMode': dmAccessMode,
    'dmAccessModes': dmAccessModes,
    'dmAllowlist': dmAllowlist,
    'dmAllowlistCount': dmAllowlist.length,
    'groupAccessMode': groupAccessMode,
    'groupAccessModes': groupAccessModes,
    'groupAllowlist': groupAllowlist,
    'groupAllowlistCount': groupAllowlist.length,
    'requireMention': requireMention,
    'entryPlaceholder': entryPlaceholder,
    'groupPlaceholder': groupPlaceholder,
    'showPairingSection': dmAccessMode == 'pairing',
    'pendingPairings': pendingPairings.isNotEmpty ? pendingPairings : null,
    'bannerHtml': bannerHtml.isNotEmpty ? bannerHtml : null,
  });

  return layoutTemplate(title: '$channelLabel Channel', body: body, appName: appName);
}
