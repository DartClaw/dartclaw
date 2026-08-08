import 'package:dartclaw_core/dartclaw_core.dart' show TaskEvent, TaskEventKind;

import '../task/tool_call_summary.dart';
import 'components.dart';
import 'helpers.dart';
import 'loader.dart';
import 'task_event_display.dart';

/// The filter buckets the chip row offers, in display order. `null` is the
/// unfiltered bucket; the rest are the values [eventMatchesFilter] accepts.
const _filterBuckets = <(String label, String? key)>[
  ('All', null),
  ('Status', 'status'),
  ('Tools', 'tools'),
  ('Artifacts', 'artifacts'),
  ('Errors', 'errors'),
];

/// Renders the full timeline section (filter bar + event list) for a task.
///
/// Returns an HTML string suitable for injection via `tl:utext`, or `''` when
/// [events] is empty — a task that has recorded nothing has no timeline to show.
/// Emptiness is judged on the unfiltered list: a filter that matches nothing
/// still renders the panel, because the chip row is the only way back to All.
String taskTimelineHtml({
  required List<TaskEvent> events,
  required String taskId,
  required String taskStatus,
  String? activeFilter,
}) {
  if (events.isEmpty) return '';

  final filtered = _applyFilter(events, activeFilter);
  final eventVms = filtered.map(_buildEventViewModel).toList();
  final autoScroll = taskStatus == 'running';
  final filter = activeFilter ?? 'all';

  // Counts come from the unfiltered list so they keep reporting what the other
  // buckets hold; derived from the filtered list they would all collapse to the
  // active one.
  final filters = _filterBuckets
      .map((bucket) {
        final (label, key) = bucket;
        return {
          'label': label,
          'count': key == null ? events.length : events.where((e) => eventMatchesFilter(e.kind, key)).length,
          'active': filter == (key ?? 'all'),
          'href': key == null ? '/tasks/$taskId' : '/tasks/$taskId?filter=$key',
        };
      })
      .toList(growable: false);

  final context = {
    'filters': filters,
    'autoScroll': autoScroll,
    'hasEvents': eventVms.isNotEmpty,
    'events': eventVms,
    'emptyStateHtml': eventVms.isEmpty
        ? emptyStateTemplate(
            title: 'No matching events',
            body: 'No events of this kind were recorded. Select All to see the full timeline.',
          )
        : null,
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
    'status' =>
      kind == TaskEventKind.statusChanged || kind == TaskEventKind.pushBack || kind == TaskEventKind.tokenUpdate,
    'tools' => kind == TaskEventKind.toolCalled,
    'artifacts' => kind == TaskEventKind.artifactCreated,
    'errors' => kind == TaskEventKind.taskError,
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
  final isStatusChanged = kind == TaskEventKind.statusChanged;

  String label;
  String? detail;
  String? detailBadge;
  String? detailBadgeClass;
  String? statusBadgeClassVal;
  String? statusLabel;

  switch (kind) {
    case TaskEventKind.statusChanged:
      final status = absentValue(newStatus);
      label = status.isAbsent ? 'Status changed' : titleCase(status.value! as String);
      statusBadgeClassVal = statusBadgeClass(newStatus);
      statusLabel = label;
    case TaskEventKind.toolCalled:
      final name = details['name']?.toString() ?? '(unknown tool)';
      final context = details['context']?.toString();
      label = formatToolEventText(name, context: context, maxLength: 80);
      final errorType = details['errorType']?.toString();
      if (errorType != null) {
        detail = truncate(errorType, 60);
      }
    case TaskEventKind.artifactCreated:
      label = details['name']?.toString() ?? '(artifact)';
      final artifactKind = details['kind']?.toString();
      if (artifactKind != null) {
        detailBadge = titleCase(artifactKind);
        detailBadgeClass = 'type-badge-$artifactKind';
      }
    case TaskEventKind.structuredOutputFinalizerUsed:
      label = 'Structured finalization envelope';
      detail = truncate(details['outputKey']?.toString() ?? '(output)', 60);
    case TaskEventKind.structuredOutputInlineUsed:
      label = 'Structured output used inline';
      detail = truncate(details['outputKey']?.toString() ?? '(output)', 60);
    case TaskEventKind.structuredOutputFallbackUsed:
      label = 'Structured output fallback';
      detail = _structuredOutputFailureDetail(details);
    case TaskEventKind.structuredOutputValidationFailed:
      label = 'Structured output validation failed';
      detail = _structuredOutputFailureDetail(details);
    case TaskEventKind.pushBack:
      label = 'Push-back';
      final comment = details['comment']?.toString();
      if (comment != null && comment.isNotEmpty) detail = truncate(comment, 120);
    case TaskEventKind.tokenUpdate:
      final input = (details['inputTokens'] as num?)?.toInt() ?? 0;
      final output = (details['outputTokens'] as num?)?.toInt() ?? 0;
      label = '${formatNumber(input)} in / ${formatNumber(output)} out';
      final cacheRead = (details['cacheReadTokens'] as num?)?.toInt() ?? 0;
      if (cacheRead > 0) detail = '${formatNumber(cacheRead)} cache read';
    case TaskEventKind.taskError:
      label = 'Error';
      final message = details['message']?.toString();
      if (message != null && message.isNotEmpty) detail = truncate(message, 120);
    case TaskEventKind.compaction:
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

String? _structuredOutputFailureDetail(Map<String, dynamic> details) {
  final outputKey = details['outputKey']?.toString();
  final failureReason = details['failureReason']?.toString();
  if (outputKey != null && failureReason != null) {
    return '$outputKey ($failureReason)';
  }
  return outputKey;
}
