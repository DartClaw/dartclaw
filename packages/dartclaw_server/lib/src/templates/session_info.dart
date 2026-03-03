import 'layout.dart';
import 'loader.dart';
import 'sidebar.dart';
import 'topbar.dart';

/// Renders the session info standalone page.
String sessionInfoTemplate({
  required String sessionId,
  required String sessionTitle,
  required int messageCount,
  required SidebarData sidebarData,
  List<NavItem> navItems = const [],
  String? createdAt,
  int? inputTokens,
  int? outputTokens,
}) {
  final displayTitle = sessionTitle.trim().isEmpty ? 'New Session' : sessionTitle;
  final totalTokens = (inputTokens ?? 0) + (outputTokens ?? 0);

  final sidebar = sidebarTemplate(
    mainSession: sidebarData.main,
    channelSessions: sidebarData.channels,
    sessionEntries: sidebarData.entries,
    activeSessionId: sessionId,
    navItems: navItems,
  );

  final topbar = pageTopbarTemplate(
    title: 'Session Info',
    backHref: '/sessions/$sessionId',
    backLabel: 'Back to Chat',
  );

  final body = templateLoader.trellis.render(templateLoader.source('session_info'), {
    'sidebar': sidebar,
    'topbar': topbar,
    'title': displayTitle,
    'sessionId': sessionId,
    'inputStr': inputTokens != null ? _formatNumber(inputTokens) : '\u2014',
    'outputStr': outputTokens != null ? _formatNumber(outputTokens) : '\u2014',
    'totalStr': totalTokens > 0 ? _formatNumber(totalTokens) : '\u2014',
    'messageCount': messageCount.toString(),
    'createdAt': createdAt ?? '\u2014',
  });

  return layoutTemplate(title: 'Session Info', body: body);
}

String _formatNumber(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
  return n.toString();
}
