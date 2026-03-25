import 'package:dartclaw_core/dartclaw_core.dart';

import 'components.dart';
import 'helpers.dart';
import 'layout.dart';
import 'loader.dart';
import 'sidebar.dart';
import 'topbar.dart';

/// Renders the task detail page with embedded chat view, artifacts, and review controls.
///
/// [tokenSummary] is optional aggregate trace data. When non-null and
/// `traceCount > 0`, a token summary card is rendered between the meta card
/// and the action bar.
///
/// [initialTokensUsed], [initialActivity], and [tokenBudget] provide the
/// initial progress state for running tasks. These are computed from
/// `TaskEventService` by the page handler.
String taskDetailPageTemplate({
  required SidebarData sidebarData,
  required List<NavItem> navItems,
  required Map<String, dynamic> task,
  required List<Map<String, dynamic>> artifacts,
  List<Map<String, dynamic>>? bindings,
  Map<String, dynamic>? conflictData,
  Map<String, dynamic>? tokenSummary,
  String? messagesHtml,
  String? timelineHtml,
  String bannerHtml = '',
  String appName = 'DartClaw',
  String defaultProvider = 'claude',
  int initialTokensUsed = 0,
  String? initialActivity,
  int? tokenBudget,
}) {
  final sidebar = buildSidebar(sidebarData: sidebarData, navItems: navItems, appName: appName);
  final title = task['title']?.toString() ?? 'Task';
  final topbar = pageTopbarTemplate(title: 'Task: $title', backHref: '/tasks', backLabel: 'Back to Tasks');
  final statusName = task['status']?.toString() ?? 'draft';
  final isDraft = statusName == 'draft';
  final isQueued = statusName == 'queued';
  final isReview = statusName == 'review';
  final isRunning = statusName == 'running';
  final isInterrupted = statusName == 'interrupted';
  final isCancellable = switch (statusName) {
    'draft' || 'queued' || 'running' || 'interrupted' => true,
    _ => false,
  };
  final provider = ProviderIdentity.normalize(task['provider']?.toString(), fallback: defaultProvider);
  final hasSession = task['sessionId'] != null && (task['sessionId'] as String).isNotEmpty;
  final pushBackCount = (task['pushBackCount'] as num?)?.toInt() ?? 0;
  final showPushBackWarning = pushBackCount >= 3;
  final bindingItems = (bindings ?? const <Map<String, dynamic>>[])
      .map(
        (binding) => {
          'channelLabel': _channelTypeLabel(binding['channelType']?.toString() ?? ''),
          'threadId': _truncateBindingId(binding['threadId']?.toString() ?? ''),
        },
      )
      .toList(growable: false);
  final conflictingFiles =
      (conflictData?['conflictingFiles'] as List?)?.map((entry) => entry.toString()).toList(growable: false) ??
      const <String>[];
  final conflictDetails = conflictData?['details']?.toString();
  final noSessionTitle = switch (statusName) {
    'queued' => 'Task queued',
    'running' => 'Session starting',
    'interrupted' => 'Task interrupted',
    _ => 'Session not started',
  };
  final noSessionText = switch (statusName) {
    'queued' => 'Waiting for an available runner. Session messages will appear automatically.',
    'running' => 'The task is starting up. Session messages will appear automatically.',
    'interrupted' => 'The previous run stopped unexpectedly. You can cancel or re-queue this task.',
    _ => 'This task has not been started yet. No session messages to display.',
  };

  // Build token summary data if available.
  final traceCount = (tokenSummary?['traceCount'] as num?)?.toInt() ?? 0;
  final hasTokenSummary = traceCount > 0;
  final totalTokens = (tokenSummary?['totalTokens'] as num?)?.toInt() ?? 0;
  final totalInputTokens = (tokenSummary?['totalInputTokens'] as num?)?.toInt() ?? 0;
  final totalOutputTokens = (tokenSummary?['totalOutputTokens'] as num?)?.toInt() ?? 0;
  final totalCacheReadTokens = (tokenSummary?['totalCacheReadTokens'] as num?)?.toInt() ?? 0;
  final totalCacheWriteTokens = (tokenSummary?['totalCacheWriteTokens'] as num?)?.toInt() ?? 0;
  final totalDurationMs = (tokenSummary?['totalDurationMs'] as num?)?.toInt() ?? 0;
  final totalToolCalls = (tokenSummary?['totalToolCalls'] as num?)?.toInt() ?? 0;
  final hasCacheTokens = totalCacheReadTokens > 0 || totalCacheWriteTokens > 0;

  // Build progress section data.
  final effectiveBudget = (tokenBudget != null && tokenBudget > 0) ? tokenBudget : null;
  final hasTokenBudget = effectiveBudget != null;
  final initialProgressPct = hasTokenBudget
      ? (initialTokensUsed / effectiveBudget * 100).round().clamp(0, 100)
      : 0;
  final initialProgressFillClass = hasTokenBudget ? '' : 'indeterminate';
  final initialProgressLabel = hasTokenBudget
      ? '${formatNumber(initialTokensUsed)} / ${formatNumber(effectiveBudget)} tokens ($initialProgressPct%)'
      : '${formatNumber(initialTokensUsed)} tokens used';
  final progressSectionStyle = isRunning ? '' : 'display:none';

  // Build artifact items for template.
  final artifactItems = artifacts.map((a) {
    final kind = a['kind']?.toString() ?? 'data';
    return {
      ...a,
      'kindLabel': kind[0].toUpperCase() + kind.substring(1),
      'isDiff': kind == 'diff',
      'isDocument': kind == 'document',
      'isData': kind == 'data',
      'content': a['content']?.toString(),
      'hasContent': a['content'] != null && (a['content'] as String).isNotEmpty,
      'renderedHtml': a['renderedHtml']?.toString(),
      'hasRenderedHtml': a['renderedHtml'] != null && (a['renderedHtml'] as String).isNotEmpty,
    };
  }).toList();

  final body = templateLoader.trellis.render(templateLoader.source('task_detail'), {
    'sidebar': sidebar,
    'topbar': topbar,
    'bannerHtml': bannerHtml.isNotEmpty ? bannerHtml : null,
    'taskId': task['id'],
    'title': title,
    'typeLabel': titleCase(task['type']?.toString() ?? ''),
    'status': statusName,
    'statusBadgeHtml': statusBadgeTemplate(variant: statusName, text: titleCase(statusName)),
    'provider': provider,
    'providerLabel': ProviderIdentity.displayName(provider),
    'hasProvider': provider.isNotEmpty,
    'goalTitle': task['goalTitle']?.toString(),
    'description': task['description']?.toString() ?? '',
    'acceptanceCriteria': task['acceptanceCriteria']?.toString(),
    'pushBackCount': pushBackCount,
    'hasPushBacks': pushBackCount > 0,
    'showPushBackWarning': showPushBackWarning,
    'hasBindings': bindingItems.isNotEmpty,
    'bindings': bindingItems,
    'createdAtDisplay': _formatRelativeTimeIso(task['createdAt']?.toString()),
    'createdByDisplay': task['createdBy']?.toString() ?? '—',
    'startedAtDisplay': _formatRelativeTimeIso(task['startedAt']?.toString()),
    'completedAtDisplay': _formatRelativeTimeIso(task['completedAt']?.toString()),
    'startedAtIso': task['startedAt']?.toString(),
    'hasStartedAt': task['startedAt'] != null,
    'hasCompletedAt': task['completedAt'] != null,
    'isDraft': isDraft,
    'isQueued': isQueued,
    'isReview': isReview,
    'isRunning': isRunning,
    'isInterrupted': isInterrupted,
    'isCancellable': isCancellable,
    'hasSession': hasSession,
    'messagesHtml': messagesHtml,
    'noSessionTitle': noSessionTitle,
    'noSessionText': noSessionText,
    'hasArtifacts': artifactItems.isNotEmpty,
    'artifacts': artifactItems,
    'hasConflict': conflictingFiles.isNotEmpty,
    'conflictingFiles': conflictingFiles,
    'conflictDetails': conflictDetails,
    'hasTokenSummary': hasTokenSummary,
    'traceCount': traceCount,
    'totalTokens': formatNumber(totalTokens),
    'totalInputTokens': formatNumber(totalInputTokens),
    'totalOutputTokens': formatNumber(totalOutputTokens),
    'totalCacheReadTokens': formatNumber(totalCacheReadTokens),
    'totalCacheWriteTokens': formatNumber(totalCacheWriteTokens),
    'hasCacheTokens': hasCacheTokens,
    'totalDurationDisplay': _formatDuration(totalDurationMs),
    'totalToolCalls': totalToolCalls,
    'timelineHtml': timelineHtml,
    'hasTimeline': timelineHtml != null && timelineHtml.isNotEmpty,
    // Progress section.
    'progressSectionStyle': progressSectionStyle,
    'initialActivity': initialActivity ?? 'Starting...',
    'initialProgressLabel': initialProgressLabel,
    'initialProgressFillClass': initialProgressFillClass,
    'initialProgressPct': initialProgressPct,
  });

  return layoutTemplate(title: 'Task: $title', body: body, appName: appName);
}

String _formatDuration(int ms) {
  if (ms <= 0) return '0s';
  final seconds = ms ~/ 1000;
  if (seconds < 60) return '${seconds}s';
  final minutes = seconds ~/ 60;
  final remainingSeconds = seconds % 60;
  if (remainingSeconds == 0) return '${minutes}m';
  return '${minutes}m ${remainingSeconds}s';
}

String _formatRelativeTimeIso(String? iso) {
  if (iso == null) return '';
  try {
    return formatRelativeTime(DateTime.parse(iso));
  } catch (e) {
    return '';
  }
}

String _channelTypeLabel(String channelType) {
  return switch (channelType) {
    'googlechat' => 'Google Chat',
    'whatsapp' => 'WhatsApp',
    'signal' => 'Signal',
    _ => titleCase(channelType),
  };
}

String _truncateBindingId(String threadId) {
  if (threadId.length <= 42) return threadId;
  return '${threadId.substring(0, 39)}...';
}
