import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart'
    show Task, TaskStatus, WorkflowDefinition, WorkflowRun, WorkflowRunStatus;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowService;

import 'task/task_service.dart';
import 'templates/sidebar.dart' show SidebarActiveTask, SidebarActiveWorkflow;

Future<List<SidebarActiveTask>> buildActiveSidebarTasks(TaskService tasks) async {
  final runningTasks = await tasks.list(status: TaskStatus.running);
  final reviewTasks = (await tasks.list(
    status: TaskStatus.review,
  )).where((task) => !task.isWorkflowOwnedGitTask).toList();

  runningTasks.sort((a, b) => _compareNullableDateTimeAsc(a.startedAt, b.startedAt));
  reviewTasks.sort((a, b) => _compareNullableDateTimeAsc(a.startedAt, b.startedAt));

  return [...runningTasks.map(_activeTaskPayload), ...reviewTasks.map(_activeTaskPayload)];
}

Future<List<SidebarActiveWorkflow>> buildActiveSidebarWorkflows(WorkflowService workflows, TaskService tasks) async {
  final running = await workflows.list(status: WorkflowRunStatus.running);
  final paused = await workflows.list(status: WorkflowRunStatus.paused);
  final activeRuns = [...running, ...paused];

  if (activeRuns.isEmpty) return const [];

  final allTasks = await tasks.list();
  return activeRuns.map((WorkflowRun run) {
    WorkflowDefinition? definition;
    try {
      definition = WorkflowDefinition.fromJson(run.definitionJson);
    } catch (_) {}
    final totalSteps = definition?.steps.length ?? 0;
    final childTasks = allTasks.where((Task t) => t.workflowRunId == run.id);
    final completedStepIndices = childTasks
        .where((Task t) => t.status == TaskStatus.accepted && t.stepIndex != null)
        .map((Task t) => t.stepIndex!)
        .toSet()
        .length;
    final completedSteps = totalSteps > 0 ? completedStepIndices.clamp(0, totalSteps) : 0;

    return (
      id: run.id,
      definitionName: run.definitionName,
      status: run.status.name,
      completedSteps: completedSteps,
      totalSteps: totalSteps,
    );
  }).toList();
}

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
