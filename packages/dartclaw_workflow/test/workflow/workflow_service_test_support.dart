import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_server/dartclaw_server.dart' show TaskService;
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        EventBus,
        KvService,
        MessageService,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowDefinition,
        WorkflowExecutionCursor,
        WorkflowGitContext,
        WorkflowGitStrategy,
        WorkflowPersistencePorts,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowService,
        WorkflowStep,
        WorkflowTurnAdapter,
        WorkflowVariable,
        WorkflowWorktreeBinding;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

final class WorkflowServiceTestHarness {
  late Directory tempDir;
  late TaskService taskService;
  late MessageService messageService;
  late KvService kvService;
  late SqliteWorkflowRunRepository repository;
  late EventBus eventBus;
  late WorkflowService workflowService;

  void setUp() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_wf_svc_test_');
    final sessionsDir = p.join(tempDir.path, 'sessions');
    Directory(sessionsDir).createSync(recursive: true);

    final db = sqlite3.openInMemory();
    eventBus = EventBus();
    final taskRepository = SqliteTaskRepository(db);
    final agentExecutionRepository = SqliteAgentExecutionRepository(db, eventBus: eventBus);
    final workflowStepExecutionRepository = SqliteWorkflowStepExecutionRepository(db);
    final executionTransactor = SqliteExecutionRepositoryTransactor(db);
    taskService = TaskService(
      taskRepository,
      agentExecutionRepository: agentExecutionRepository,
      executionTransactor: executionTransactor,
      eventBus: eventBus,
    );
    repository = SqliteWorkflowRunRepository(db);
    messageService = MessageService(baseDir: sessionsDir);
    kvService = KvService(filePath: p.join(tempDir.path, 'kv.json'));

    workflowService = WorkflowService(
      repository: repository,
      taskService: taskService,
      messageService: messageService,
      persistencePorts: WorkflowPersistencePorts(
        taskRepository: taskRepository,
        agentExecutionRepository: agentExecutionRepository,
        workflowStepExecutionRepository: workflowStepExecutionRepository,
        executionRepositoryTransactor: executionTransactor,
      ),
      eventBus: eventBus,
      kvService: kvService,
      dataDir: tempDir.path,
    );
  }

  Future<void> tearDown({WorkflowService? currentService}) async {
    final services = <WorkflowService>{workflowService, ?currentService};
    for (final service in services) {
      await service.dispose();
    }
    await taskService.dispose();
    await messageService.dispose();
    await kvService.dispose();
    await eventBus.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  }

  WorkflowDefinition makeDefinition({
    List<WorkflowStep>? steps,
    Map<String, WorkflowVariable> variables = const {},
    WorkflowGitStrategy? gitStrategy,
  }) {
    return WorkflowDefinition(
      name: 'test-workflow',
      description: 'Test workflow',
      variables: variables,
      gitStrategy: gitStrategy,
      steps:
          steps ??
          [
            const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
          ],
    );
  }

  WorkflowService lifecycleOnlyService({WorkflowTurnAdapter? turnAdapter, WorkflowGitContext? gitContext}) {
    return WorkflowService.lifecycleOnly(
      repository: repository,
      taskService: taskService,
      messageService: messageService,
      eventBus: eventBus,
      kvService: kvService,
      dataDir: tempDir.path,
      turnAdapter: turnAdapter,
      gitContext: gitContext,
    );
  }

  void autoCompleteNewTasks([List<String>? titles]) {
    eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      if (titles != null) {
        final task = await taskService.get(e.taskId);
        if (task != null) titles.add(task.title);
      }
      try {
        await taskService.transition(e.taskId, TaskStatus.running, trigger: 'test');
        await taskService.transition(e.taskId, TaskStatus.review, trigger: 'test');
        await taskService.transition(e.taskId, TaskStatus.accepted, trigger: 'test');
      } on StateError {
        // Some tests deliberately move tasks before the queued listener runs.
      }
    });
  }

  Future<void> waitForRunStatus(String runId, WorkflowRunStatus expected) async {
    for (var i = 0; i < 200; i++) {
      final stored = await repository.getById(runId);
      if (stored?.status == expected) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final stored = await repository.getById(runId);
    fail('Expected workflow $runId to reach ${expected.name}, found ${stored?.status.name}');
  }

  void writeContextSnapshot(String runId, Map<String, dynamic> contextJson) {
    final contextDir = Directory(p.join(tempDir.path, 'workflows', 'runs', runId))..createSync(recursive: true);
    File(p.join(contextDir.path, 'context.json')).writeAsStringSync(jsonEncode(contextJson));
  }

  Future<WorkflowRun> insertRun({
    required String id,
    WorkflowDefinition? definition,
    WorkflowRunStatus status = WorkflowRunStatus.running,
    int? currentStepIndex,
    Map<String, String> variablesJson = const {},
    Map<String, dynamic> contextJson = const {},
    WorkflowExecutionCursor? executionCursor,
    WorkflowWorktreeBinding? workflowWorktree,
    String? errorMessage,
    bool writeContextFile = false,
  }) async {
    final now = DateTime.now();
    final resolvedDefinition = definition ?? makeDefinition();
    final run = WorkflowRun(
      id: id,
      definitionName: resolvedDefinition.name,
      status: status,
      startedAt: now,
      updatedAt: now,
      completedAt: status.terminal ? now : null,
      errorMessage: errorMessage,
      currentStepIndex: currentStepIndex ?? 0,
      variablesJson: variablesJson,
      definitionJson: resolvedDefinition.toJson(),
      contextJson: contextJson,
      executionCursor: executionCursor,
      workflowWorktree: workflowWorktree,
    );
    await repository.insert(run);
    if (writeContextFile) {
      writeContextSnapshot(run.id, run.contextJson);
    }
    return run;
  }
}
