import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:uuid/uuid.dart';

/// Centralizes task event recording: SQLite persistence + EventBus notification.
///
/// Integration points call typed convenience methods instead of manually
/// constructing [TaskEvent] instances. Each method:
/// 1. Constructs a [TaskEvent] with the appropriate kind and details
/// 2. Inserts it synchronously via [TaskEventService] (NF04 durability)
/// 3. Fires a [TaskEventCreatedEvent] on the [EventBus]
class TaskEventRecorder {
  final TaskEventService _eventService;
  final EventBus? _eventBus;
  final Uuid _uuid;

  TaskEventRecorder({required TaskEventService eventService, EventBus? eventBus, Uuid? uuid})
    : _eventService = eventService,
      _eventBus = eventBus,
      _uuid = uuid ?? const Uuid();

  /// Records a task lifecycle status transition.
  void recordStatusChanged(
    String taskId, {
    required TaskStatus oldStatus,
    required TaskStatus newStatus,
    required String trigger,
  }) {
    _record(taskId, const StatusChanged(), {
      'oldStatus': oldStatus.name,
      'newStatus': newStatus.name,
      'trigger': trigger,
    });
  }

  /// Records a tool invocation during agent execution.
  void recordToolCalled(
    String taskId, {
    required String name,
    required bool success,
    int durationMs = 0,
    String? errorType,
    String? context,
  }) {
    final details = <String, dynamic>{'name': name, 'success': success, 'durationMs': durationMs};
    if (errorType case final value?) {
      details['errorType'] = value;
    }
    if (context case final value?) {
      details['context'] = value;
    }
    _record(taskId, const ToolCalled(), details);
  }

  /// Records an artifact being created and attached to the task.
  void recordArtifactCreated(String taskId, {required String name, required String kind}) {
    _record(taskId, const ArtifactCreated(), {'name': name, 'kind': kind});
  }

  /// Records that structured-output extraction fell back to heuristic parsing.
  void recordStructuredOutputFallbackUsed(
    String taskId, {
    required String stepId,
    required String outputKey,
    required String failureReason,
    String? providerSubtype,
  }) {
    final details = <String, dynamic>{'stepId': stepId, 'outputKey': outputKey, 'failureReason': failureReason};
    if (providerSubtype case final value?) {
      details['providerSubtype'] = value;
    }
    _record(taskId, const StructuredOutputFallbackUsed(), details);
  }

  /// Records a push-back from review with a comment.
  void recordPushBack(String taskId, {required String comment}) {
    _record(taskId, const PushBack(), {'comment': comment});
  }

  /// Records a token consumption update after a completed turn.
  void recordTokenUpdate(
    String taskId, {
    required int inputTokens,
    required int outputTokens,
    int cacheReadTokens = 0,
    int cacheWriteTokens = 0,
  }) {
    _record(taskId, const TokenUpdate(), {
      'inputTokens': inputTokens,
      'outputTokens': outputTokens,
      if (cacheReadTokens > 0) 'cacheReadTokens': cacheReadTokens,
      if (cacheWriteTokens > 0) 'cacheWriteTokens': cacheWriteTokens,
    });
  }

  /// Records an error that occurred during task execution.
  void recordError(String taskId, {required String message}) {
    _record(taskId, const TaskErrorEvent(), {'message': message});
  }

  /// Records a context compaction that occurred during agent execution.
  void recordCompaction(String taskId, {required String trigger, required String sessionId, int? preTokens}) {
    final details = <String, dynamic>{'trigger': trigger, 'sessionId': sessionId};
    if (preTokens != null) details['preTokens'] = preTokens;
    _record(taskId, const Compaction(), details);
  }

  void _record(String taskId, TaskEventKind kind, Map<String, dynamic> details) {
    final event = TaskEvent(id: _uuid.v4(), taskId: taskId, timestamp: DateTime.now(), kind: kind, details: details);
    _eventService.insert(event);
    _eventBus?.fire(
      TaskEventCreatedEvent(
        taskId: taskId,
        eventId: event.id,
        kind: kind.name,
        details: details,
        timestamp: event.timestamp,
      ),
    );
  }
}
