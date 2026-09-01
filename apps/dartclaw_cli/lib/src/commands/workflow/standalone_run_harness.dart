import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart'
    show
        EventBus,
        MapIterationCompletedEvent,
        Task,
        TaskStatusChangedEvent,
        WorkflowApprovalRequestedEvent,
        WorkflowCliTurnProgressEvent,
        WorkflowRunStatusChangedEvent,
        WorkflowStepCompletedEvent;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show ExitFn, TaskService, WriteLine;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowDefinition, WorkflowRun, WorkflowService;

import 'cli_progress_printer.dart';
import 'workflow_progress_renderer.dart';
import 'workflow_run_digest.dart';

/// Drives an already-wired standalone workflow run to its next settle point.
///
/// Subscribes to the in-process [eventBus] for step/approval/status progress,
/// invokes [trigger] (which performs the `start`/`resume`/`retry` that spawns
/// the executor asynchronously), and awaits a terminal / `paused` /
/// `awaitingApproval` status before returning the final [WorkflowRun]. The
/// caller maps that status to a process exit code via [standaloneWorkflowExitCode].
///
/// Step progress renders through the shared [WorkflowProgressRenderer]; this
/// lane owns its renderer-authored `--json` payloads, the settle sequence and
/// the interrupt handling.
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
  WorkflowApprovalRequestedEvent? lastApprovalEvent;

  final renderer = WorkflowProgressRenderer(
    definition: definition,
    printer: printer,
    jsonOutput: jsonOutput,
    resolveStepContext: (update) async {
      final runId = activeRunId;
      final taskId = update.taskId;
      if (runId == null || taskId == null) return null;
      final task = await taskService.get(taskId);
      if (task == null || task.workflowRunId != runId) return null;
      final stepIndex = task.stepIndex;
      if (stepIndex == null) return null;
      return TaskStepContext(
        stepIndex: stepIndex,
        stepId: definition.steps.length > stepIndex ? definition.steps[stepIndex].id : task.id,
        title: task.title,
        provider: task.provider ?? definition.steps[stepIndex].provider,
        displayScope: taskDisplayScope(task),
      );
    },
    jsonSink: jsonOutput
        ? WorkflowProgressJsonSink(
            taskTransition: (update, context) {
              final payload = <String, Object?>{
                'type': 'task_status_changed',
                'runId': activeRunId,
                'taskId': update.taskId,
                'stepIndex': context.stepIndex,
                'stepId': context.stepId,
                'oldStatus': update.oldStatus?.name,
                'newStatus': update.newStatus.name,
              };
              if (context.displayScope != null) {
                payload['displayScope'] = context.displayScope;
              }
              stdoutLine(jsonEncode(payload));
            },
            stepCompleted: (event, duration) => stdoutLine(
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
            ),
            mapIterationCompleted: (event, stepIndex, duration) => stdoutLine(
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
            ),
          )
        : null,
  );

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
    renderer.stepCompleted(event, displayScope: event.displayScope);
  });

  final mapIterationSub = eventBus.on<MapIterationCompletedEvent>().listen((event) {
    if (activeRunId != null && event.runId != activeRunId) return;
    renderer.mapIterationCompleted(event, displayScope: event.itemId);
  });

  final tokenSub = eventBus.on<WorkflowCliTurnProgressEvent>().listen((event) {
    renderer.turnProgress(taskId: event.taskId, cumulativeTokens: event.cumulativeTokens);
  });

  final taskSub = eventBus.on<TaskStatusChangedEvent>().listen((event) {
    if (activeRunId == null) return;
    unawaited(
      renderer.taskStatusChanged(
        TaskProgressUpdate(taskId: event.taskId, newStatus: event.newStatus, oldStatus: event.oldStatus),
      ),
    );
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

/// Reads a task's `displayScope` config value, normalized to null when blank.
String? taskDisplayScope(Task task) {
  final scope = task.configJson['displayScope'];
  if (scope is! String) return null;
  final trimmed = scope.trim();
  return trimmed.isEmpty ? null : trimmed;
}
