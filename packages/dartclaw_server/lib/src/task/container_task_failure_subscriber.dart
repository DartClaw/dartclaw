import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';

import '../container/container_dispatcher.dart';
import '../execution_policy_resolver.dart';
import 'task_budget_policy.dart';
import 'task_service.dart';

/// Fails running tasks whose execution profile crashed.
class ContainerTaskFailureSubscriber {
  final TaskService _tasks;
  final ExecutionPolicyResolver? _policyResolver;

  /// Routes a crash through the same retry/settlement logic the executor uses,
  /// so a container crash re-queues within `maxRetries` instead of terminally
  /// failing and racing the executor as a second settlement owner.
  late final TaskFailureHandler _failureHandler = TaskFailureHandler(tasks: _tasks);
  StreamSubscription<ContainerCrashedEvent>? _subscription;

  new({required TaskService tasks, ExecutionPolicyResolver? policyResolver})
    : _tasks = tasks,
      _policyResolver = policyResolver;

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
      await _failureHandler.markFailedOrRetry(task, errorSummary: event.error);
    }
  }

  /// Whether [task] was running inside the crashed container.
  ///
  /// Every container belongs to exactly one execution authority, so an event
  /// naming the authority's task fails that task and no other — a second
  /// research task in its own healthy container keeps running. An event naming
  /// no task came from an authority no task owns (the primary lane, a
  /// logical-agent session) and affects nothing.
  ///
  /// The profile match survives only for compositions with no resolver and no
  /// per-authority attribution, where the built-in task-type profile default is
  /// the only identity available.
  bool _affectedBy(Task task, ContainerCrashedEvent event) {
    final crashedTaskId = event.taskId;
    if (crashedTaskId != null) return crashedTaskId == task.id;
    final resolver = _policyResolver;
    if (resolver != null) return false;
    return resolveProfile(task.type) == event.profileId;
  }
}
