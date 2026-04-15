import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

import '../turn_manager.dart';
import 'task_service.dart';

/// Cancels active turns when running tasks are transitioned to `cancelled`.
///
/// This closes the gap between internal task lifecycle transitions
/// (for example workflow-driven cancellation) and the API routes that cancel
/// turns explicitly after updating task status.
class TaskCancellationSubscriber {
  static final _log = Logger('TaskCancellationSubscriber');

  final TaskService _tasks;
  final TurnManager _turns;
  StreamSubscription<TaskStatusChangedEvent>? _subscription;

  TaskCancellationSubscriber({required TaskService tasks, required TurnManager turns}) : _tasks = tasks, _turns = turns;

  void subscribe(EventBus eventBus) {
    _subscription ??= eventBus.on<TaskStatusChangedEvent>().listen((event) {
      unawaited(_cancelIfRunningTask(event));
    });
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  Future<void> _cancelIfRunningTask(TaskStatusChangedEvent event) async {
    if (!_shouldCancelTurn(event)) {
      return;
    }

    final task = await _tasks.get(event.taskId);
    if (task == null) {
      _log.warning('Task ${event.taskId} not found while cancelling its active turn');
      return;
    }

    final sessionId = task.sessionId?.trim();
    if (sessionId == null || sessionId.isEmpty) {
      _log.fine('Task ${task.id} was cancelled without an active session ID');
      return;
    }

    try {
      await _turns.cancelTurn(sessionId);
    } catch (error, stackTrace) {
      _log.warning('Failed to cancel active turn for task ${task.id} session $sessionId', error, stackTrace);
    }
  }

  bool _shouldCancelTurn(TaskStatusChangedEvent event) =>
      event.oldStatus == TaskStatus.running && event.newStatus == TaskStatus.cancelled;
}
