import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

import 'task_event_recorder.dart';
import 'task_service.dart';

/// Records a `compaction` [TaskEvent] when a [CompactionCompletedEvent] fires
/// for a session that has an active (running) task.
///
/// Non-task sessions receive the EventBus event only — no TaskEvent is written.
class CompactionTaskEventSubscriber {
  static final _log = Logger('CompactionTaskEventSubscriber');

  final TaskService _tasks;
  final TaskEventRecorder _eventRecorder;
  StreamSubscription<CompactionCompletedEvent>? _subscription;

  CompactionTaskEventSubscriber({required TaskService tasks, required TaskEventRecorder eventRecorder})
    : _tasks = tasks,
      _eventRecorder = eventRecorder;

  void subscribe(EventBus eventBus) {
    _subscription ??= eventBus.on<CompactionCompletedEvent>().listen((event) {
      unawaited(_recordIfActiveTask(event));
    });
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  Future<void> _recordIfActiveTask(CompactionCompletedEvent event) async {
    final sessionId = event.sessionId;
    if (sessionId.isEmpty) return;

    try {
      final runningTasks = await _tasks.list(status: TaskStatus.running);
      final task = runningTasks.where((t) => t.sessionId == sessionId).firstOrNull;
      if (task == null) {
        _log.fine('Compaction in session $sessionId — no active task, EventBus only');
        return;
      }
      _eventRecorder.recordCompaction(
        task.id,
        trigger: event.trigger,
        sessionId: sessionId,
        preTokens: event.preTokens,
      );
    } catch (e, st) {
      _log.warning('Failed to record compaction task event for session $sessionId', e, st);
    }
  }
}
