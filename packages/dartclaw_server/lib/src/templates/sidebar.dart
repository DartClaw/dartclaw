import 'package:dartclaw_core/dartclaw_core.dart';

import 'loader.dart';

/// Navigation item for sidebar system links.
typedef NavItem = ({String label, String href, bool active});

/// Session entry for sidebar rendering, carrying type info.
typedef SidebarSession = ({String id, String title, SessionType type});

/// Partitioned session data for sidebar rendering.
typedef SidebarData = ({
  SidebarSession? main,
  List<SidebarSession> channels,
  List<SidebarSession> entries,
});

/// Builds the canonical system navigation items for the sidebar.
///
/// [activePage] determines which item gets `active: true` — must match
/// one of the label values exactly (e.g. `'Health'`, `'Settings'`,
/// `'Scheduling'`).
List<NavItem> buildSystemNavItems({required String activePage}) => [
      (label: 'Health', href: '/health-dashboard', active: activePage == 'Health'),
      (label: 'Settings', href: '/settings', active: activePage == 'Settings'),
      (label: 'Memory', href: '/memory', active: activePage == 'Memory'),
      (label: 'Scheduling', href: '/scheduling', active: activePage == 'Scheduling'),
    ];

/// Sidebar with typed session sections.
///
/// - [mainSession]: pinned at top (always present after startup)
/// - [channelSessions]: channel sessions (WhatsApp etc.)
/// - [sessionEntries]: unified list of user + archive sessions, pre-sorted by updatedAt desc
/// - [navItems]: system navigation links
///
/// All session links carry HTMX SPA navigation attributes for partial page swap.
/// All dynamic values are auto-escaped by Trellis (`tl:text`, `tl:attr`).
String sidebarTemplate({
  SidebarSession? mainSession,
  List<SidebarSession> channelSessions = const [],
  List<SidebarSession> sessionEntries = const [],
  String? activeSessionId,
  List<NavItem> navItems = const [],
  String appName = 'DartClaw',
}) {
  final channels = channelSessions.map((ch) {
    final trimmed = ch.title.trim();
    return {
      'title': trimmed.isEmpty ? 'Channel' : trimmed,
      'href': '/sessions/${ch.id}',
      'active': ch.id == activeSessionId,
    };
  }).toList();

  // Build unified entries list preserving the original sort order.
  // Archives get session-item-archive class and no delete button;
  // user sessions get a delete button.
  final entries = sessionEntries.map((entry) {
    final trimmed = entry.title.trim();
    final isArchive = entry.type == SessionType.archive;
    final isActive = entry.id == activeSessionId;
    final extraClass = [
      if (isArchive) 'session-item-archive',
      if (isActive) 'active',
    ].join(' ');
    return {
      'id': entry.id,
      'href': '/sessions/${entry.id}',
      'active': isActive,
      'isArchive': isArchive,
      'extraClass': extraClass,
      'title': isArchive
          ? (trimmed.isEmpty ? 'Archived session' : trimmed)
          : (trimmed.isEmpty ? 'New Session' : trimmed),
    };
  }).toList();

  return templateLoader.trellis.renderFragment(
    templateLoader.source('sidebar'),
    fragment: 'sidebar',
    context: {
      'appName': appName,
      'mainSession': mainSession != null,
      'mainHref': mainSession != null ? '/sessions/${mainSession.id}' : '',
      'mainActive': mainSession != null && mainSession.id == activeSessionId,
      'noChannels': channelSessions.isEmpty,
      'channels': channels,
      'noEntries': sessionEntries.isEmpty,
      'entries': entries,
      'hasNav': navItems.isNotEmpty,
      'navItems': navItems.map((item) {
        return {
          'label': item.label,
          'href': item.href,
          'active': item.active,
          'ariaCurrent': item.active ? 'page' : null,
        };
      }).toList(),
    },
  );
}

/// Builds the unified sidebar from [SidebarData] and system nav items.
///
/// Used by system/admin pages (Settings, Health, etc.) that show the
/// full sidebar with sessions but no active session highlighted.
String buildSidebar({
  required SidebarData sidebarData,
  required List<NavItem> navItems,
  String appName = 'DartClaw',
}) {
  return sidebarTemplate(
    mainSession: sidebarData.main,
    channelSessions: sidebarData.channels,
    sessionEntries: sidebarData.entries,
    navItems: navItems,
    appName: appName,
  );
}
