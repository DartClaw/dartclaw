part of 'workflow_executor.dart';

class _WorkflowRunWaitAbort implements Exception {
  const _WorkflowRunWaitAbort(this.message);

  final String message;

  @override
  String toString() => message;
}

extension WorkflowExecutorTaskWait on WorkflowExecutor {
  /// Awaits task completion, aborting early if the workflow run transitions
  /// away from `running` (e.g. on pause or cancel).
  ///
  /// Abort takes explicit priority over task completion: if both signals arrive
  /// in the same microtask turn, the abort wins. This avoids the `Future.any`
  /// registration-order race where the task future could shadow a simultaneous
  /// abort. A re-check against the repository closes the window between
  /// subscription setup and a prior abort event that the broadcast stream
  /// already dropped.
  Future<Task> _waitForTaskCompletion(
    String taskId,
    WorkflowStep step,
    Completer<Task> completer,
    StreamSubscription<TaskStatusChangedEvent> sub, {
    String? runId,
  }) async {
    StreamSubscription<WorkflowRunStatusChangedEvent>? runSub;

    // Priority completer: abort always wins over task completion.
    final result = Completer<Task>();
    _WorkflowRunWaitAbort? pendingAbort;

    void abortWait(String message) {
      pendingAbort ??= _WorkflowRunWaitAbort(message);
      if (!result.isCompleted) result.completeError(pendingAbort!);
    }

    void resolveTask(Task task) {
      // Drop the task resolution if an abort is already queued or delivered.
      if (pendingAbort != null) return;
      if (!result.isCompleted) result.complete(task);
    }

    unawaited(
      completer.future.then(
        resolveTask,
        onError: (Object e, StackTrace st) {
          if (!result.isCompleted) result.completeError(e, st);
        },
      ),
    );

    if (runId != null) {
      runSub = _eventBus.on<WorkflowRunStatusChangedEvent>().where((e) => e.runId == runId).listen((event) {
        if (event.newStatus != WorkflowRunStatus.running) {
          abortWait(
            'Workflow run "$runId" transitioned to ${event.newStatus.name} while step "${step.name}" awaited task $taskId',
          );
        }
      });
      // Close the race: if pause fired before we subscribed, re-check.
      final currentRun = await _repository.getById(runId);
      if (currentRun != null && currentRun.status != WorkflowRunStatus.running) {
        abortWait(
          'Workflow run "$runId" is ${currentRun.status.name}; step "${step.name}" wait aborted before task $taskId completed',
        );
      }
    }

    final currentTask = await _taskService.get(taskId);
    if (currentTask != null && currentTask.status.terminal && !completer.isCompleted) {
      completer.complete(currentTask);
    }

    try {
      if (step.timeoutSeconds != null) {
        return await result.future.timeout(
          Duration(seconds: step.timeoutSeconds!),
          onTimeout: () =>
              throw TimeoutException('Step "${step.name}" timed out', Duration(seconds: step.timeoutSeconds!)),
        );
      } else {
        return await result.future;
      }
    } finally {
      await sub.cancel();
      await runSub?.cancel();
    }
  }
}
