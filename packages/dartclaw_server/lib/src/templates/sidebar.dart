import 'package:dartclaw_core/dartclaw_core.dart';

import 'helpers.dart';

/// Session entry for sidebar rendering, carrying type info.
typedef SidebarSession = ({String id, String title, SessionType type});

/// Partitioned session data for sidebar rendering.
typedef SidebarData = ({
  SidebarSession? main,
  List<SidebarSession> channels,
  List<SidebarSession> entries,
});

/// Sidebar with typed session sections.
///
/// - [mainSession]: pinned at top (always present after startup)
/// - [channelSessions]: channel sessions (WhatsApp etc.)
/// - [sessionEntries]: unified list of user + archive sessions, pre-sorted by updatedAt desc
/// - [navItems]: system navigation links
String sidebarTemplate({
  SidebarSession? mainSession,
  List<SidebarSession> channelSessions = const [],
  List<SidebarSession> sessionEntries = const [],
  String? activeSessionId,
  List<({String label, String href, bool active})> navItems = const [],
}) {
  final buf = StringBuffer();

  // --- Main session (pinned) ---
  if (mainSession != null) {
    final isActive = mainSession.id == activeSessionId;
    final activeClass = isActive ? ' active' : '';
    final escapedId = htmlEscape(mainSession.id);
    buf.writeln(
      '  <div class="session-item session-item-main$activeClass">'
      '<a href="/sessions/$escapedId" class="session-item-link">'
      '<span class="session-item-title">Main</span></a>'
      '</div>',
    );
  }

  buf.writeln('  <hr class="sidebar-divider">');

  // --- Channels section ---
  buf.writeln('  <div class="sidebar-section-label">Channels</div>');
  if (channelSessions.isEmpty) {
    buf.writeln('  <div class="sidebar-placeholder">No active channels</div>');
  } else {
    for (final ch in channelSessions) {
      final trimmed = ch.title.trim();
      final title = trimmed.isEmpty ? 'Channel' : htmlEscape(trimmed);
      final escapedId = htmlEscape(ch.id);
      final isActive = ch.id == activeSessionId;
      final activeClass = isActive ? ' active' : '';
      buf.writeln(
        '  <div class="session-item session-item-channel$activeClass">'
        '<a href="/sessions/$escapedId" class="session-item-link">'
        '<span class="session-item-title">$title</span></a>'
        '</div>',
      );
    }
  }

  buf.writeln('  <hr class="sidebar-divider">');

  // --- Sessions section (user + archives, unified) ---
  buf.writeln('  <div class="sidebar-section-label">Sessions</div>');
  buf.writeln('  <button class="btn btn-ghost btn-new-session" data-action="create-session">+ New Session</button>');

  if (sessionEntries.isEmpty) {
    buf.writeln('  <div class="sidebar-placeholder">No sessions yet</div>');
  } else {
    for (final entry in sessionEntries) {
      final trimmed = entry.title.trim();
      final isActive = entry.id == activeSessionId;
      final activeClass = isActive ? ' active' : '';
      final escapedId = htmlEscape(entry.id);

      if (entry.type == SessionType.archive) {
        final title = trimmed.isEmpty ? 'Archived session' : htmlEscape(trimmed);
        buf.writeln(
          '  <div class="session-item session-item-archive$activeClass">'
          '<a href="/sessions/$escapedId" class="session-item-link">'
          '<span class="session-item-title">$title</span></a>'
          '</div>',
        );
      } else {
        final title = trimmed.isEmpty ? 'New Session' : htmlEscape(trimmed);
        buf.writeln(
          '  <div class="session-item$activeClass">'
          '<a href="/sessions/$escapedId" class="session-item-link">'
          '<span class="session-item-title">$title</span></a>'
          '<button class="session-delete" data-action="delete-session" '
          'data-session-id="$escapedId" aria-label="Delete session">&#215;</button>'
          '</div>',
        );
      }
    }
  }

  // --- System nav ---
  final navSection = StringBuffer();
  if (navItems.isNotEmpty) {
    navSection.write('  <nav class="sidebar-section" aria-label="System navigation">\n');
    navSection.write('    <div class="sidebar-section-label">System</div>\n');
    for (final item in navItems) {
      final activeClass = item.active ? ' active' : '';
      final ariaCurrent = item.active ? ' aria-current="page"' : '';
      navSection.write(
        '    <a href="${htmlEscape(item.href)}" class="sidebar-nav-item$activeClass"$ariaCurrent>'
        '${htmlEscape(item.label)}</a>\n',
      );
    }
    navSection.write('  </nav>\n');
  }

  return '''
<aside class="sidebar" id="sidebar">
  <div class="sidebar-header">
    <span class="logo">&#10095; DartClaw</span>
    <button class="btn btn-icon btn-ghost sidebar-close" aria-label="Close sidebar">&#215;</button>
  </div>
$buf$navSection</aside>
''';
}
