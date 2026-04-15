import 'package:dartclaw_config/dartclaw_config.dart';

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
  String provider = 'claude',
  String defaultProvider = 'claude',
  int? inputTokens,
  int? outputTokens,
  double? estimatedCostUsd,
  int? cachedInputTokens,
  String bannerHtml = '',
  List<Map<String, String>> recentTurns = const [],
  String appName = 'DartClaw',
}) {
  final displayTitle = sessionTitle.trim().isEmpty ? 'New Chat' : sessionTitle;
  final totalTokens = (inputTokens ?? 0) + (outputTokens ?? 0);
  final normalizedDefaultProvider = ProviderIdentity.normalize(defaultProvider);
  final normalizedProvider = ProviderIdentity.normalize(provider, fallback: normalizedDefaultProvider);
  final templateEstimatedCostUsd = normalizedProvider == 'claude' && (estimatedCostUsd ?? 0) > 0
      ? estimatedCostUsd
      : null;
  final hasEstimatedCost = templateEstimatedCostUsd != null;
  final estimatedCostDisplay = templateEstimatedCostUsd != null
      ? '\$${templateEstimatedCostUsd.toStringAsFixed(2)}'
      : null;
  final hasCachedTokens = (cachedInputTokens ?? 0) > 0;

  final sidebar = buildSidebar(sidebarData: sidebarData, navItems: navItems, appName: appName);

  final topbar = pageTopbarTemplate(title: 'Session Info', backHref: '/sessions/$sessionId', backLabel: 'Back to Chat');

  final body = templateLoader.trellis.render(templateLoader.source('session_info'), {
    'sidebar': sidebar,
    'topbar': topbar,
    'title': displayTitle,
    'sessionId': sessionId,
    'inputStr': inputTokens != null ? _formatNumber(inputTokens) : '\u2014',
    'outputStr': outputTokens != null ? _formatNumber(outputTokens) : '\u2014',
    'totalStr': totalTokens > 0 ? _formatNumber(totalTokens) : '\u2014',
    'provider': normalizedProvider,
    'providerLabel': ProviderIdentity.displayName(normalizedProvider),
    'estimatedCostUsd': templateEstimatedCostUsd,
    'hasEstimatedCost': hasEstimatedCost,
    'estimatedCostDisplay': estimatedCostDisplay,
    'cachedInputTokens': cachedInputTokens,
    'hasCachedTokens': hasCachedTokens,
    'cachedTokensDisplay': hasCachedTokens ? _formatNumber(cachedInputTokens!) : null,
    'costUnavailableTooltip':
        'This provider does not report USD cost. Token counts are tracked for governance budgets.',
    'messageCount': messageCount.toString(),
    'createdAt': createdAt ?? '\u2014',
    'bannerHtml': bannerHtml.isNotEmpty ? bannerHtml : null,
    'hasRecentTurns': recentTurns.isNotEmpty,
    'recentTurns': recentTurns,
  });

  return layoutTemplate(title: 'Session Info', body: body, appName: appName, scripts: standardShellScripts());
}

String _formatNumber(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
  return n.toString();
}
