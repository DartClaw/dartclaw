import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show Task, TaskStatus;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show WorkflowDefinition, WorkflowRun, WorkflowRunStatus, WorkflowService, WorkflowTaskType, stepStatusFromTask;

import 'task/task_service.dart';
import 'templates/sidebar.dart' show SidebarActiveTask, SidebarActiveWorkflow;

/// Builds the running and review-pending [SidebarActiveTask]s for the sidebar.
Future<List<SidebarActiveTask>> buildActiveSidebarTasks(TaskService tasks) async {
  final runningTasks = await tasks.list(status: TaskStatus.running);
  final reviewTasks = (await tasks.list(
    status: TaskStatus.review,
  )).where((task) => !task.isWorkflowOwnedGitTask).toList();

  runningTasks.sort((a, b) => _compareNullableDateTimeAsc(a.startedAt, b.startedAt));
  reviewTasks.sort((a, b) => _compareNullableDateTimeAsc(a.startedAt, b.startedAt));

  return [...runningTasks.map(_activeTaskPayload), ...reviewTasks.map(_activeTaskPayload)];
}

/// Builds the active [SidebarActiveWorkflow]s, including step progress, for the sidebar.
Future<List<SidebarActiveWorkflow>> buildActiveSidebarWorkflows(WorkflowService workflows, TaskService tasks) async {
  final running = await workflows.list(status: WorkflowRunStatus.running);
  final paused = await workflows.list(status: WorkflowRunStatus.paused);
  final awaitingApproval = await workflows.list(status: WorkflowRunStatus.awaitingApproval);
  final activeRuns = [...running, ...paused, ...awaitingApproval];

  if (activeRuns.isEmpty) return const [];

  final allTasks = await tasks.list();
  return activeRuns.map((WorkflowRun run) {
    WorkflowDefinition? definition;
    try {
      definition = WorkflowDefinition.fromJson(run.definitionJson);
    } catch (_) {} // Malformed stored definition — render sidebar without step progress.
    final totalSteps = definition?.steps.length ?? 0;
    final tasksByStepIndex = <int, Task>{
      for (final task in allTasks.where((Task t) => t.workflowRunId == run.id))
        if (task.stepIndex != null) task.stepIndex!: task,
    };
    final completedSteps = definition == null
        ? 0
        : definition.steps.indexed
              .where((entry) {
                final (index, step) = entry;
                final status = step.taskType == WorkflowTaskType.approval
                    ? switch (run.contextJson['${step.id}.approval.status']) {
                        'approved' => 'completed',
                        _ => 'pending',
                      }
                    : stepStatusFromTask(run, index, tasksByStepIndex[index], stepId: step.id);
                return status == 'completed' || status == 'skipped';
              })
              .length
              .clamp(0, totalSteps);

    return (
      id: run.id,
      definitionName: run.definitionName,
      status: run.status.name,
      completedSteps: completedSteps,
      totalSteps: totalSteps,
    );
  }).toList();
}

/// Serializes a [SidebarActiveTask] record to its sidebar JSON payload.
Map<String, dynamic> sidebarActiveTaskToJson(SidebarActiveTask task) {
  return {
    'id': task.id,
    'title': task.title,
    'status': task.status,
    'startedAt': task.startedAt,
    'provider': task.provider,
    'providerLabel': task.providerLabel,
  };
}

/// Serializes a [SidebarActiveWorkflow] record to its sidebar JSON payload.
Map<String, dynamic> sidebarActiveWorkflowToJson(SidebarActiveWorkflow workflow) {
  return {
    'id': workflow.id,
    'definitionName': workflow.definitionName,
    'status': workflow.status,
    'completedSteps': workflow.completedSteps,
    'totalSteps': workflow.totalSteps,
  };
}

SidebarActiveTask _activeTaskPayload(Task task) {
  final provider = task.provider ?? 'claude';
  return (
    id: task.id,
    title: task.title,
    status: task.status.name,
    startedAt: task.startedAt?.toIso8601String(),
    provider: provider,
    providerLabel: ProviderIdentity.displayName(provider),
  );
}

int _compareNullableDateTimeAsc(DateTime? left, DateTime? right) {
  if (left == null && right == null) return 0;
  if (left == null) return 1;
  if (right == null) return -1;
  return left.compareTo(right);
}
