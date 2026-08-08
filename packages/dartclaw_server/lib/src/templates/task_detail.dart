import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show humanizeDurationMs;

import 'components.dart';
import 'helpers.dart';
import 'layout.dart';
import 'loader.dart';
import 'sidebar.dart';
import 'session_info.dart' show isActiveTurnStatusState;
import 'task_status_display.dart';
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
  Map<String, dynamic>? turnStatus,
  String? messagesHtml,
  String? timelineHtml,
  String restartBannerHtml = '',
  String appName = 'DartClaw',
  String defaultProvider = 'claude',
  int initialTokensUsed = 0,
  String? initialActivity,
  int? tokenBudget,
}) {
  final sidebar = buildSidebar(sidebarData: sidebarData, navItems: navItems, appName: appName);
  final title = task['title']?.toString() ?? 'Task';
  final topbar = pageTopbarTemplate(
    title: 'Task: $title',
    backHref: '/tasks',
    backLabel: 'Back to Tasks',
    restartBannerHtml: restartBannerHtml,
  );
  // Same normalisation the task list groups by, so a status cannot read one way
  // in the table and another here — and an unrecognised one is never presented
  // as a draft, which would offer a Start button for a task nobody can start.
  final statusName = taskStatusKey(task['status']);
  final statusPresentation = taskStatusPresentation(task['status']);
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
  final tokenMetricCardsHtml = [
    metricCardTemplate(color: 'accent', value: formatNumber(totalTokens), label: 'Total Tokens'),
    metricCardTemplate(
      color: 'info',
      value: '${formatNumber(totalInputTokens)} / ${formatNumber(totalOutputTokens)}',
      label: 'Input / Output',
      labelTooltip: 'Input tokens / output tokens',
    ),
    if (hasCacheTokens)
      metricCardTemplate(
        color: 'info',
        value: '${formatNumber(totalCacheReadTokens)} / ${formatNumber(totalCacheWriteTokens)}',
        label: 'Cache Read / Write',
        labelTooltip: 'Cache read tokens / cache write tokens',
      ),
    metricCardTemplate(color: 'info', value: humanizeDurationMs(totalDurationMs), label: 'Duration'),
    metricCardTemplate(color: 'info', value: formatNumber(totalToolCalls), label: 'Tool Calls'),
    metricCardTemplate(color: 'info', value: formatNumber(traceCount), label: 'Turns'),
  ].join('\n');

  // Build progress section data.
  final effectiveBudget = (tokenBudget != null && tokenBudget > 0) ? tokenBudget : null;
  final hasTokenBudget = effectiveBudget != null;
  final initialProgressPct = hasTokenBudget ? (initialTokensUsed / effectiveBudget * 100).round().clamp(0, 100) : 0;
  final initialProgressLabel = hasTokenBudget
      ? '${formatNumber(initialTokensUsed)} / ${formatNumber(effectiveBudget)} tokens ($initialProgressPct%)'
      : '${formatNumber(initialTokensUsed)} tokens used';
  final progressSectionStyle = isRunning ? '' : 'display:none';
  final turnStatusView = _turnStatusView(turnStatus, fallbackSessionId: task['sessionId']?.toString());

  // Build artifact items for template.
  final artifactItems = artifacts.map((a) {
    final kind = a['kind']?.toString() ?? 'data';
    final kindLabel = kind[0].toUpperCase() + kind.substring(1);
    final name = a['name']?.toString() ?? '';
    return {
      ...a,
      'kindLabel': kindLabel,
      'frameTitle': name.isNotEmpty ? name : kindLabel,
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
    // The topbar owns this page's <h1>, so the head carries a description line
    // rather than a second title (DESIGN.md § Layout → Page title and skip link).
    'pageHeaderHtml': pageHeaderTemplate(subtitle: _detailSubtitle(task, statusPresentation.label)),
    'noSessionEmptyStateHtml': emptyStateTemplate(title: noSessionTitle, body: noSessionText),
    'noArtifactsEmptyStateHtml': emptyStateTemplate(
      title: 'No artifacts yet',
      body: 'Artifacts will appear here when the task produces output.',
    ),
    'taskId': task['id'],
    'title': title,
    'typeLabel': titleCase(task['type']?.toString() ?? ''),
    'status': statusName,
    'statusBadgeHtml': statusBadgeTemplate(
      variant: statusName,
      text: statusPresentation.label,
      dot: statusPresentation.dot,
    ),
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
    'createdAtDisplay': formatRelativeTimeIso(task['createdAt']?.toString()),
    'createdAtIso': isoTitle(task['createdAt']?.toString()),
    'completedAtIso': isoTitle(task['completedAt']?.toString()),
    'createdByDisplay': absentValue(task['createdBy']?.toString()).value,
    'createdByAbsent': absentValue(task['createdBy']?.toString()).isAbsent,
    'startedAtDisplay': formatRelativeTimeIso(task['startedAt']?.toString()),
    'completedAtDisplay': formatRelativeTimeIso(task['completedAt']?.toString()),
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
    'turnStatus': turnStatusView,
    'hasTurnStatus': turnStatusView != null,
    'messagesHtml': messagesHtml,
    'noSessionTitle': noSessionTitle,
    'noSessionText': noSessionText,
    'hasArtifacts': artifactItems.isNotEmpty,
    'artifacts': artifactItems,
    'hasConflict': conflictingFiles.isNotEmpty,
    'conflictingFiles': conflictingFiles,
    'conflictDetails': conflictDetails,
    'hasTokenSummary': hasTokenSummary,
    'tokenMetricCardsHtml': tokenMetricCardsHtml,
    'timelineHtml': timelineHtml,
    'hasTimeline': timelineHtml != null && timelineHtml.isNotEmpty,
    // Progress section.
    'progressSectionStyle': progressSectionStyle,
    'hasTokenBudget': hasTokenBudget,
    'initialActivity': initialActivity ?? 'Starting...',
    'initialProgressLabel': initialProgressLabel,
    'initialProgressPct': initialProgressPct,
  });

  return layoutTemplate(title: 'Task: $title', body: body, appName: appName, scripts: standardShellScripts());
}

Map<String, dynamic>? _turnStatusView(Map<String, dynamic>? status, {String? fallbackSessionId}) {
  final state = status?['state']?.toString() ?? 'idle';
  final sessionId = status?['session_id']?.toString() ?? fallbackSessionId;
  if (sessionId == null || sessionId.isEmpty) return null;
  if (!isActiveTurnStatusState(state)) {
    return {
      'sessionId': sessionId,
      'turnId': '',
      'stateLabel': '',
      'reasonLabel': '',
      'reasonAbsent': true,
      'waitingSince': '',
      'stuckSince': '',
      'globalTimeoutAt': '',
      'canCancel': false,
      'hidden': true,
      'cancelHidden': true,
      'cancelDisabled': 'disabled',
    };
  }
  final activeStatus = status!;
  final reason = activeStatus['wait_reason']?.toString();
  final canCancel = activeStatus['can_cancel'] == true;
  return {
    'sessionId': sessionId,
    'turnId': activeStatus['turn_id']?.toString() ?? '',
    'state': state,
    'stateLabel': titleCase(state),
    'reason': reason ?? '',
    'reasonLabel': reason?.replaceAll('_', ' '),
    'reasonAbsent': absentValue(reason).isAbsent,
    'waitingSince': activeStatus['waiting_since']?.toString() ?? '',
    'stuckSince': activeStatus['stuck_since']?.toString() ?? '',
    'globalTimeoutAt': activeStatus['global_timeout_at']?.toString() ?? '',
    'canCancel': canCancel,
    'hidden': null,
    'cancelHidden': canCancel ? null : true,
    'cancelDisabled': canCancel ? null : 'disabled',
  };
}

/// The page head's description line, built from what the task already carries:
/// its goal when it has one, otherwise its type and current status.
String _detailSubtitle(Map<String, dynamic> task, String statusLabel) {
  final goal = task['goalTitle']?.toString();
  if (goal != null && goal.isNotEmpty) return 'Goal: $goal';
  final type = task['type']?.toString();
  return type == null || type.isEmpty ? statusLabel : '${titleCase(type)} task – $statusLabel';
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
