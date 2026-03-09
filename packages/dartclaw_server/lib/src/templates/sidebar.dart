import 'package:dartclaw_core/dartclaw_core.dart';

import 'loader.dart';

/// Navigation item for sidebar system links.
typedef NavItem = ({String label, String href, bool active});

/// Session entry for sidebar rendering, carrying type info.
typedef SidebarSession = ({String id, String title, SessionType type});

/// Partitioned session data for sidebar rendering.
typedef SidebarData = ({
  SidebarSession? main,
  List<SidebarSession> dmChannels,
  List<SidebarSession> groupChannels,
  List<SidebarSession> activeEntries,
  List<SidebarSession> archivedEntries,
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
/// - [dmChannels]: DM channel sessions
/// - [groupChannels]: group channel sessions
/// - [activeEntries]: user sessions (pre-sorted by updatedAt desc)
/// - [archivedEntries]: archived sessions (pre-sorted by updatedAt desc)
/// - [navItems]: system navigation links
///
/// All session links carry HTMX SPA navigation attributes for partial page swap.
/// All dynamic values are auto-escaped by Trellis (`tl:text`, `tl:attr`).
String sidebarTemplate({
  SidebarSession? mainSession,
  List<SidebarSession> dmChannels = const [],
  List<SidebarSession> groupChannels = const [],
  List<SidebarSession> activeEntries = const [],
  List<SidebarSession> archivedEntries = const [],
  String? activeSessionId,
  List<NavItem> navItems = const [],
  String appName = 'DartClaw',
}) {
  Map<String, Object?> mapChannel(SidebarSession ch) {
    final trimmed = ch.title.trim();
    return {
      'title': trimmed.isEmpty ? 'Channel' : trimmed,
      'href': '/sessions/${ch.id}',
      'active': ch.id == activeSessionId,
    };
  }

  final dmList = dmChannels.map(mapChannel).toList();
  final groupList = groupChannels.map(mapChannel).toList();

  // Build active entries list (user sessions only — all get delete button).
  final activeList = activeEntries.map((entry) {
    final trimmed = entry.title.trim();
    final isActive = entry.id == activeSessionId;
    return {
      'id': entry.id,
      'href': '/sessions/${entry.id}',
      'active': isActive,
      'extraClass': isActive ? 'active' : '',
      'title': trimmed.isEmpty ? 'New Session' : trimmed,
    };
  }).toList();

  // Build archived entries list (no delete button).
  final archiveList = archivedEntries.map((entry) {
    final trimmed = entry.title.trim();
    final isActive = entry.id == activeSessionId;
    return {
      'id': entry.id,
      'href': '/sessions/${entry.id}',
      'active': isActive,
      'extraClass': isActive ? 'active' : '',
      'title': trimmed.isEmpty ? 'Archived session' : trimmed,
    };
  }).toList();

  final archiveContainsActive = activeSessionId != null &&
      archivedEntries.any((e) => e.id == activeSessionId);

  return templateLoader.trellis.renderFragment(
    templateLoader.source('sidebar'),
    fragment: 'sidebar',
    context: {
      'appName': appName,
      'mainSession': mainSession != null,
      'mainHref': mainSession != null ? '/sessions/${mainSession.id}' : '',
      'mainActive': mainSession != null && mainSession.id == activeSessionId,
      'noChannels': dmChannels.isEmpty && groupChannels.isEmpty,
      'noDmChannels': dmChannels.isEmpty,
      'hasGroupChannels': groupChannels.isNotEmpty,
      'showDmLabel': groupChannels.isNotEmpty && dmChannels.isNotEmpty,
      'dmChannels': dmList,
      'groupChannels': groupList,
      'noActiveEntries': activeEntries.isEmpty,
      'activeEntries': activeList,
      'hasArchivedEntries': archivedEntries.isNotEmpty,
      'archivedEntries': archiveList,
      'archivedCount': archivedEntries.length,
      'archiveContainsActive': archiveContainsActive,
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
    dmChannels: sidebarData.dmChannels,
    groupChannels: sidebarData.groupChannels,
    activeEntries: sidebarData.activeEntries,
    archivedEntries: sidebarData.archivedEntries,
    navItems: navItems,
    appName: appName,
  );
}
