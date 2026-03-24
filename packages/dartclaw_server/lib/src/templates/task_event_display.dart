import 'package:dartclaw_core/dartclaw_core.dart' show TaskEventKind, StatusChanged, ToolCalled, ArtifactCreated, PushBack, TokenUpdate, TaskErrorEvent;

/// CSS icon class for a given [TaskEventKind].
///
/// Returns the `.icon-*` class name (without the `icon` base class).
String eventIconClass(TaskEventKind kind, {String? newStatus}) {
  return switch (kind) {
    StatusChanged() => _statusChangedIconClass(newStatus),
    ToolCalled() => 'icon-wrench',
    ArtifactCreated() => 'icon-file-text',
    PushBack() => 'icon-message-circle',
    TokenUpdate() => 'icon-gauge',
    TaskErrorEvent() => 'icon-triangle-alert',
  };
}

/// CSS kind class for per-kind color accent on `.tl-event`.
String eventKindClass(TaskEventKind kind, {bool? success}) {
  return switch (kind) {
    StatusChanged() => 'tl-event-status',
    ToolCalled() => (success == false) ? 'tl-event-error' : 'tl-event-tool',
    ArtifactCreated() => 'tl-event-artifact',
    PushBack() => 'tl-event-pushback',
    TokenUpdate() => 'tl-event-token',
    TaskErrorEvent() => 'tl-event-error',
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
    StatusChanged() => 'task-event-icon-status',
    ToolCalled() => 'task-event-icon-tool',
    ArtifactCreated() => 'task-event-icon-artifact',
    PushBack() => 'task-event-icon-pushback',
    TokenUpdate() => 'task-event-icon-token',
    TaskErrorEvent() => 'task-event-icon-error',
  };
}

/// Unicode character for compact dashboard event icon.
///
/// Used by the `/tasks` dashboard preview and SSE `task_event` payloads.
String compactEventIconChar(TaskEventKind kind) {
  return switch (kind) {
    StatusChanged() => '\u25CF', // ● filled circle
    ToolCalled() => '\uD83D\uDD27', // 🔧 wrench
    ArtifactCreated() => '\uD83D\uDCC4', // 📄 page
    PushBack() => '\uD83D\uDCAC', // 💬 speech bubble
    TokenUpdate() => '\uD83D\uDCCA', // 📊 chart
    TaskErrorEvent() => '\u26A0', // ⚠ warning
  };
}

String _statusChangedIconClass(String? newStatus) {
  return switch (newStatus) {
    'accepted' || 'completed' => 'icon-circle-check',
    'failed' || 'cancelled' => 'icon-circle-x',
    _ => 'icon-circle-check',
  };
}
