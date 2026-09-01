import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';

import 'task_budget_policy.dart';
import 'task_service.dart';

/// Fails running tasks whose execution profile crashed.
class ContainerTaskFailureSubscriber {
  final TaskService _tasks;

  /// Routes a crash through the same retry/settlement logic the executor uses,
  /// so a container crash re-queues within `maxRetries` instead of terminally
  /// failing and racing the executor as a second settlement owner.
  late final TaskFailureHandler _failureHandler = TaskFailureHandler(tasks: _tasks);
  StreamSubscription<ContainerCrashedEvent>? _subscription;

  new({required TaskService tasks}) : _tasks = tasks;

  void subscribe(EventBus eventBus) {
    _subscription ??= eventBus.on<ContainerCrashedEvent>().listen((event) {
      unawaited(_failAffectedTasks(event));
    });
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  Future<void> _failAffectedTasks(ContainerCrashedEvent event) async {
    final runningTasks = await _tasks.list(status: TaskStatus.running);
    for (final task in runningTasks) {
      if (!_affectedBy(task, event)) continue;
      // markFailedOrRetry re-reads the task and no-ops when it is already
      // terminal, so it consults retries and does not clobber a settlement the
      // executor may have just made for a crash that raced a completing turn.
      await _failureHandler.markFailedOrRetry(task, errorSummary: event.error, kind: TaskFailureReason.containerCrash);
    }
  }

  /// Whether [task] was running inside the crashed container.
  ///
  /// Every container belongs to exactly one execution authority, so an event
  /// naming the authority's task fails that task and no other — a second
  /// second task in its own healthy container keeps running. An event naming
  /// no task came from an authority no task owns (the primary lane, a
  /// logical-agent session) and affects nothing.
  bool _affectedBy(Task task, ContainerCrashedEvent event) {
    final crashedTaskId = event.taskId;
    return crashedTaskId != null && crashedTaskId == task.id;
  }
}
