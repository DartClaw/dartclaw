// Shared test harness for WorkflowExecutor concern-focused test files.
//
// Each executor_*.dart file creates a [WorkflowExecutorHarness], calls its
// setUp/tearDown from the test setUp/tearDown hooks, and uses the helper
// factories directly on the harness instance.
library;

import 'dart:async';
import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        BashStepPolicy,
        ContextExtractor,
        EventBus,
        GateEvaluator,
        KvService,
        MessageService,
        SessionService,
        StepExecutionContext,
        Task,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowExecutor,
        WorkflowGitPort,
        WorkflowLoop,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowStep,
        WorkflowStepOutputTransformer,
        WorkflowTurnAdapter;
import 'package:dartclaw_server/dartclaw_server.dart' show TaskService, WorkflowGitPortProcess;
import 'package:dartclaw_core/dartclaw_core.dart' show ProjectService;
import 'package:dartclaw_storage/dartclaw_storage.dart'
    show
        SqliteAgentExecutionRepository,
        SqliteExecutionRepositoryTransactor,
        SqliteTaskRepository,
        SqliteWorkflowRunRepository,
        SqliteWorkflowStepExecutionRepository;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Shared harness for WorkflowExecutor component tests.
///
/// Call [setUp] / [tearDown] in each test file's setUp/tearDown hooks.
/// Provides [makeExecutor], [makeRun], [makeDefinition], [completeTask],
/// and [executeAndCaptureSingleTask] utilities.
final class WorkflowExecutorHarness {
  late Directory tempDir;
  late String sessionsDir;
  late Database db;
  late SqliteTaskRepository taskRepository;
  late TaskService taskService;
  late SessionService sessionService;
  late MessageService messageService;
  late KvService kvService;
  late SqliteWorkflowRunRepository repository;
  late SqliteAgentExecutionRepository agentExecutionRepository;
  late SqliteWorkflowStepExecutionRepository workflowStepExecutionRepository;
  late SqliteExecutionRepositoryTransactor executionRepositoryTransactor;
  late EventBus eventBus;
  late WorkflowExecutor executor;

  void setUp() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_wf_exec_test_');
    sessionsDir = p.join(tempDir.path, 'sessions');
    Directory(sessionsDir).createSync(recursive: true);

    db = sqlite3.openInMemory();
    eventBus = EventBus();
    taskRepository = SqliteTaskRepository(db);
    agentExecutionRepository = SqliteAgentExecutionRepository(db, eventBus: eventBus);
    workflowStepExecutionRepository = SqliteWorkflowStepExecutionRepository(db);
    executionRepositoryTransactor = SqliteExecutionRepositoryTransactor(db);
    taskService = TaskService(
      taskRepository,
      agentExecutionRepository: agentExecutionRepository,
      executionTransactor: executionRepositoryTransactor,
      eventBus: eventBus,
    );
    repository = SqliteWorkflowRunRepository(db);
    sessionService = SessionService(baseDir: sessionsDir);
    messageService = MessageService(baseDir: sessionsDir);
    kvService = KvService(filePath: p.join(tempDir.path, 'kv.json'));

    executor = makeExecutor();
  }

  Future<void> tearDown() async {
    await taskService.dispose();
    await messageService.dispose();
    await kvService.dispose();
    await eventBus.dispose();
    db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  }

  WorkflowExecutor makeExecutor({
    WorkflowTurnAdapter? turnAdapter,
    WorkflowStepOutputTransformer? outputTransformer,
    ProjectService? projectService,
    ContextExtractor? contextExtractor,
    bool wirePersistence = true,
    Map<String, String>? hostEnvironment,
    List<String>? bashStepEnvAllowlist,
    List<String>? bashStepExtraStripPatterns,
    WorkflowGitPort? workflowGitPort,
  }) {
    return WorkflowExecutor(
      executionContext: StepExecutionContext(
        taskService: taskService,
        eventBus: eventBus,
        kvService: kvService,
        repository: repository,
        gateEvaluator: GateEvaluator(),
        contextExtractor:
            contextExtractor ??
            ContextExtractor(
              taskService: taskService,
              messageService: messageService,
              dataDir: tempDir.path,
              workflowStepExecutionRepository: wirePersistence ? workflowStepExecutionRepository : null,
            ),
        turnAdapter: turnAdapter,
        outputTransformer: outputTransformer,
        workflowGitPort: workflowGitPort ?? WorkflowGitPortProcess(),
        taskRepository: wirePersistence ? taskRepository : null,
        agentExecutionRepository: wirePersistence ? agentExecutionRepository : null,
        workflowStepExecutionRepository: wirePersistence ? workflowStepExecutionRepository : null,
        executionTransactor: wirePersistence ? executionRepositoryTransactor : null,
        projectService: projectService,
      ),
      dataDir: tempDir.path,
      bashStepPolicy: hostEnvironment != null || bashStepEnvAllowlist != null || bashStepExtraStripPatterns != null
          ? BashStepPolicy(
              hostEnvironment: hostEnvironment,
              envAllowlist: bashStepEnvAllowlist ?? BashStepPolicy.defaultEnvAllowlist,
              extraStripPatterns: bashStepExtraStripPatterns ?? const <String>[],
            )
          : const BashStepPolicy(),
    );
  }

  WorkflowRun makeRun(WorkflowDefinition definition, {int stepIndex = 0}) {
    final now = DateTime.now();
    return WorkflowRun(
      id: 'run-1',
      definitionName: definition.name,
      status: WorkflowRunStatus.running,
      startedAt: now,
      updatedAt: now,
      currentStepIndex: stepIndex,
      definitionJson: definition.toJson(),
    );
  }

  WorkflowDefinition makeDefinition({
    List<WorkflowStep>? steps,
    int? maxTokens,
    List<WorkflowLoop> loops = const [],
  }) {
    return WorkflowDefinition(
      name: 'test-workflow',
      description: 'Test workflow',
      steps:
          steps ??
          [
            const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
          ],
      loops: loops,
      maxTokens: maxTokens,
    );
  }

  /// Simulates task completion: queued → running → [review →] terminal.
  Future<void> completeTask(String taskId, {TaskStatus status = TaskStatus.accepted}) async {
    try {
      await taskService.transition(taskId, TaskStatus.running, trigger: 'test');
    } on StateError {
      // May already be running.
    }
    if (status == TaskStatus.accepted || status == TaskStatus.rejected) {
      try {
        await taskService.transition(taskId, TaskStatus.review, trigger: 'test');
      } on StateError {
        // May already be in review.
      }
    }
    await taskService.transition(taskId, status, trigger: 'test');
  }

  Future<Task> executeAndCaptureSingleTask({
    required WorkflowDefinition definition,
    required WorkflowContext context,
    String runId = 'run-capture',
  }) async {
    final run = makeRun(definition).copyWith(id: runId, variablesJson: context.variables);
    await repository.insert(run);

    final taskCompleter = Completer<Task>();
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      final task = await taskService.get(e.taskId);
      if (task != null && !taskCompleter.isCompleted) {
        taskCompleter.complete(task);
      }
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();
    return taskCompleter.future;
  }
}
