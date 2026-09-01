import 'package:dartclaw_core/dartclaw_core.dart' show TaskEventKind;

/// CSS icon class for a given [TaskEventKind].
///
/// Returns the `.icon-*` class name (without the `icon` base class).
String eventIconClass(TaskEventKind kind, {String? newStatus}) {
  return switch (kind) {
    TaskEventKind.statusChanged => _statusChangedIconClass(newStatus),
    TaskEventKind.toolCalled => 'icon-wrench',
    TaskEventKind.artifactCreated => 'icon-file-text',
    TaskEventKind.structuredOutputFinalizerUsed => 'icon-file-json',
    TaskEventKind.structuredOutputInlineUsed => 'icon-file-json',
    TaskEventKind.structuredOutputFallbackUsed => 'icon-file-warning',
    TaskEventKind.structuredOutputValidationFailed => 'icon-file-warning',
    TaskEventKind.pushBack => 'icon-message-circle',
    TaskEventKind.tokenUpdate => 'icon-gauge',
    TaskEventKind.taskError => 'icon-triangle-alert',
    TaskEventKind.compaction => 'icon-layers',
  };
}

/// CSS kind class for per-kind color accent on `.tl-event`.
String eventKindClass(TaskEventKind kind, {bool? success}) {
  return switch (kind) {
    TaskEventKind.statusChanged => 'tl-event-status',
    TaskEventKind.toolCalled => (success == false) ? 'tl-event-error' : 'tl-event-tool',
    TaskEventKind.artifactCreated => 'tl-event-artifact',
    TaskEventKind.structuredOutputFinalizerUsed => 'tl-event-tool',
    TaskEventKind.structuredOutputInlineUsed => 'tl-event-tool',
    TaskEventKind.structuredOutputFallbackUsed => 'tl-event-warning',
    TaskEventKind.structuredOutputValidationFailed => 'tl-event-error',
    TaskEventKind.pushBack => 'tl-event-pushback',
    TaskEventKind.tokenUpdate => 'tl-event-token',
    TaskEventKind.taskError => 'tl-event-error',
    TaskEventKind.compaction => 'tl-event-compaction',
  };
}

/// CSS class for a status badge on a `statusChanged` event.
String statusBadgeClass(String? statusName) {
  if (statusName == null || statusName.isEmpty) return 'status-badge-draft';
  return 'status-badge-$statusName';
}

/// CSS color class for compact dashboard event icon (`.task-event-icon-*`).
///
/// Used by the `/tasks` dashboard preview and SSE `task_event` payloads.
String compactEventIconClass(TaskEventKind kind) {
  return switch (kind) {
    TaskEventKind.statusChanged => 'task-event-icon-status',
    TaskEventKind.toolCalled => 'task-event-icon-tool',
    TaskEventKind.artifactCreated => 'task-event-icon-artifact',
    TaskEventKind.structuredOutputFinalizerUsed => 'task-event-icon-tool',
    TaskEventKind.structuredOutputInlineUsed => 'task-event-icon-tool',
    TaskEventKind.structuredOutputFallbackUsed => 'task-event-icon-warning',
    TaskEventKind.structuredOutputValidationFailed => 'task-event-icon-error',
    TaskEventKind.pushBack => 'task-event-icon-pushback',
    TaskEventKind.tokenUpdate => 'task-event-icon-token',
    TaskEventKind.taskError => 'task-event-icon-error',
    TaskEventKind.compaction => 'task-event-icon-compaction',
  };
}

/// Unicode character for compact dashboard event icon.
///
/// Used by the `/tasks` dashboard preview and SSE `task_event` payloads.
String compactEventIconChar(TaskEventKind kind) {
  return switch (kind) {
    TaskEventKind.statusChanged => '●', // ● filled circle
    TaskEventKind.toolCalled => '🔧', // 🔧 wrench
    TaskEventKind.artifactCreated => '📄', // 📄 page
    TaskEventKind.structuredOutputFinalizerUsed => '📦', // 📦 envelope package
    TaskEventKind.structuredOutputInlineUsed => '📥', // 📥 inbox tray
    TaskEventKind.structuredOutputFallbackUsed => '⚠', // ⚠ warning
    TaskEventKind.structuredOutputValidationFailed => '⚠', // ⚠ warning
    TaskEventKind.pushBack => '💬', // 💬 speech bubble
    TaskEventKind.tokenUpdate => '📊', // 📊 chart
    TaskEventKind.taskError => '⚠', // ⚠ warning
    TaskEventKind.compaction => '⊓', // ⊓ compaction
  };
}

String _statusChangedIconClass(String? newStatus) {
  return switch (newStatus) {
    'accepted' || 'completed' => 'icon-circle-check',
    'failed' || 'cancelled' => 'icon-circle-x',
    _ => 'icon-circle-check',
  };
}
