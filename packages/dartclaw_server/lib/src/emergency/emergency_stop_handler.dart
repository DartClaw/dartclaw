import 'package:dartclaw_core/dartclaw_core.dart'
    show EventBus, EmergencyStopEvent, TaskStatus;
import 'package:logging/logging.dart';

import '../api/sse_broadcast.dart';
import '../task/task_service.dart';
import '../turn_manager.dart';

/// Result of an emergency stop operation.
class EmergencyStopResult {
  /// Number of active turns that were cancelled.
  final int turnsCancelled;

  /// Number of tasks that were transitioned to cancelled.
  final int tasksCancelled;

  const EmergencyStopResult({
    required this.turnsCancelled,
    required this.tasksCancelled,
  });

  /// True when at least one turn or task was cancelled.
  bool get hadActivity => turnsCancelled > 0 || tasksCancelled > 0;
}

/// Orchestrates the emergency stop sequence.
///
/// Cancels all active turns across all runners in the harness pool, then
/// transitions all running and queued tasks to cancelled. Fires an
/// [EmergencyStopEvent] on the EventBus and broadcasts an SSE event for
/// web UI awareness.
///
/// Best-effort: individual failures are logged but do not halt the stop
/// sequence — remaining turns and tasks are still cancelled.
class EmergencyStopHandler {
  static final _log = Logger('EmergencyStopHandler');

  final TurnManager _turnManager;
  final TaskService _taskService;
  final EventBus? _eventBus;
  final SseBroadcast? _sseBroadcast;

  EmergencyStopHandler({
    required TurnManager turnManager,
    required TaskService taskService,
    EventBus? eventBus,
    SseBroadcast? sseBroadcast,
  })  : _turnManager = turnManager,
        _taskService = taskService,
        _eventBus = eventBus,
        _sseBroadcast = sseBroadcast;

  /// Execute the emergency stop sequence.
  ///
  /// 1. Cancel all active turns across all runners in the pool.
  /// 2. Transition all running and queued tasks to [TaskStatus.cancelled].
  /// 3. Fire [EmergencyStopEvent] and an `emergency_stop` SSE broadcast.
  ///
  /// Returns counts of cancelled turns and tasks.
  Future<EmergencyStopResult> execute({
    required String stoppedBy,
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();

    // Phase 1: Cancel all active turns.
    var turnsCancelled = 0;
    for (final runner in _turnManager.pool.runners) {
      for (final sessionId in runner.activeSessionIds.toList()) {
        try {
          await runner.cancelTurn(sessionId);
          turnsCancelled++;
        } catch (e, st) {
          _log.warning('Failed to cancel turn for session $sessionId', e, st);
        }
      }
    }

    // Phase 2: Cancel all running and queued tasks.
    // Only running and queued are cancellable — review/draft/accepted/rejected
    // are left for manual resolution.
    var tasksCancelled = 0;
    for (final status in [TaskStatus.running, TaskStatus.queued]) {
      final tasks = await _taskService.list(status: status);
      for (final task in tasks) {
        try {
          await _taskService.transition(
            task.id,
            TaskStatus.cancelled,
            now: timestamp,
            trigger: 'emergency_stop',
          );
          tasksCancelled++;
        } catch (e, st) {
          // VersionConflictException or StateError means the task was modified
          // concurrently (e.g. completed between list and cancel). Safe to skip.
          _log.warning('Failed to cancel task ${task.id}', e, st);
        }
      }
    }

    final result = EmergencyStopResult(
      turnsCancelled: turnsCancelled,
      tasksCancelled: tasksCancelled,
    );

    // Fire EventBus event and SSE broadcast.
    _eventBus?.fire(EmergencyStopEvent(
      stoppedBy: stoppedBy,
      turnsCancelled: turnsCancelled,
      tasksCancelled: tasksCancelled,
      timestamp: timestamp,
    ));

    _sseBroadcast?.broadcast('emergency_stop', {
      'stopped_by': stoppedBy,
      'turns_cancelled': turnsCancelled,
      'tasks_cancelled': tasksCancelled,
    });

    _log.info(
      'Emergency stop by $stoppedBy: '
      '$turnsCancelled turns, $tasksCancelled tasks cancelled',
    );

    return result;
  }
}
