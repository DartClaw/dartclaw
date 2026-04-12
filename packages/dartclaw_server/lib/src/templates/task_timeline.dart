import 'package:dartclaw_core/dartclaw_core.dart'
    show
        TaskEvent,
        TaskEventKind,
        StatusChanged,
        ToolCalled,
        ArtifactCreated,
        PushBack,
        TokenUpdate,
        TaskErrorEvent,
        Compaction;

import '../task/tool_call_summary.dart';
import 'helpers.dart';
import 'loader.dart';
import 'task_event_display.dart';

/// Renders the full timeline section (filter bar + event list) for a task.
///
/// Returns an HTML string suitable for injection via `tl:utext`.
String taskTimelineHtml({
  required List<TaskEvent> events,
  required String taskId,
  required String taskStatus,
  String? activeFilter,
}) {
  final filtered = _applyFilter(events, activeFilter);
  final eventVms = filtered.map(_buildEventViewModel).toList();
  final autoScroll = taskStatus == 'running';
  final filter = activeFilter ?? 'all';

  final context = {
    'filterAll': filter == 'all',
    'filterStatus': filter == 'status',
    'filterTools': filter == 'tools',
    'filterArtifacts': filter == 'artifacts',
    'filterErrors': filter == 'errors',
    'filterAllHref': '/tasks/$taskId',
    'filterStatusHref': '/tasks/$taskId?filter=status',
    'filterToolsHref': '/tasks/$taskId?filter=tools',
    'filterArtifactsHref': '/tasks/$taskId?filter=artifacts',
    'filterErrorsHref': '/tasks/$taskId?filter=errors',
    'autoScroll': autoScroll,
    'hasEvents': eventVms.isNotEmpty,
    'events': eventVms,
  };

  return templateLoader.trellis.renderFragment(
    templateLoader.source('task_timeline'),
    fragment: 'timeline',
    context: context,
  );
}

/// Renders a single event item HTML fragment for SSE appending (S10).
String timelineEventItemHtml(TaskEvent event) {
  final context = {'event': _buildEventViewModel(event)};
  return templateLoader.trellis.renderFragment(
    templateLoader.source('task_timeline'),
    fragment: 'eventItem',
    context: context,
  );
}

/// Returns true if [filter] matches [kind].
bool eventMatchesFilter(TaskEventKind kind, String? filter) {
  if (filter == null || filter == 'all') return true;
  return switch (filter) {
    'status' => kind is StatusChanged || kind is PushBack || kind is TokenUpdate,
    'tools' => kind is ToolCalled,
    'artifacts' => kind is ArtifactCreated,
    'errors' => kind is TaskErrorEvent,
    _ => true,
  };
}

List<TaskEvent> _applyFilter(List<TaskEvent> events, String? filter) {
  if (filter == null || filter == 'all') return events;
  return events.where((e) => eventMatchesFilter(e.kind, filter)).toList();
}

Map<String, dynamic> _buildEventViewModel(TaskEvent event) {
  final kind = event.kind;
  final details = event.details;

  final newStatus = details['newStatus']?.toString();
  final success = details['success'] as bool?;
  final iconClass = eventIconClass(kind, newStatus: newStatus);
  final kindClass = eventKindClass(kind, success: success);
  final isStatusChanged = kind is StatusChanged;

  String label;
  String? detail;
  String? detailBadge;
  String? detailBadgeClass;
  String? statusBadgeClassVal;
  String? statusLabel;

  switch (kind) {
    case StatusChanged():
      label = titleCase(newStatus ?? 'unknown');
      statusBadgeClassVal = statusBadgeClass(newStatus);
      statusLabel = titleCase(newStatus ?? 'unknown');
    case ToolCalled():
      final name = details['name']?.toString() ?? '(unknown tool)';
      final context = details['context']?.toString();
      label = formatToolEventText(name, context: context, maxLength: 80);
      final errorType = details['errorType']?.toString();
      if (errorType != null) {
        detail = truncate(errorType, 60);
      }
    case ArtifactCreated():
      label = details['name']?.toString() ?? '(artifact)';
      final artifactKind = details['kind']?.toString();
      if (artifactKind != null) {
        detailBadge = titleCase(artifactKind);
        detailBadgeClass = 'type-badge-$artifactKind';
      }
    case PushBack():
      label = 'Push-back';
      final comment = details['comment']?.toString();
      if (comment != null && comment.isNotEmpty) detail = truncate(comment, 120);
    case TokenUpdate():
      final input = (details['inputTokens'] as num?)?.toInt() ?? 0;
      final output = (details['outputTokens'] as num?)?.toInt() ?? 0;
      label = '${formatNumber(input)} in / ${formatNumber(output)} out';
      final cacheRead = (details['cacheReadTokens'] as num?)?.toInt() ?? 0;
      if (cacheRead > 0) detail = '${formatNumber(cacheRead)} cache read';
    case TaskErrorEvent():
      label = 'Error';
      final message = details['message']?.toString();
      if (message != null && message.isNotEmpty) detail = truncate(message, 120);
    case Compaction():
      label = 'Compaction';
      final trigger = details['trigger']?.toString();
      final preTokens = details['preTokens'];
      if (preTokens != null) {
        detail = 'trigger: ${trigger ?? 'auto'}, ${formatNumber(preTokens as int)} tokens';
      } else if (trigger != null) {
        detail = 'trigger: $trigger';
      }
  }

  final timestamp = event.timestamp;
  return {
    'id': event.id,
    'kind': kind.name,
    'iconClass': iconClass,
    'kindClass': kindClass,
    'isStatusChanged': isStatusChanged,
    'statusBadgeClass': statusBadgeClassVal,
    'statusLabel': statusLabel,
    'label': label,
    'detail': detail,
    'detailBadge': detailBadge,
    'detailBadgeClass': detailBadgeClass,
    'timestamp': formatRelativeTime(timestamp),
    'timestampIso': timestamp.toIso8601String(),
  };
}
