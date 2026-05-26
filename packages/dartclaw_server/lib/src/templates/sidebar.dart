import 'package:dartclaw_config/dartclaw_config.dart';

import 'helpers.dart';
import 'loader.dart';

/// Navigation item for sidebar system links.
typedef NavItem = ({String label, String href, bool active, String navGroup, String? icon});

/// Session entry for sidebar rendering, carrying type info.
typedef SidebarSession = ({String id, String title, SessionType type, String provider});

/// Active task summary for the live sidebar sections.
typedef SidebarActiveTask = ({
  String id,
  String title,
  String status,
  String? startedAt,
  String provider,
  String providerLabel,
});

/// Active workflow summary for the live sidebar sections.
typedef SidebarActiveWorkflow = ({String id, String definitionName, String status, int completedSteps, int totalSteps});

/// Partitioned session data for sidebar rendering.
typedef SidebarData = ({
  SidebarSession? main,
  List<SidebarSession> dmChannels,
  List<SidebarSession> groupChannels,
  List<SidebarSession> activeEntries,
  List<SidebarSession> archivedEntries,
  List<SidebarActiveTask> activeTasks,
  List<SidebarActiveWorkflow> activeWorkflows,
  bool showChannels,
  bool tasksEnabled,
  String? activeSessionId,
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
  SidebarData? sidebarData,
  SidebarSession? mainSession,
  List<SidebarSession> dmChannels = const [],
  List<SidebarSession> groupChannels = const [],
  List<SidebarSession> activeEntries = const [],
  List<SidebarSession> archivedEntries = const [],
  List<SidebarActiveTask> activeTasks = const [],
  List<SidebarActiveWorkflow> activeWorkflows = const [],
  bool showChannels = true,
  bool tasksEnabled = false,
  String? activeSessionId,
  List<NavItem> navItems = const [],
  String appName = 'DartClaw',
}) {
  final resolvedMainSession = sidebarData?.main ?? mainSession;
  final resolvedDmChannels = sidebarData?.dmChannels ?? dmChannels;
  final resolvedGroupChannels = sidebarData?.groupChannels ?? groupChannels;
  final resolvedActiveEntries = sidebarData?.activeEntries ?? activeEntries;
  final resolvedArchivedEntries = sidebarData?.archivedEntries ?? archivedEntries;
  final resolvedActiveTasks = sidebarData?.activeTasks ?? activeTasks;
  final resolvedActiveWorkflows = sidebarData?.activeWorkflows ?? activeWorkflows;
  final resolvedShowChannels = sidebarData?.showChannels ?? showChannels;
  final resolvedTasksEnabled = sidebarData?.tasksEnabled ?? tasksEnabled;
  final resolvedActiveSessionId = sidebarData?.activeSessionId ?? activeSessionId;
  final systemNavItems = navItems.where((item) => item.navGroup == 'system').toList();
  final extensionNavItems = navItems.where((item) => item.navGroup != 'system').toList();

  Map<String, Object?> mapChannel(SidebarSession ch) {
    final trimmed = ch.title.trim();
    return {
      'title': trimmed.isEmpty ? 'Channel' : trimmed,
      'href': '/sessions/${ch.id}',
      'active': ch.id == resolvedActiveSessionId,
      'provider': ch.provider,
      'providerLabel': ProviderIdentity.displayName(ch.provider),
    };
  }

  final dmList = resolvedDmChannels.map(mapChannel).toList();
  final groupList = resolvedGroupChannels.map(mapChannel).toList();

  // Build active entries list (user sessions only — all get delete button).
  final activeList = resolvedActiveEntries.map((entry) {
    final trimmed = entry.title.trim();
    final isActive = entry.id == resolvedActiveSessionId;
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
  final archiveList = resolvedArchivedEntries.map((entry) {
    final trimmed = entry.title.trim();
    final isActive = entry.id == resolvedActiveSessionId;
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

  final archiveContainsActive =
      resolvedActiveSessionId != null && resolvedArchivedEntries.any((e) => e.id == resolvedActiveSessionId);
  final activeTaskList = resolvedActiveTasks
      .map(
        (task) => {
          'href': '/tasks/${task.id}',
          'title': task.title.trim().isEmpty ? 'Untitled Task' : task.title.trim(),
          'isReview': task.status == 'review',
          'startedAt': task.startedAt,
          'provider': task.provider,
          'providerLabel': task.providerLabel,
        },
      )
      .toList();
  final activeWorkflowList = resolvedActiveWorkflows
      .map(
        (workflow) => {
          'href': '/workflows/${workflow.id}',
          'title': workflow.definitionName.trim().isEmpty ? 'Workflow' : workflow.definitionName.trim(),
          'isPaused': workflow.status == 'paused',
          'progress': '${workflow.completedSteps}/${workflow.totalSteps}',
        },
      )
      .toList();

  final aside = templateLoader.trellis.renderFragment(
    templateLoader.source('sidebar'),
    fragment: 'sidebar',
    context: {
      'appName': appName,
      'mainSession': resolvedMainSession != null,
      'mainHref': resolvedMainSession != null ? '/sessions/${resolvedMainSession.id}' : '',
      'mainActive': resolvedMainSession != null && resolvedMainSession.id == resolvedActiveSessionId,
      'mainProvider': resolvedMainSession?.provider,
      'mainProviderLabel': resolvedMainSession != null
          ? ProviderIdentity.displayName(resolvedMainSession.provider)
          : null,
      'tasksEnabledAttr': resolvedTasksEnabled ? 'true' : null,
      'showChannels': resolvedShowChannels,
      'noChannels': resolvedDmChannels.isEmpty && resolvedGroupChannels.isEmpty,
      'noDmChannels': resolvedDmChannels.isEmpty,
      'hasGroupChannels': resolvedGroupChannels.isNotEmpty,
      'showDmLabel': resolvedGroupChannels.isNotEmpty && resolvedDmChannels.isNotEmpty,
      'dmChannels': dmList,
      'groupChannels': groupList,
      'noActiveEntries': resolvedActiveEntries.isEmpty,
      'activeEntries': activeList,
      'hasArchivedEntries': resolvedArchivedEntries.isNotEmpty,
      'archivedEntries': archiveList,
      'archivedCount': resolvedArchivedEntries.length,
      'archiveContainsActive': archiveContainsActive,
      'hasActiveTasks': activeTaskList.isNotEmpty,
      'activeTasks': activeTaskList,
      'hasActiveWorkflows': activeWorkflowList.isNotEmpty,
      'activeWorkflows': activeWorkflowList,
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
  return sidebarTemplate(sidebarData: sidebarData, navItems: navItems, appName: appName);
}
