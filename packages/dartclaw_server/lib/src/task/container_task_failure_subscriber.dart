import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

/// Fails running tasks whose execution profile crashed.
class ContainerTaskFailureSubscriber {
  static final _log = Logger('ContainerTaskFailureSubscriber');

  final TaskService _tasks;
  StreamSubscription<ContainerCrashedEvent>? _subscription;

  ContainerTaskFailureSubscriber({required TaskService tasks}) : _tasks = tasks;

  void subscribe(EventBus eventBus) {
    _subscription ??= eventBus.on<ContainerCrashedEvent>().listen((event) {
      unawaited(_failAffectedTasks(event, eventBus));
    });
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  Future<void> _failAffectedTasks(ContainerCrashedEvent event, EventBus eventBus) async {
    final runningTasks = await _tasks.list(status: TaskStatus.running);
    for (final task in runningTasks) {
      if (resolveProfile(task.type) != event.profileId) continue;
      try {
        final failed = await _tasks.transition(task.id, TaskStatus.failed);
        eventBus.fire(
          TaskStatusChangedEvent(
            taskId: task.id,
            oldStatus: TaskStatus.running,
            newStatus: failed.status,
            trigger: 'system',
            timestamp: DateTime.now(),
          ),
        );
      } on StateError catch (error, stackTrace) {
        _log.warning('Failed to transition task ${task.id} after container crash', error, stackTrace);
      }
    }
  }
}
