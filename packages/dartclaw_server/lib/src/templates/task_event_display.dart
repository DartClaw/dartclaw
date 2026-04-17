import 'package:dartclaw_core/dartclaw_core.dart'
    show
        TaskEventKind,
        StatusChanged,
        ToolCalled,
        ArtifactCreated,
        StructuredOutputFallbackUsed,
        PushBack,
        TokenUpdate,
        TaskErrorEvent,
        Compaction;

/// CSS icon class for a given [TaskEventKind].
///
/// Returns the `.icon-*` class name (without the `icon` base class).
String eventIconClass(TaskEventKind kind, {String? newStatus}) {
  return switch (kind) {
    StatusChanged() => _statusChangedIconClass(newStatus),
    ToolCalled() => 'icon-wrench',
    ArtifactCreated() => 'icon-file-text',
    StructuredOutputFallbackUsed() => 'icon-file-warning',
    PushBack() => 'icon-message-circle',
    TokenUpdate() => 'icon-gauge',
    TaskErrorEvent() => 'icon-triangle-alert',
    Compaction() => 'icon-layers',
  };
}

/// CSS kind class for per-kind color accent on `.tl-event`.
String eventKindClass(TaskEventKind kind, {bool? success}) {
  return switch (kind) {
    StatusChanged() => 'tl-event-status',
    ToolCalled() => (success == false) ? 'tl-event-error' : 'tl-event-tool',
    ArtifactCreated() => 'tl-event-artifact',
    StructuredOutputFallbackUsed() => 'tl-event-warning',
    PushBack() => 'tl-event-pushback',
    TokenUpdate() => 'tl-event-token',
    TaskErrorEvent() => 'tl-event-error',
    Compaction() => 'tl-event-compaction',
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
    StructuredOutputFallbackUsed() => 'task-event-icon-warning',
    PushBack() => 'task-event-icon-pushback',
    TokenUpdate() => 'task-event-icon-token',
    TaskErrorEvent() => 'task-event-icon-error',
    Compaction() => 'task-event-icon-compaction',
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
    StructuredOutputFallbackUsed() => '\u26A0', // ⚠ warning
    PushBack() => '\uD83D\uDCAC', // 💬 speech bubble
    TokenUpdate() => '\uD83D\uDCCA', // 📊 chart
    TaskErrorEvent() => '\u26A0', // ⚠ warning
    Compaction() => '\u2293', // ⊓ compaction
  };
}

String _statusChangedIconClass(String? newStatus) {
  return switch (newStatus) {
    'accepted' || 'completed' => 'icon-circle-check',
    'failed' || 'cancelled' => 'icon-circle-x',
    _ => 'icon-circle-check',
  };
}
