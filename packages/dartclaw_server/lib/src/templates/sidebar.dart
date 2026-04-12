import 'package:dartclaw_config/dartclaw_config.dart';

import 'helpers.dart';
import 'loader.dart';

/// Navigation item for sidebar system links.
typedef NavItem = ({String label, String href, bool active, String navGroup, String? icon});

/// Session entry for sidebar rendering, carrying type info.
typedef SidebarSession = ({String id, String title, SessionType type, String provider});

/// Partitioned session data for sidebar rendering.
typedef SidebarData = ({
  SidebarSession? main,
  List<SidebarSession> dmChannels,
  List<SidebarSession> groupChannels,
  List<SidebarSession> activeEntries,
  List<SidebarSession> archivedEntries,
  bool showChannels,
  bool tasksEnabled,
});

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
  bool showChannels = true,
  bool tasksEnabled = false,
  String? activeSessionId,
  List<NavItem> navItems = const [],
  String appName = 'DartClaw',
}) {
  final systemNavItems = navItems.where((item) => item.navGroup == 'system').toList();
  final extensionNavItems = navItems.where((item) => item.navGroup != 'system').toList();

  Map<String, Object?> mapChannel(SidebarSession ch) {
    final trimmed = ch.title.trim();
    return {
      'title': trimmed.isEmpty ? 'Channel' : trimmed,
      'href': '/sessions/${ch.id}',
      'active': ch.id == activeSessionId,
      'provider': ch.provider,
      'providerLabel': ProviderIdentity.displayName(ch.provider),
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
      'title': trimmed.isEmpty ? 'New Chat' : trimmed,
      'provider': entry.provider,
      'providerLabel': ProviderIdentity.displayName(entry.provider),
    };
  }).toList();

  // Build archived entries list.
  final archiveList = archivedEntries.map((entry) {
    final trimmed = entry.title.trim();
    final isActive = entry.id == activeSessionId;
    return {
      'id': entry.id,
      'href': '/sessions/${entry.id}',
      'active': isActive,
      'extraClass': isActive ? 'active' : '',
      'title': trimmed.isEmpty ? 'Archived session' : trimmed,
      'provider': entry.provider,
      'providerLabel': ProviderIdentity.displayName(entry.provider),
    };
  }).toList();

  final archiveContainsActive = activeSessionId != null && archivedEntries.any((e) => e.id == activeSessionId);

  final aside = templateLoader.trellis.renderFragment(
    templateLoader.source('sidebar'),
    fragment: 'sidebar',
    context: {
      'appName': appName,
      'mainSession': mainSession != null,
      'mainHref': mainSession != null ? '/sessions/${mainSession.id}' : '',
      'mainActive': mainSession != null && mainSession.id == activeSessionId,
      'mainProvider': mainSession?.provider,
      'mainProviderLabel': mainSession != null ? ProviderIdentity.displayName(mainSession.provider) : null,
      'tasksEnabledAttr': tasksEnabled ? 'true' : null,
      'showChannels': showChannels,
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
      'showSystemNav': systemNavItems.isNotEmpty,
      'showExtensionNav': extensionNavItems.isNotEmpty,
      'systemNavItems': systemNavItems.map((item) {
        // Inject hidden badge spans for Tasks and Workflows nav items (populated by JS via SSE).
        final labelHtml = item.label == 'Tasks'
            ? '${escapeHtml(item.label)}<span id="tasks-badge" class="nav-badge" style="display:none"></span>'
            : item.label == 'Workflows'
            ? '${escapeHtml(item.label)}<span id="workflows-badge" class="nav-badge" style="display:none"></span>'
            : escapeHtml(item.label);
        return {
          'label': labelHtml,
          'href': item.href,
          'active': item.active,
          'ariaCurrent': item.active ? 'page' : null,
          'icon': item.icon,
        };
      }).toList(),
      'extensionNavItems': extensionNavItems.map((item) {
        return {
          'label': item.label,
          'href': item.href,
          'active': item.active,
          'ariaCurrent': item.active ? 'page' : null,
          'icon': item.icon,
        };
      }).toList(),
    },
  );
  // The scrim must be a sibling of <aside class="sidebar"> so the CSS combinator
  // `.sidebar.open ~ .sidebar-scrim` can show it. Appending here covers all
  // render paths (direct string injection in web_routes.dart and tl:utext in HTML templates).
  return '$aside<button class="sidebar-scrim" type="button" aria-label="Close sidebar"></button>';
}

/// Builds the unified sidebar from [SidebarData] and system nav items.
///
/// Used by system/admin pages (Settings, Health, etc.) that show the
/// full sidebar with sessions but no active session highlighted.
String buildSidebar({required SidebarData sidebarData, required List<NavItem> navItems, String appName = 'DartClaw'}) {
  return sidebarTemplate(
    mainSession: sidebarData.main,
    dmChannels: sidebarData.dmChannels,
    groupChannels: sidebarData.groupChannels,
    activeEntries: sidebarData.activeEntries,
    archivedEntries: sidebarData.archivedEntries,
    showChannels: sidebarData.showChannels,
    tasksEnabled: sidebarData.tasksEnabled,
    navItems: navItems,
    appName: appName,
  );
}
