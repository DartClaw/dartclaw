import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowRunRepository;

import 'artifact_collector.dart';
import 'goal_service.dart';
import 'task_event_recorder.dart';
import 'task_file_guard.dart';
import 'task_service.dart';
import 'worktree_manager.dart';

/// Repository, bus, and service dependencies for [TaskExecutor].
class TaskExecutorServices {
  const TaskExecutorServices({
    required this.tasks,
    this.goals,
    required this.sessions,
    required this.messages,
    required this.artifactCollector,
    this.worktreeManager,
    this.taskFileGuard,
    this.traceService,
    this.eventRecorder,
    this.workflowStepExecutionRepository,
    this.workflowRunRepository,
    this.projectService,
    this.kvService,
    this.eventBus,
  });

  final TaskService tasks;
  final GoalService? goals;
  final SessionService sessions;
  final MessageService messages;
  final ArtifactCollector artifactCollector;
  final WorktreeManager? worktreeManager;
  final TaskFileGuard? taskFileGuard;
  final TurnTraceService? traceService;
  final TaskEventRecorder? eventRecorder;
  final WorkflowStepExecutionRepository? workflowStepExecutionRepository;
  final WorkflowRunRepository? workflowRunRepository;
  final ProjectService? projectService;
  final KvService? kvService;
  final EventBus? eventBus;
}
