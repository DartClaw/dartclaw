import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_config/dartclaw_config.dart' show WorkflowRunStatus;
import 'package:dartclaw_core/dartclaw_core.dart'
    show
        EventBus,
        MapIterationCompletedEvent,
        Task,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowApprovalRequestedEvent,
        WorkflowCliTurnProgressEvent,
        WorkflowRunStatusChangedEvent,
        WorkflowStepCompletedEvent;
import 'package:dartclaw_server/dartclaw_server.dart' show TaskService;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show WorkflowDefinition, WorkflowRun, WorkflowService, WorkflowTaskType;

import '../serve_command.dart' show ExitFn, WriteLine;
import 'cli_progress_printer.dart';
import 'workflow_event_printer_dispatch.dart';
import 'workflow_run_digest.dart';

/// Drives an already-wired standalone workflow run to its next settle point.
///
/// Subscribes to the in-process [eventBus] for step/approval/status progress,
/// invokes [trigger] (which performs the `start`/`resume`/`retry` that spawns
/// the executor asynchronously), and awaits a terminal / `paused` /
/// `awaitingApproval` status before returning the final [WorkflowRun]. The
/// caller maps that status to a process exit code via [standaloneWorkflowExitCode].
///
/// Shared by `workflow run --standalone` and the standalone lifecycle commands
/// (`resume`/`retry`) so both render identical step-progress output. Because
/// `WorkflowService.resume`/`retry`/`start` return before the run settles, the
/// returned run must never be treated as final — only the awaited settle is.
Future<WorkflowRun> driveStandaloneWorkflowRun({
  required WorkflowService service,
  required TaskService taskService,
  required WorkflowDefinition definition,
  required EventBus eventBus,
  required CliProgressPrinter printer,
  required bool jsonOutput,
  required WriteLine stdoutLine,
  required Stream<void> Function() interrupts,
  required ExitFn exitFn,
  required Future<WorkflowRun> Function() trigger,
}) async {
  final runCompleter = Completer<WorkflowRun>();
  String? activeRunId;
  final stepStartTimes = <String, DateTime>{};
  WorkflowApprovalRequestedEvent? lastApprovalEvent;

  final runSub = eventBus.on<WorkflowRunStatusChangedEvent>().listen((event) {
    final runId = activeRunId;
    if (runId != null && event.runId != runId) return;
    if (jsonOutput) {
      stdoutLine(
        jsonEncode({
          'type': 'workflow_status_changed',
          'runId': event.runId,
          'definitionName': event.definitionName,
          'oldStatus': event.oldStatus.name,
          'newStatus': event.newStatus.name,
          'errorMessage': event.errorMessage,
        }),
      );
    }
    if (event.newStatus.terminal ||
        event.newStatus == WorkflowRunStatus.paused ||
        event.newStatus == WorkflowRunStatus.awaitingApproval) {
      if (!runCompleter.isCompleted) {
        service.get(event.runId).then((run) {
          if (run != null && !runCompleter.isCompleted) {
            runCompleter.complete(run);
          }
        });
      }
    }
  });

  final approvalSub = eventBus.on<WorkflowApprovalRequestedEvent>().listen((event) {
    if (activeRunId != null && event.runId != activeRunId) return;
    lastApprovalEvent = event;
    if (jsonOutput) {
      stdoutLine(
        jsonEncode({
          'type': 'workflow_approval_requested',
          'runId': event.runId,
          'stepId': event.stepId,
          'message': event.message,
          'timeoutSeconds': event.timeoutSeconds,
        }),
      );
    }
  });

  final stepSub = eventBus.on<WorkflowStepCompletedEvent>().listen((event) {
    if (activeRunId != null && event.runId != activeRunId) return;
    final key = progressStartKey(stepIndex: event.stepIndex, taskId: event.taskId, displayScope: event.displayScope);
    final startTime = stepStartTimes.remove(key);
    final duration = startTime != null ? DateTime.now().difference(startTime) : Duration.zero;
    if (jsonOutput) {
      stdoutLine(
        jsonEncode({
          'type': 'workflow_step_completed',
          'runId': event.runId,
          'stepId': event.stepId,
          'stepIndex': event.stepIndex,
          'totalSteps': event.totalSteps,
          'taskId': event.taskId,
          if (event.displayScope != null) 'displayScope': event.displayScope,
          'success': event.success,
          if (event.outcome != null) 'outcome': event.outcome,
          if (event.reason != null) 'reason': event.reason,
          'tokenCount': event.tokenCount,
          'durationMs': duration.inMilliseconds,
        }),
      );
      return;
    }
    dispatchWorkflowStepCompletedToPrinter(
      printer: printer,
      event: event,
      duration: startTime != null ? duration : null,
      progressKey: key,
    );
  });

  final mapIterationSub = eventBus.on<MapIterationCompletedEvent>().listen((event) {
    if (activeRunId != null && event.runId != activeRunId) return;
    final stepIndex = definition.steps.indexWhere((step) => step.id == event.stepId);
    if (stepIndex < 0) return;
    if (definition.steps[stepIndex].taskType == WorkflowTaskType.foreach && event.taskId.trim().isNotEmpty) return;
    final key = progressStartKey(stepIndex: stepIndex, taskId: event.taskId, displayScope: event.itemId);
    final startTime = stepStartTimes.remove(key);
    final duration = startTime != null ? DateTime.now().difference(startTime) : Duration.zero;
    if (jsonOutput) {
      stdoutLine(
        jsonEncode({
          'type': 'map_iteration_completed',
          'runId': event.runId,
          'stepId': event.stepId,
          'stepIndex': stepIndex,
          'iterationIndex': event.iterationIndex,
          'totalIterations': event.totalIterations,
          if (event.itemId != null) 'itemId': event.itemId,
          if (event.itemId != null) 'displayScope': event.itemId,
          'taskId': event.taskId,
          'success': event.success,
          if (event.outcome != null) 'outcome': event.outcome,
          if (event.reason != null) 'reason': event.reason,
          'tokenCount': event.tokenCount,
          'durationMs': duration.inMilliseconds,
        }),
      );
      return;
    }
    dispatchMapIterationCompletedToPrinter(
      printer: printer,
      event: event,
      stepIndex: stepIndex,
      duration: startTime != null ? duration : null,
      progressKey: key,
      displayScope: event.itemId,
    );
  });

  // Live per-step token ticks: the workflow CLI provider fires this per turn
  // with the task's cumulative tokens. `stepTokens` is a no-op unless that task
  // is a currently-running step of this run, so it needs no run-id scoping.
  final tokenSub = eventBus.on<WorkflowCliTurnProgressEvent>().listen((event) {
    if (jsonOutput) return;
    final key = tokenProgressKey(event.taskId);
    if (key != null) printer.stepTokens(key, event.cumulativeTokens);
  });

  final taskSub = eventBus.on<TaskStatusChangedEvent>().listen((event) {
    final runId = activeRunId;
    if (runId == null) return;
    if (event.newStatus == TaskStatus.running || event.newStatus == TaskStatus.review) {
      taskService.get(event.taskId).then((task) {
        if (task == null || task.workflowRunId != runId) return;
        final stepIndex = task.stepIndex;
        if (stepIndex == null) return;
        final stepId = definition.steps.length > stepIndex ? definition.steps[stepIndex].id : task.id;
        final displayScope = taskDisplayScope(task);
        final runningKey = progressStartKey(stepIndex: stepIndex, taskId: event.taskId, displayScope: displayScope);
        if (event.newStatus == TaskStatus.running) {
          stepStartTimes[runningKey] = DateTime.now();
        }
        if (jsonOutput) {
          final payload = {
            'type': 'task_status_changed',
            'runId': runId,
            'taskId': event.taskId,
            'stepIndex': stepIndex,
            'stepId': stepId,
            'oldStatus': event.oldStatus.name,
            'newStatus': event.newStatus.name,
          };
          if (displayScope != null) {
            payload['displayScope'] = displayScope;
          }
          stdoutLine(jsonEncode(payload));
          return;
        }
        if (event.newStatus == TaskStatus.running) {
          printer.stepRunning(
            stepIndex,
            stepId,
            task.title,
            task.provider ?? definition.steps[stepIndex].provider,
            displayScope: displayScope,
            progressKey: runningKey,
          );
        } else {
          printer.stepReview(stepIndex, stepId, displayScope: displayScope);
        }
      });
    }
  });

  StreamSubscription<void>? sigintSub;
  DateTime? firstSigint;
  sigintSub = interrupts().listen((_) {
    final now = DateTime.now();
    final first = firstSigint;
    if (first != null && now.difference(first) < const Duration(seconds: 3)) {
      exitFn(1);
    }
    firstSigint = now;
    if (jsonOutput) {
      stdoutLine(jsonEncode({'type': 'interrupt_received', 'runId': activeRunId}));
    } else {
      printer.workflowCancelling();
    }
    final runId = activeRunId;
    if (runId != null) {
      unawaited(service.cancel(runId));
    }
  });

  try {
    final run = await trigger();
    activeRunId = run.id;
    if (jsonOutput) {
      stdoutLine(jsonEncode({'type': 'run_started', 'run': run.toJson()}));
    } else {
      printer.workflowStarted();
    }

    final finalRun = await runCompleter.future;
    if (!jsonOutput) {
      switch (finalRun.status) {
        case WorkflowRunStatus.completed:
          printer.workflowCompleted(finalRun.currentStepIndex, finalRun.totalTokens);
        case WorkflowRunStatus.paused || WorkflowRunStatus.awaitingApproval:
          final approval = lastApprovalEvent;
          if (approval != null) {
            printer.workflowApprovalPaused(
              finalRun.id,
              finalRun.currentStepIndex - 1,
              approval.stepId,
              approval.message,
            );
          } else {
            printer.workflowPaused(finalRun.currentStepIndex, finalRun.errorMessage);
          }
        case WorkflowRunStatus.failed || WorkflowRunStatus.cancelled:
          printer.workflowFailed(finalRun.currentStepIndex, finalRun.errorMessage ?? 'Cancelled');
        case WorkflowRunStatus.pending || WorkflowRunStatus.running:
          break;
      }
    }
    if (finalRun.status != WorkflowRunStatus.pending && finalRun.status != WorkflowRunStatus.running) {
      final childTasks = (await taskService.list()).where((task) => task.workflowRunId == finalRun.id).toList();
      final digest = buildWorkflowRunDigest(run: finalRun, definition: definition, childTasks: childTasks);
      if (jsonOutput) {
        stdoutLine(jsonEncode(digest.toJson()));
      } else {
        for (final line in renderWorkflowRunDigestLines(digest, color: printer.colorEnabled)) {
          stdoutLine(line);
        }
      }
    }
    return finalRun;
  } finally {
    printer.disposeLive();
    await runSub.cancel();
    await stepSub.cancel();
    await mapIterationSub.cancel();
    await taskSub.cancel();
    await tokenSub.cancel();
    await sigintSub.cancel();
    await approvalSub.cancel();
  }
}

/// Maps a settled standalone [WorkflowRunStatus] to a process exit code:
/// `0` completed, `1` failed (or unexpected pending/running), `2`
/// cancelled/paused/awaitingApproval.
int standaloneWorkflowExitCode(WorkflowRunStatus status) {
  return switch (status) {
    WorkflowRunStatus.completed => 0,
    WorkflowRunStatus.failed => 1,
    WorkflowRunStatus.cancelled || WorkflowRunStatus.paused || WorkflowRunStatus.awaitingApproval => 2,
    WorkflowRunStatus.pending || WorkflowRunStatus.running => 1,
  };
}

/// Stable key for matching a step's start time to its completion event,
/// keyed by task id when present, else step index plus optional display scope.
String progressStartKey({required int stepIndex, String? taskId, String? displayScope}) {
  final normalizedTaskId = taskId?.trim();
  if (normalizedTaskId != null && normalizedTaskId.isNotEmpty) {
    return 'task:$normalizedTaskId';
  }
  final normalizedScope = displayScope?.trim();
  if (normalizedScope != null && normalizedScope.isNotEmpty) {
    return 'step:$stepIndex:$normalizedScope';
  }
  return 'step:$stepIndex';
}

/// Key for matching a live token tick to its running step. A token event
/// carries only a taskId, which always dominates [progressStartKey]'s
/// step-index path — so this returns that `task:<id>` key directly and yields
/// null for a blank taskId, rather than letting it collapse to `step:0` and
/// mis-attribute the tick to whichever step holds that key.
String? tokenProgressKey(String? taskId) {
  final normalized = taskId?.trim();
  if (normalized == null || normalized.isEmpty) return null;
  return progressStartKey(stepIndex: 0, taskId: normalized);
}

/// Reads a task's `displayScope` config value, normalized to null when blank.
String? taskDisplayScope(Task task) {
  final scope = task.configJson['displayScope'];
  if (scope is! String) return null;
  final trimmed = scope.trim();
  return trimmed.isEmpty ? null : trimmed;
}
