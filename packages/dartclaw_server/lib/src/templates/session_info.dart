import 'package:dartclaw_config/dartclaw_config.dart';

import 'components.dart';
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
  int? effectiveTokens,
  double? estimatedCostUsd,
  int? cachedInputTokens,
  String bannerHtml = '',
  List<Map<String, String>> recentTurns = const [],
  Map<String, dynamic>? turnStatus,
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
  final hasEffectiveTokens = (effectiveTokens ?? 0) > 0;
  final inputLabel = normalizedProvider == 'codex' ? 'Input (fresh)' : 'Input';
  final inputTooltip = normalizedProvider == 'codex'
      ? 'Fresh input tokens only. Cached input is tracked separately below.'
      : null;

  final sidebar = buildSidebar(sidebarData: sidebarData, navItems: navItems, appName: appName);
  final turnStatusView = sessionTurnStatusView(turnStatus, fallbackSessionId: sessionId);

  final topbar = pageTopbarTemplate(title: 'Session Info', backHref: '/sessions/$sessionId', backLabel: 'Back to Chat');

  final body = templateLoader.trellis.render(templateLoader.source('session_info'), {
    'sidebar': sidebar,
    'topbar': topbar,
    'title': displayTitle,
    'sessionId': sessionId,
    'inputLabel': inputLabel,
    'inputTooltip': inputTooltip,
    'tokenMetricCardsHtml': [
      metricCardTemplate(
        color: 'info',
        value: inputTokens != null ? _formatNumber(inputTokens) : '\u2014',
        label: inputLabel,
        labelTooltip: inputTooltip,
      ),
      metricCardTemplate(
        color: 'info',
        value: outputTokens != null ? _formatNumber(outputTokens) : '\u2014',
        label: 'Output',
      ),
      metricCardTemplate(
        color: 'accent',
        value: totalTokens > 0 ? _formatNumber(totalTokens) : '\u2014',
        label: 'Total',
      ),
    ].join('\n'),
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
    'hasEffectiveTokens': hasEffectiveTokens,
    'effectiveTokensDisplay': hasEffectiveTokens ? _formatNumber(effectiveTokens!) : null,
    'effectiveTokensTooltip':
        'Billing-weighted token count. Fresh input counts at 1x, cache writes at 1.25x, cache reads at 0.1x.',
    'costUnavailableTooltip':
        'This provider does not report USD cost. Token counts are tracked for governance budgets.',
    'messageCount': messageCount.toString(),
    'createdAt': createdAt ?? '\u2014',
    'bannerHtml': bannerHtml.isNotEmpty ? bannerHtml : null,
    'hasRecentTurns': recentTurns.isNotEmpty,
    'recentTurns': recentTurns,
    'turnStatus': turnStatusView,
    'hasTurnStatus': turnStatusView != null,
  });

  return layoutTemplate(title: 'Session Info', body: body, appName: appName, scripts: standardShellScripts());
}

Map<String, dynamic>? sessionTurnStatusView(Map<String, dynamic>? status, {required String fallbackSessionId}) {
  if (status == null) return null;
  final state = status['state']?.toString() ?? 'idle';
  if (state == 'idle') return null;
  final reason = status['wait_reason']?.toString();
  final canCancel = status['can_cancel'] == true;
  return {
    'sessionId': status['session_id']?.toString() ?? fallbackSessionId,
    'turnId': status['turn_id']?.toString() ?? '',
    'stateLabel': state.replaceAll('_', ' '),
    'reasonLabel': reason == null ? '—' : reason.replaceAll('_', ' '),
    'waitingSince': status['waiting_since']?.toString() ?? '',
    'stuckSince': status['stuck_since']?.toString() ?? '',
    'globalTimeoutAt': status['global_timeout_at']?.toString() ?? '',
    'canCancel': canCancel,
    'cancelDisabled': canCancel ? null : 'disabled',
  };
}

String _formatNumber(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
  return n.toString();
}
