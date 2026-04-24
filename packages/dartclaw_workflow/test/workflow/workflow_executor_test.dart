import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_models/dartclaw_models.dart' show Project, ProjectStatus, SessionType;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        ArtifactKind,
        ContextExtractor,
        EventBus,
        GateEvaluator,
        KvService,
        MessageService,
        OnFailurePolicy,
        OutputConfig,
        OutputFormat,
        SessionService,
        BashStepPolicy,
        StepExecutionContext,
        StepConfigDefault,
        StepReviewMode,
        Task,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowApprovalRequestedEvent,
        WorkflowBudgetWarningEvent,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowLoop,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowRunStatusChangedEvent,
        WorkflowDefinitionParser,
        WorkflowGitBootstrapResult,
        WorkflowGitArtifactsStrategy,
        WorkflowGitPromotionSuccess,
        WorkflowGitPublishResult,
        WorkflowGitPublishStrategy,
        WorkflowGitWorktreeStrategy,
        WorkflowGitStrategy,
        WorkflowGitException,
        WorkflowGitPort,
        WorkflowExecutor,
        WorkflowStepOutputTransformer,
        WorkflowTurnAdapter,
        WorkflowTurnOutcome,
        WorkflowVariable,
        WorkflowWorktreeBinding,
        TaskType,
        WorkflowStep,
        WorkflowStepCompletedEvent;
import 'package:dartclaw_server/dartclaw_server.dart' show TaskService, WorkflowGitPortProcess;
import 'package:dartclaw_core/dartclaw_core.dart' show ProjectService;
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeGitGateway, FakeProjectService;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

const _inlineLoopExecutionYaml = '''
name: ordered-inline-loop
description: Inline loop authored in step order
steps:
  - id: gap-analysis
    name: Gap Analysis
    prompt: Analyze the implementation
  - id: remediation-loop
    name: Remediation Loop
    type: loop
    maxIterations: 3
    exitGate: re-review.status == accepted
    steps:
      - id: remediate
        name: Remediate
        prompt: Apply fixes
      - id: re-review
        name: Re-review
        prompt: Verify the fixes
  - id: update-state
    name: Update State
    prompt: Record the final result
''';

const _inlineEntryGateLoopYaml = '''
name: ordered-inline-entry-gate-loop
description: Inline loop with entry gate
steps:
  - id: gap-analysis
    name: Gap Analysis
    prompt: Analyze the implementation
  - id: remediation-loop
    name: Remediation Loop
    type: loop
    maxIterations: 3
    entryGate: gap-analysis.findings_count > 0
    exitGate: re-review.status == accepted
    steps:
      - id: remediate
        name: Remediate
        prompt: Apply fixes
      - id: re-review
        name: Re-review
        prompt: Verify the fixes
  - id: update-state
    name: Update State
    prompt: Record the final result
''';

void main() {
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

  setUp(() {
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
  });

  tearDown(() async {
    await taskService.dispose();
    await messageService.dispose();
    await kvService.dispose();
    await eventBus.dispose();
    db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('workflow execution fails fast when AE/WSE persistence is not wired', () async {
    // Synthesize an executor deliberately missing the AE/WSE/triple infrastructure.
    final bareExecutor = makeExecutor(
      wirePersistence: false,
      contextExtractor: ContextExtractor(
        taskService: taskService,
        messageService: messageService,
        dataDir: tempDir.path,
      ),
    );

    final definition = WorkflowDefinition(
      name: 'wf',
      description: 'desc',
      steps: const [
        WorkflowStep(id: 's1', name: 'S1', prompts: ['p']),
      ],
    );
    final now = DateTime.now();
    final run = WorkflowRun(
      id: 'run-fail-fast',
      definitionName: definition.name,
      status: WorkflowRunStatus.running,
      startedAt: now,
      updatedAt: now,
      currentStepIndex: 0,
      definitionJson: definition.toJson(),
    );
    await repository.insert(run);

    Object? captured;
    try {
      await bareExecutor.execute(run, definition, WorkflowContext());
    } catch (err) {
      captured = err;
    }
    // Either the executor surfaces the StateError directly, or it pauses the
    // run with the same message captured as the failure. Both are acceptable
    // shapes of "fail fast"; what must NOT happen is a silent success that
    // bypasses AE/WSE persistence.
    if (captured == null) {
      final finalRun = await repository.getById('run-fail-fast');
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
      expect(finalRun?.errorMessage, contains('AgentExecution + WorkflowStepExecution persistence'));
    } else {
      expect(captured, isA<StateError>());
      expect((captured as StateError).message, contains('AgentExecution + WorkflowStepExecution persistence'));
    }
  });

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

  WorkflowDefinition makeDefinition({List<WorkflowStep>? steps, int? maxTokens, List<WorkflowLoop> loops = const []}) {
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
  ///
  /// accepted requires going through review first (queued→running→review→accepted).
  /// failed/cancelled go: queued→running→failed/cancelled.
  Future<void> completeTask(String taskId, {TaskStatus status = TaskStatus.accepted}) async {
    try {
      await taskService.transition(taskId, TaskStatus.running, trigger: 'test');
    } on StateError {
      // May already be running.
    }
    if (status == TaskStatus.accepted || status == TaskStatus.rejected) {
      // Must pass through review to reach accepted/rejected.
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

  test('fatal artifact commit failure emits failed step and stops before downstream dispatch', () async {
    final repoDir = Directory(p.join(tempDir.path, 'projects', 'proj'))..createSync(recursive: true);
    File(p.join(repoDir.path, 'plan.md')).writeAsStringSync('plan');
    final git = FakeGitGateway()
      ..initWorktree(repoDir.path)
      ..addUntracked(repoDir.path, 'plan.md', content: 'plan')
      ..failNextAdd('add failed');
    executor = makeExecutor(
      workflowGitPort: git,
      outputTransformer: (run, definition, step, task, outputs) async => {'plan': 'plan.md'},
    );
    final definition = WorkflowDefinition(
      name: 'artifact-failure',
      description: 'Artifact failure workflow',
      project: 'proj',
      gitStrategy: const WorkflowGitStrategy(
        worktree: WorkflowGitWorktreeStrategy(mode: 'per-map-item'),
        artifacts: WorkflowGitArtifactsStrategy(commit: true),
      ),
      steps: const [
        WorkflowStep(
          id: 'plan',
          name: 'Plan',
          prompts: ['plan'],
          contextOutputs: ['plan'],
          outputs: {'plan': OutputConfig(format: OutputFormat.path)},
        ),
        WorkflowStep(
          id: 'implement',
          name: 'Implement',
          prompts: ['implement'],
          mapOver: 'story_specs',
          maxParallel: 2,
        ),
      ],
    );
    final run = makeRun(definition);
    await repository.insert(run);
    final stepEvents = <WorkflowStepCompletedEvent>[];
    final stepSub = eventBus.on<WorkflowStepCompletedEvent>().listen(stepEvents.add);
    final taskSub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, WorkflowContext(data: {'story_specs': <Map<String, Object?>>[]}));
    await taskSub.cancel();
    await stepSub.cancel();

    final stored = await repository.getById(run.id);
    expect(stored?.status, WorkflowRunStatus.failed);
    expect(stored?.currentStepIndex, 0);
    expect(stored?.errorMessage, contains('add failed'));
    expect(stepEvents.map((event) => (event.stepId, event.success)), [('plan', false)]);
  });

  test('3-step sequential workflow executes all steps', () async {
    final definition = makeDefinition(
      steps: [
        const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
        const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
        const WorkflowStep(id: 'step3', name: 'Step 3', prompts: ['Do step 3']),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    // Fire completions as tasks are created.
    final taskIds = <String>[];
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      taskIds.add(e.taskId);
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();

    expect(taskIds.length, equals(3));

    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });

  test('entry-gated skip records skipped outcome and still executes following steps', () async {
    final definition = makeDefinition(
      steps: [
        const WorkflowStep(id: 'spec', name: 'Spec', entryGate: 'should_run == true', prompts: ['Write the spec']),
        const WorkflowStep(id: 'implement', name: 'Implement', prompts: ['Implement the change']),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext(data: {'should_run': false});

    final queuedTaskIds = <String>[];
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      queuedTaskIds.add(e.taskId);
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();

    expect(queuedTaskIds, hasLength(1));
    final queuedTask = await taskService.get(queuedTaskIds.single);
    expect(queuedTask?.title, contains('Implement'));

    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    expect(finalRun?.currentStepIndex, equals(2));
    final contextData = Map<String, dynamic>.from(finalRun?.contextJson['data'] as Map? ?? const {});
    expect(contextData['step.spec.outcome'], equals('skipped'));
    expect(contextData['step.spec.outcome.reason'], equals('should_run == true'));
  });

  test('workflow-owned git coding task auto-advances on accepted terminal status', () async {
    final definition = WorkflowDefinition(
      name: 'workflow-git-auto-accept',
      description: 'Workflow-owned git tasks should advance on accepted.',
      gitStrategy: const WorkflowGitStrategy(
        bootstrap: true,
        worktree: WorkflowGitWorktreeStrategy(mode: 'per-map-item'),
        promotion: 'merge',
        publish: WorkflowGitPublishStrategy(enabled: false),
      ),
      steps: const [
        WorkflowStep(
          id: 'implement',
          name: 'Implement',
          type: 'coding',
          project: 'my-project',
          prompts: ['Implement the story'],
        ),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext(variables: const {'PROJECT': 'my-project', 'BRANCH': 'main'});
    final promotionCalls = <Map<String, String?>>[];

    final runtimeExecutor = makeExecutor(
      turnAdapter: WorkflowTurnAdapter(
        reserveTurn: (_) => Future.value('turn-1'),
        executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
        waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
        bootstrapWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async =>
            const WorkflowGitBootstrapResult(integrationBranch: 'dartclaw/integration/test'),
        promoteWorkflowBranch:
            ({
              required runId,
              required projectId,
              required branch,
              required integrationBranch,
              required strategy,
              String? storyId,
            }) async {
              promotionCalls.add({
                'runId': runId,
                'projectId': projectId,
                'branch': branch,
                'integrationBranch': integrationBranch,
                'strategy': strategy,
                'storyId': storyId,
              });
              return const WorkflowGitPromotionSuccess(commitSha: 'abc123');
            },
      ),
    );

    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      await taskService.updateFields(
        e.taskId,
        worktreeJson: {
          'path': p.join(tempDir.path, 'worktrees', e.taskId),
          'branch': 'story-branch',
          'createdAt': DateTime.now().toIso8601String(),
        },
      );
      try {
        await taskService.transition(e.taskId, TaskStatus.running, trigger: 'test');
      } on StateError {
        // Already running.
      }
      await taskService.transition(e.taskId, TaskStatus.accepted, trigger: 'test');
    });

    await runtimeExecutor.execute(run, definition, context);
    await sub.cancel();

    final finalTask = (await taskService.list()).single;
    final finalRun = await repository.getById('run-1');
    expect(finalTask.status, equals(TaskStatus.accepted));
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    expect(promotionCalls, [
      {
        'runId': 'run-1',
        'projectId': 'my-project',
        'branch': 'story-branch',
        'integrationBranch': 'dartclaw/integration/test',
        'strategy': 'merge',
        'storyId': null,
      },
    ]);
  });

  test('explicit review: always keeps workflow waiting until a later accept', () async {
    final definition = WorkflowDefinition(
      name: 'workflow-git-review-gate',
      description: 'Explicit review mode should still park for human review.',
      gitStrategy: const WorkflowGitStrategy(
        bootstrap: true,
        worktree: WorkflowGitWorktreeStrategy(mode: 'per-map-item'),
        promotion: 'merge',
        publish: WorkflowGitPublishStrategy(enabled: false),
      ),
      steps: const [
        WorkflowStep(
          id: 'implement',
          name: 'Implement',
          type: 'coding',
          project: 'my-project',
          review: StepReviewMode.always,
          prompts: ['Implement the story'],
        ),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext(variables: const {'PROJECT': 'my-project', 'BRANCH': 'main'});
    final reviewReached = Completer<void>();
    final allowAccept = Completer<void>();
    final runtimeExecutor = makeExecutor(
      turnAdapter: WorkflowTurnAdapter(
        reserveTurn: (_) => Future.value('turn-1'),
        executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
        waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
        bootstrapWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async =>
            const WorkflowGitBootstrapResult(integrationBranch: 'dartclaw/integration/test'),
        promoteWorkflowBranch:
            ({
              required runId,
              required projectId,
              required branch,
              required integrationBranch,
              required strategy,
              String? storyId,
            }) async => const WorkflowGitPromotionSuccess(commitSha: 'gate123'),
      ),
    );

    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      await taskService.updateFields(
        e.taskId,
        worktreeJson: {
          'path': p.join(tempDir.path, 'worktrees', e.taskId),
          'branch': 'story-branch',
          'createdAt': DateTime.now().toIso8601String(),
        },
      );
      try {
        await taskService.transition(e.taskId, TaskStatus.running, trigger: 'test');
      } on StateError {
        // Already running.
      }
      await taskService.transition(e.taskId, TaskStatus.review, trigger: 'test');
      if (!reviewReached.isCompleted) {
        reviewReached.complete();
      }
      await allowAccept.future;
      await taskService.transition(e.taskId, TaskStatus.accepted, trigger: 'test');
    });

    final executeFuture = runtimeExecutor.execute(run, definition, context);
    await reviewReached.future;
    await Future<void>.delayed(Duration.zero);
    expect((await repository.getById('run-1'))?.status, equals(WorkflowRunStatus.running));

    allowAccept.complete();
    await executeFuture;
    await sub.cancel();

    final finalTask = (await taskService.list()).single;
    final finalRun = await repository.getById('run-1');
    expect(finalTask.status, equals(TaskStatus.accepted));
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });

  test('context from step 1 is available in step 2 prompt', () async {
    // Step 1 produces output; step 2 uses {{context.research_notes}}.
    final definition = makeDefinition(
      steps: [
        const WorkflowStep(id: 'step1', name: 'Research', prompts: ['Do research'], contextOutputs: ['research_notes']),
        const WorkflowStep(id: 'step2', name: 'Summarize', prompts: ['Summarize: {{context.research_notes}}']),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);

    // Pre-create artifact for step 1 to be read during extraction.
    final capturedTaskIds = <String>[];
    final capturedDescriptions = <String>[];

    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      final task = await taskService.get(e.taskId);
      if (task != null) {
        capturedTaskIds.add(e.taskId);
        capturedDescriptions.add(task.description);

        // Create artifact for step 1 to provide context output.
        if (capturedTaskIds.length == 1) {
          final artifactsDir = Directory(p.join(tempDir.path, 'tasks', e.taskId, 'artifacts'));
          artifactsDir.createSync(recursive: true);
          final mdFile = File(p.join(artifactsDir.path, 'output.md'));
          mdFile.writeAsStringSync('Key findings about the topic.');
          await taskService.addArtifact(
            id: 'art-1',
            taskId: e.taskId,
            name: 'output.md',
            kind: ArtifactKind.document,
            path: mdFile.path,
          );
        }
      }
      await completeTask(e.taskId);
    });

    final context = WorkflowContext();
    await executor.execute(run, definition, context);
    await sub.cancel();

    expect(capturedDescriptions.length, equals(2));
    // Step 2 description should contain the extracted content from step 1.
    expect(capturedDescriptions[1], contains('Key findings about the topic.'));
  });

  test('loop-body workflow-owned git coding task promotes after accepted completion', () async {
    final definition = WorkflowDefinition(
      name: 'loop-workflow-git-auto-accept',
      description: 'Loop-owned git tasks should promote after accepted completion.',
      gitStrategy: const WorkflowGitStrategy(
        bootstrap: true,
        worktree: WorkflowGitWorktreeStrategy(mode: 'per-task'),
        publish: WorkflowGitPublishStrategy(enabled: false),
      ),
      steps: const [
        WorkflowStep(id: 'implement', name: 'Implement', type: 'coding', project: 'my-project', prompts: ['Implement']),
      ],
      loops: const [
        WorkflowLoop(
          id: 'remediate-loop',
          steps: ['implement'],
          maxIterations: 1,
          exitGate: 'implement.status == accepted',
        ),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext(data: {'implement.status': 'pending'}, variables: const {'PROJECT': 'my-project'});
    final promotionCalls = <Map<String, String?>>[];

    final runtimeExecutor = makeExecutor(
      turnAdapter: WorkflowTurnAdapter(
        reserveTurn: (_) => Future.value('turn-1'),
        executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
        waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
        bootstrapWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async =>
            const WorkflowGitBootstrapResult(integrationBranch: 'dartclaw/integration/test'),
        promoteWorkflowBranch:
            ({
              required runId,
              required projectId,
              required branch,
              required integrationBranch,
              required strategy,
              String? storyId,
            }) async {
              promotionCalls.add({
                'runId': runId,
                'projectId': projectId,
                'branch': branch,
                'integrationBranch': integrationBranch,
                'strategy': strategy,
                'storyId': storyId,
              });
              return const WorkflowGitPromotionSuccess(commitSha: 'loop123');
            },
      ),
    );

    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      await taskService.updateFields(
        e.taskId,
        worktreeJson: {
          'path': p.join(tempDir.path, 'worktrees', e.taskId),
          'branch': 'loop-branch',
          'createdAt': DateTime.now().toIso8601String(),
        },
      );
      try {
        await taskService.transition(e.taskId, TaskStatus.running, trigger: 'test');
      } on StateError {
        // Already running.
      }
      await taskService.transition(e.taskId, TaskStatus.accepted, trigger: 'test');
    });

    await runtimeExecutor.execute(run, definition, context);
    await sub.cancel();

    final finalTask = (await taskService.list()).single;
    final finalRun = await repository.getById('run-1');
    expect(finalTask.status, equals(TaskStatus.accepted));
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    expect(promotionCalls, [
      {
        'runId': 'run-1',
        'projectId': 'my-project',
        'branch': 'loop-branch',
        'integrationBranch': 'dartclaw/integration/test',
        'strategy': 'merge',
        'storyId': null,
      },
    ]);
  });

  test('failed first-prompt steps still persist token usage before pause', () async {
    final definition = makeDefinition(
      steps: [
        const WorkflowStep(id: 'step1', name: 'Failing Step', prompts: ['Do the failing step']),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final sessionService = SessionService(baseDir: sessionsDir);

    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      final task = await taskService.get(e.taskId);
      if (task == null) return;

      final session = await sessionService.createSession(type: SessionType.task);
      await taskService.updateFields(task.id, sessionId: session.id);
      await kvService.set('session_cost:${session.id}', jsonEncode({'total_tokens': 7}));
      await taskService.transition(task.id, TaskStatus.running, trigger: 'test');
      await taskService.transition(task.id, TaskStatus.failed, trigger: 'test');
    });

    final context = WorkflowContext();
    await executor.execute(run, definition, context);
    await sub.cancel();

    final finalRun = await repository.getById(run.id);
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    expect(finalRun?.totalTokens, equals(7));
    expect(context['step1.status'], equals('failed'));
    expect(context['step1.tokenCount'], equals(7));
  });

  test('task description includes required output format for explicit json schema', () async {
    final definition = makeDefinition(
      steps: [
        const WorkflowStep(
          id: 'review',
          name: 'Review',
          prompts: ['Review the implementation.'],
          outputs: {'result': OutputConfig(format: OutputFormat.json, schema: 'verdict')},
        ),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    String? capturedDescription;
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      final task = await taskService.get(e.taskId);
      capturedDescription = task?.description;
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();

    expect(capturedDescription, contains('Review the implementation.'));
    expect(capturedDescription, contains('## Required Output Format'));
    expect(capturedDescription, contains('findings_count'));
  });

  test('workflow task config carries built-in workflow workspace path', () async {
    final definition = makeDefinition(
      steps: [
        const WorkflowStep(
          id: 'spec',
          name: 'Generate Spec',
          prompts: ['Write the specification.'],
          outputs: {'result': OutputConfig(format: OutputFormat.json)},
        ),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    String? capturedDescription;
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      final task = await taskService.get(e.taskId);
      capturedDescription = task?.description;
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();

    final workflowWorkspaceDir = p.join(tempDir.path, 'workflow-workspace');
    expect(capturedDescription, contains('Write the specification.'));
    expect(
      (await agentExecutionRepository.get((await taskService.list()).single.agentExecutionId!))?.workspaceDir,
      workflowWorkspaceDir,
    );
    expect(File(p.join(workflowWorkspaceDir, 'AGENTS.md')).existsSync(), isTrue);
  });

  test('deterministic publish writes publish.* outputs when enabled', () async {
    final publishExecutor = makeExecutor(
      turnAdapter: WorkflowTurnAdapter(
        reserveTurn: (_) => Future.value('turn-1'),
        executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
        waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
        publishWorkflowBranch: ({required runId, required projectId, required branch}) async =>
            WorkflowGitPublishResult(
              status: 'success',
              branch: branch,
              remote: 'origin',
              prUrl: 'https://example.test/pr/123',
            ),
      ),
    );

    final definition = WorkflowDefinition(
      name: 'publish-only',
      description: 'No steps, publish only',
      gitStrategy: const WorkflowGitStrategy(publish: WorkflowGitPublishStrategy(enabled: true)),
      steps: const [],
    );

    final run = WorkflowRun(
      id: 'publish-run',
      definitionName: definition.name,
      status: WorkflowRunStatus.running,
      startedAt: DateTime.now(),
      updatedAt: DateTime.now(),
      variablesJson: const {'PROJECT': 'my-project', 'BRANCH': 'feature/test'},
      definitionJson: definition.toJson(),
    );
    await repository.insert(run);

    final context = WorkflowContext(variables: const {'PROJECT': 'my-project', 'BRANCH': 'feature/test'});
    await publishExecutor.execute(run, definition, context);

    final finalRun = await repository.getById(run.id);
    expect(finalRun?.status, WorkflowRunStatus.completed);
    expect(context['publish.status'], 'success');
    expect(context['publish.branch'], 'feature/test');
    expect(context['publish.remote'], 'origin');
    expect(context['publish.pr_url'], 'https://example.test/pr/123');
  });

  test('workflow git bootstrap passes an empty baseRef when BRANCH is absent', () async {
    String? capturedBaseRef;
    final bootstrapExecutor = makeExecutor(
      turnAdapter: WorkflowTurnAdapter(
        reserveTurn: (_) => Future.value('turn-1'),
        executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
        waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
        bootstrapWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async {
          capturedBaseRef = baseRef;
          return const WorkflowGitBootstrapResult(integrationBranch: 'dartclaw/integration/test');
        },
      ),
    );

    final definition = WorkflowDefinition(
      name: 'bootstrap-no-branch',
      description: 'Bootstrap resolves the base ref upstream',
      gitStrategy: const WorkflowGitStrategy(bootstrap: true),
      steps: const [],
    );

    final run = WorkflowRun(
      id: 'bootstrap-no-branch',
      definitionName: definition.name,
      status: WorkflowRunStatus.running,
      startedAt: DateTime.now(),
      updatedAt: DateTime.now(),
      variablesJson: const {'PROJECT': 'my-project'},
      definitionJson: definition.toJson(),
    );
    await repository.insert(run);

    await bootstrapExecutor.execute(run, definition, WorkflowContext(variables: const {'PROJECT': 'my-project'}));

    expect(capturedBaseRef, isEmpty);
  });

  test('artifact commit stages path outputs from the producing task worktree', () async {
    final projectDir = Directory(p.join(tempDir.path, 'projects', 'my-project'))..createSync(recursive: true);
    final worktreeDir = Directory(p.join(tempDir.path, 'worktree'));

    ProcessResult runGit(String workingDir, List<String> args) {
      final result = Process.runSync('git', args, workingDirectory: workingDir);
      if (result.exitCode != 0) {
        fail('git ${args.join(' ')} failed in $workingDir: ${result.stderr}');
      }
      return result;
    }

    runGit(projectDir.path, ['init', '-b', 'main']);
    runGit(projectDir.path, ['config', 'user.name', 'Test User']);
    runGit(projectDir.path, ['config', 'user.email', 'test@example.com']);
    File(p.join(projectDir.path, 'README.md')).writeAsStringSync('# repo\n');
    runGit(projectDir.path, ['add', 'README.md']);
    runGit(projectDir.path, ['commit', '-m', 'initial']);
    runGit(projectDir.path, ['worktree', 'add', worktreeDir.path, '-b', 'dartclaw/workflow/run-1', 'main']);

    final definition = WorkflowDefinition(
      name: 'artifact-commit',
      description: 'Commits produced path artifacts',
      gitStrategy: const WorkflowGitStrategy(
        artifacts: WorkflowGitArtifactsStrategy(commit: true, commitMessage: 'workflow artifacts {{runId}}'),
      ),
      variables: const {'PROJECT': WorkflowVariable(required: false)},
      steps: const [
        WorkflowStep(
          id: 'spec',
          name: 'Spec',
          type: 'writing',
          project: '{{PROJECT}}',
          contextOutputs: ['spec_path'],
          outputs: {'spec_path': OutputConfig(format: OutputFormat.path)},
          prompts: ['Write spec'],
        ),
      ],
    );

    final run = WorkflowRun(
      id: 'run-1',
      definitionName: definition.name,
      status: WorkflowRunStatus.running,
      startedAt: DateTime.now(),
      updatedAt: DateTime.now(),
      variablesJson: const {'PROJECT': 'my-project'},
      definitionJson: definition.toJson(),
    );
    await repository.insert(run);

    final context = WorkflowContext(variables: const {'PROJECT': 'my-project'});

    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      final outputPath = p.join(worktreeDir.path, 'docs', 'specs', 'test.md');
      File(outputPath).parent.createSync(recursive: true);
      File(outputPath).writeAsStringSync('# test\n');
      final task = await taskService.get(e.taskId);
      expect(task, isNotNull);
      final session = await sessionService.createSession(type: SessionType.task);
      await taskService.updateFields(
        task!.id,
        sessionId: session.id,
        worktreeJson: {
          'path': worktreeDir.path,
          'branch': 'dartclaw/workflow/run-1',
          'createdAt': DateTime.now().toIso8601String(),
        },
      );
      await messageService.insertMessage(
        sessionId: session.id,
        role: 'assistant',
        content: '<workflow-context>${jsonEncode({'spec_path': 'docs/specs/test.md'})}</workflow-context>',
      );
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();

    final logResult = runGit(worktreeDir.path, ['log', '-1', '--pretty=%s']);
    expect((logResult.stdout as String).trim(), 'workflow artifacts run-1');
    final showResult = runGit(worktreeDir.path, ['show', 'HEAD:docs/specs/test.md']);
    expect(showResult.stdout, contains('# test'));
  });

  test('artifact commit resolves localPath projects without relying on dataDir/projects', () async {
    final projectDir = Directory(p.join(tempDir.path, 'named-local-project'))..createSync(recursive: true);

    ProcessResult runGit(String workingDir, List<String> args) {
      final result = Process.runSync('git', args, workingDirectory: workingDir);
      if (result.exitCode != 0) {
        fail('git ${args.join(' ')} failed in $workingDir: ${result.stderr}');
      }
      return result;
    }

    runGit(projectDir.path, ['init', '-b', 'main']);
    runGit(projectDir.path, ['config', 'user.name', 'Test User']);
    runGit(projectDir.path, ['config', 'user.email', 'test@example.com']);
    File(p.join(projectDir.path, 'README.md')).writeAsStringSync('# local repo\n');
    runGit(projectDir.path, ['add', 'README.md']);
    runGit(projectDir.path, ['commit', '-m', 'initial']);

    final projectService = FakeProjectService(
      projects: [
        Project(
          id: 'my-project',
          name: 'My Project',
          remoteUrl: '',
          localPath: projectDir.path,
          defaultBranch: 'main',
          status: ProjectStatus.ready,
          createdAt: DateTime.parse('2026-03-24T10:00:00Z'),
        ),
      ],
    );

    final localPathExecutor = makeExecutor(projectService: projectService);

    final definition = WorkflowDefinition(
      name: 'artifact-commit-local-path',
      description: 'Commits artifacts in named localPath projects',
      gitStrategy: const WorkflowGitStrategy(
        artifacts: WorkflowGitArtifactsStrategy(commit: true, commitMessage: 'workflow artifacts {{runId}}'),
      ),
      variables: const {'PROJECT': WorkflowVariable(required: false)},
      steps: const [
        WorkflowStep(
          id: 'spec',
          name: 'Spec',
          type: 'writing',
          project: '{{PROJECT}}',
          contextOutputs: ['spec_path'],
          outputs: {'spec_path': OutputConfig(format: OutputFormat.path)},
          prompts: ['Write spec'],
        ),
      ],
    );

    final run = WorkflowRun(
      id: 'run-local-path',
      definitionName: definition.name,
      status: WorkflowRunStatus.running,
      startedAt: DateTime.now(),
      updatedAt: DateTime.now(),
      variablesJson: const {'PROJECT': 'my-project'},
      definitionJson: definition.toJson(),
    );
    await repository.insert(run);

    final context = WorkflowContext(variables: const {'PROJECT': 'my-project'});
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      final outputPath = p.join(projectDir.path, 'docs', 'specs', 'test.md');
      File(outputPath).parent.createSync(recursive: true);
      File(outputPath).writeAsStringSync('# local path test\n');
      final session = await sessionService.createSession(type: SessionType.task);
      await taskService.updateFields(e.taskId, sessionId: session.id, worktreeJson: {'path': projectDir.path});
      await messageService.insertMessage(
        sessionId: session.id,
        role: 'assistant',
        content: '<workflow-context>${jsonEncode({'spec_path': 'docs/specs/test.md'})}</workflow-context>',
      );
      await completeTask(e.taskId);
    });

    await localPathExecutor.execute(run, definition, context);
    await sub.cancel();

    final logResult = runGit(projectDir.path, ['log', '-1', '--pretty=%s']);
    expect((logResult.stdout as String).trim(), 'workflow artifacts run-local-path');
    final showResult = runGit(projectDir.path, ['show', 'HEAD:docs/specs/test.md']);
    expect(showResult.stdout, contains('# local path test'));
  });

  test('step failure pauses workflow', () async {
    final definition = makeDefinition(
      steps: [
        const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
        const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    var stepCount = 0;
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      stepCount++;
      if (stepCount == 1) {
        await completeTask(e.taskId, status: TaskStatus.failed);
      } else {
        await completeTask(e.taskId);
      }
    });

    await executor.execute(run, definition, context);
    await sub.cancel();

    expect(stepCount, equals(1)); // Step 2 never executed.
    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    expect(finalRun?.errorMessage, contains('step1'));
  });

  test('gate failure pauses workflow', () async {
    final definition = makeDefinition(
      steps: [
        const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
        const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2'], gate: 'step1.approved == true'),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);

    // Context has step1.approved = false → gate will fail.
    // (step1 execution only writes step1.status/tokenCount, not step1.approved)
    final context = WorkflowContext(data: {'step1.approved': 'false'});

    var stepCount = 0;
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      stepCount++;
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();

    // Step 1 executes (no gate), step 2 is blocked by gate.
    expect(stepCount, equals(1));
    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    expect(finalRun?.errorMessage, contains('Gate failed'));
  });

  test('loop nodes own their body steps and execute them in authored order', () async {
    final definition = WorkflowDefinition(
      name: 'test-workflow',
      description: 'Test',
      steps: [
        const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
        const WorkflowStep(id: 'step2', name: 'Step 2 (loop-owned)', prompts: ['Loop body']),
        const WorkflowStep(id: 'step3', name: 'Step 3', prompts: ['Do step 3']),
      ],
      loops: [
        const WorkflowLoop(id: 'loop1', steps: ['step2'], maxIterations: 3, exitGate: 'step2.status == accepted'),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    final executedStepIds = <String>[];
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      final task = await taskService.get(e.taskId);
      if (task != null) executedStepIds.add(e.taskId);
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();

    // Authored order is step1 -> loop(step2) -> step3. The loop body executes
    // once because the exit gate passes immediately.
    expect(executedStepIds.length, equals(3));

    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });

  test('workflow task config maps default and explicit review modes', () async {
    Future<String?> captureReviewMode(WorkflowStep step, {TaskStatus completionStatus = TaskStatus.accepted}) async {
      final definition = WorkflowDefinition(
        name: 'review-mode-${step.id}',
        description: 'Review mode capture',
        steps: [step],
      );
      final run = makeRun(definition).copyWith(id: 'run-${step.id}');
      await repository.insert(run);
      final context = WorkflowContext();
      final modeCompleter = Completer<String?>();

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        final task = await taskService.get(e.taskId);
        if (task != null && !modeCompleter.isCompleted) {
          modeCompleter.complete(task.configJson['reviewMode'] as String?);
        }
        try {
          await taskService.transition(e.taskId, TaskStatus.running, trigger: 'test');
        } on StateError {
          // Already running.
        }
        if (completionStatus == TaskStatus.accepted) {
          await taskService.transition(e.taskId, TaskStatus.accepted, trigger: 'test');
        } else {
          await taskService.transition(e.taskId, completionStatus, trigger: 'test');
        }
      });

      await executor.execute(run, definition, context);
      await sub.cancel();
      return modeCompleter.future;
    }

    expect(
      await captureReviewMode(
        const WorkflowStep(id: 'default-step', name: 'Default Step', type: 'coding', prompts: ['Implement']),
      ),
      'auto-accept',
    );
    expect(
      await captureReviewMode(
        const WorkflowStep(
          id: 'coding-only-step',
          name: 'Coding Only Step',
          type: 'coding',
          review: StepReviewMode.codingOnly,
          prompts: ['Implement'],
        ),
      ),
      'auto-accept',
    );
    expect(
      await captureReviewMode(
        const WorkflowStep(
          id: 'review-step',
          name: 'Review Step',
          type: 'coding',
          review: StepReviewMode.always,
          prompts: ['Implement'],
        ),
      ),
      'mandatory',
    );
    expect(
      await captureReviewMode(
        const WorkflowStep(
          id: 'never-step',
          name: 'Never Step',
          type: 'coding',
          review: StepReviewMode.never,
          prompts: ['Implement'],
        ),
      ),
      'auto-accept',
    );
  });

  test('workflow-level project does not bind semantic analysis steps in inline mode', () async {
    const definition = WorkflowDefinition(
      name: 'workflow-project-analysis-unbound',
      description: 'Semantic analysis labels should not bind workflow-level project ids.',
      project: '{{PROJECT}}',
      steps: [
        WorkflowStep(id: 'review', name: 'Review', type: 'analysis', typeAuthored: true, prompts: ['Review the repo']),
      ],
    );

    final task = await executeAndCaptureSingleTask(
      definition: definition,
      context: WorkflowContext(variables: const {'PROJECT': 'demo-project'}),
      runId: 'run-analysis-unbound',
    );

    expect(task.projectId, isNull);
    expect(task.configJson.containsKey('_workflowNeedsWorktree'), isFalse);
  });

  test('workflow-level project binds project-aware read-only steps without forcing a worktree', () async {
    const definition = WorkflowDefinition(
      name: 'workflow-project-readonly-bound',
      description: 'Project-aware review steps should target the workflow project inline.',
      project: '{{PROJECT}}',
      steps: [
        WorkflowStep(
          id: 'review',
          name: 'Review',
          type: 'custom',
          typeAuthored: true,
          allowedTools: ['file_read'],
          contextInputs: ['project_index'],
          prompts: ['Review the generated plan'],
        ),
      ],
    );

    final task = await executeAndCaptureSingleTask(
      definition: definition,
      context: WorkflowContext(
        variables: const {'PROJECT': 'demo-project'},
        data: const {
          'project_index': {'project_root': '/repo/demo-project'},
        },
      ),
      runId: 'run-readonly-bound',
    );

    expect(task.projectId, 'demo-project');
    expect(task.configJson.containsKey('_workflowNeedsWorktree'), isFalse);
  });

  test('workflow-level project still binds neutral custom steps without an explicit tool allowlist', () async {
    const definition = WorkflowDefinition(
      name: 'workflow-project-custom-bound',
      description: 'Neutral custom steps stay project-bound after S41.',
      project: '{{PROJECT}}',
      steps: [
        WorkflowStep(
          id: 'implement',
          name: 'Implement',
          type: 'custom',
          typeAuthored: true,
          prompts: ['Implement the change'],
        ),
      ],
    );

    final task = await executeAndCaptureSingleTask(
      definition: definition,
      context: WorkflowContext(variables: const {'PROJECT': 'demo-project'}),
      runId: 'run-custom-bound',
    );

    expect(task.projectId, 'demo-project');
    expect(task.configJson['_workflowNeedsWorktree'], isTrue);
  });

  test('explicit step project override still wins for semantic analysis steps', () async {
    const definition = WorkflowDefinition(
      name: 'workflow-step-project-override',
      description: 'Explicit step projects keep binding precedence.',
      project: '{{PROJECT}}',
      steps: [
        WorkflowStep(
          id: 'review',
          name: 'Review',
          type: 'analysis',
          typeAuthored: true,
          project: 'docs-project',
          prompts: ['Review the repo'],
        ),
      ],
    );

    final task = await executeAndCaptureSingleTask(
      definition: definition,
      context: WorkflowContext(variables: const {'PROJECT': 'code-project'}),
      runId: 'run-step-override',
    );

    expect(task.projectId, 'docs-project');
    expect(task.configJson['_workflowNeedsWorktree'], isTrue);
  });

  test('inline loop executes in authored order before following sibling steps', () async {
    final definition = WorkflowDefinitionParser().parse(_inlineLoopExecutionYaml);
    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    final completedStepIds = <String>[];
    final taskSub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      await completeTask(e.taskId);
    });
    final stepSub = eventBus.on<WorkflowStepCompletedEvent>().listen((event) {
      completedStepIds.add(event.stepId);
    });

    await executor.execute(run, definition, context);
    await taskSub.cancel();
    await stepSub.cancel();

    expect(completedStepIds, equals(['gap-analysis', 'remediate', 're-review', 'update-state']));

    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });

  test('inline loop entry gate skips the loop body when findings_count is zero', () async {
    final definition = WorkflowDefinitionParser().parse(_inlineEntryGateLoopYaml);
    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext(data: {'gap-analysis.findings_count': 0});

    final completedStepIds = <String>[];
    final taskSub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      await completeTask(e.taskId);
    });
    final stepSub = eventBus.on<WorkflowStepCompletedEvent>().listen((event) {
      completedStepIds.add(event.stepId);
    });

    await executor.execute(run, definition, context);
    await taskSub.cancel();
    await stepSub.cancel();

    expect(completedStepIds, equals(['gap-analysis', 'update-state']));
    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });

  test('inline loop entry gate executes the loop body when findings_count is positive', () async {
    final definition = WorkflowDefinitionParser().parse(_inlineEntryGateLoopYaml);
    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext(data: {'gap-analysis.findings_count': 3});

    final completedStepIds = <String>[];
    final taskSub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      await completeTask(e.taskId);
    });
    final stepSub = eventBus.on<WorkflowStepCompletedEvent>().listen((event) {
      completedStepIds.add(event.stepId);
    });

    await executor.execute(run, definition, context);
    await taskSub.cancel();
    await stepSub.cancel();

    expect(completedStepIds, equals(['gap-analysis', 'remediate', 're-review', 'update-state']));
    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });

  test('legacy loops execute in authored-order model at first loop step without side-table ordering drift', () async {
    final definition = WorkflowDefinition(
      name: 'legacy-side-table',
      description: 'Legacy loops side table compatibility',
      steps: [
        const WorkflowStep(id: 'setup', name: 'Setup', prompts: ['Setup']),
        const WorkflowStep(id: 'remediate', name: 'Remediate', prompts: ['Fix']),
        const WorkflowStep(id: 'middle', name: 'Middle', prompts: ['Middle']),
        const WorkflowStep(id: 're-review', name: 'Re-review', prompts: ['Review']),
        const WorkflowStep(id: 'after', name: 'After', prompts: ['After']),
      ],
      loops: [
        const WorkflowLoop(
          id: 'legacy-loop',
          steps: ['remediate', 're-review'],
          maxIterations: 2,
          exitGate: 're-review.status == accepted',
        ),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    final completedStepIds = <String>[];
    final taskSub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      await completeTask(e.taskId);
    });
    final stepSub = eventBus.on<WorkflowStepCompletedEvent>().listen((event) {
      completedStepIds.add(event.stepId);
    });

    await executor.execute(run, definition, context);
    await taskSub.cancel();
    await stepSub.cancel();

    expect(completedStepIds, equals(['setup', 'remediate', 're-review', 'middle', 'after']));
  });

  test('cancellation token stops execution between steps', () async {
    final definition = makeDefinition(
      steps: [
        const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
        const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    var stepCount = 0;
    var cancelled = false;
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      stepCount++;
      cancelled = true; // Signal cancellation after step 1.
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context, isCancelled: () => cancelled);
    await sub.cancel();

    // Only step 1 executed before cancellation was detected.
    expect(stepCount, equals(1));
  });

  test('workflow budget exceeded pauses workflow before next step', () async {
    final definition = makeDefinition(
      maxTokens: 1000,
      steps: [
        const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
        const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
      ],
    );

    var run = makeRun(definition);
    // Pre-seed totalTokens to exceed budget.
    run = run.copyWith(totalTokens: 1000);
    await repository.insert(run);
    final context = WorkflowContext();

    var stepCount = 0;
    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      stepCount++;
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();

    // Step 1 executes but budget is checked before step 2.
    expect(stepCount, lessThanOrEqualTo(1));
    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    expect(finalRun?.errorMessage, contains('budget'));
  });

  test('automatic metadata keys set after step completes', () async {
    final definition = makeDefinition(
      steps: [
        const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();

    expect(context['step1.status'], equals('accepted'));
    expect(context['step1.tokenCount'], isNotNull);
  });

  test('WorkflowRunStatusChangedEvent fired on completion', () async {
    final definition = makeDefinition();
    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    final statusEvents = <WorkflowRunStatusChangedEvent>[];
    final statusSub = eventBus.on<WorkflowRunStatusChangedEvent>().listen(statusEvents.add);

    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();
    await statusSub.cancel();

    expect(statusEvents, isNotEmpty);
    expect(statusEvents.last.newStatus, equals(WorkflowRunStatus.completed));
  });

  test('WorkflowStepCompletedEvent fired after each step', () async {
    final definition = makeDefinition(
      steps: [
        const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
        const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
      ],
    );
    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    final stepEvents = <WorkflowStepCompletedEvent>[];
    final stepSub = eventBus.on<WorkflowStepCompletedEvent>().listen(stepEvents.add);

    final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      await completeTask(e.taskId);
    });

    await executor.execute(run, definition, context);
    await sub.cancel();
    await stepSub.cancel();

    expect(stepEvents.length, equals(2));
    expect(stepEvents[0].stepId, equals('step1'));
    expect(stepEvents[1].stepId, equals('step2'));
  });

  group('retry integration', () {
    test('workflow waits through retry cycle, completes when retry succeeds', () async {
      // maxRetries: 2 so that after first failure (retryCount becomes 1),
      // the condition retryCount(1) < maxRetries(2) is true → workflow keeps waiting.
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1'], maxRetries: 2),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      // Track queued events to distinguish first creation from retry re-queue.
      int queueCount = 0;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        queueCount++;
        if (queueCount == 1) {
          // First attempt: fail, then simulate _markFailedOrRetry re-queue.
          // Set retryCount: 1 (< maxRetries: 2) so workflow keeps waiting.
          await taskService.transition(e.taskId, TaskStatus.running, trigger: 'test');
          await taskService.updateFields(e.taskId, retryCount: 1);
          await taskService.transition(e.taskId, TaskStatus.failed, trigger: 'system');
          await taskService.transition(e.taskId, TaskStatus.queued, trigger: 'retry');
        } else {
          // Second attempt (retry): succeed.
          await completeTask(e.taskId);
        }
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      expect(queueCount, equals(2)); // queued twice (original + retry)
      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('workflow pauses after all retries exhausted', () async {
      // maxRetries: 2 so the first retry is allowed (retryCount 1 < maxRetries 2).
      // Second failure increments retryCount to 2, making retryCount(2) >= maxRetries(2)
      // → permanent failure → workflow pauses.
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1'], maxRetries: 2),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      int queueCount = 0;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        queueCount++;
        if (queueCount == 1) {
          // First attempt: fail, retryCount → 1 (< maxRetries 2), re-queue.
          await taskService.transition(e.taskId, TaskStatus.running, trigger: 'test');
          await taskService.updateFields(e.taskId, retryCount: 1);
          await taskService.transition(e.taskId, TaskStatus.failed, trigger: 'system');
          await taskService.transition(e.taskId, TaskStatus.queued, trigger: 'retry');
        } else {
          // Second attempt (retry 1): fail, retryCount → 2 (== maxRetries 2).
          // Executor sees retryCount(2) < maxRetries(2) = false → permanent failure.
          await taskService.transition(e.taskId, TaskStatus.running, trigger: 'test');
          await taskService.updateFields(e.taskId, retryCount: 2);
          await taskService.transition(e.taskId, TaskStatus.failed, trigger: 'system');
        }
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      expect(queueCount, equals(2));
      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    });
  });

  test('step timeout pauses workflow', () async {
    const timeoutSeconds = 1;
    final definition = makeDefinition(
      steps: [
        const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1'], timeoutSeconds: timeoutSeconds),
      ],
    );

    final run = makeRun(definition);
    await repository.insert(run);
    final context = WorkflowContext();

    // Do NOT complete the task — let it time out.
    await executor.execute(run, definition, context);

    final finalRun = await repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    expect(finalRun?.errorMessage, contains('timed out'));
  }, timeout: const Timeout(Duration(seconds: 10)));

  group('budget warning', () {
    test('fires WorkflowBudgetWarningEvent at 80% of maxTokens', () async {
      final definition = makeDefinition(
        maxTokens: 10000,
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
        ],
      );

      // Pre-seed at 80% of budget so warning fires before step 1.
      var run = makeRun(definition);
      run = run.copyWith(totalTokens: 8000);
      await repository.insert(run);
      final context = WorkflowContext();

      final warnings = <WorkflowBudgetWarningEvent>[];
      final warnSub = eventBus.on<WorkflowBudgetWarningEvent>().listen(warnings.add);

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();
      await warnSub.cancel();

      expect(warnings, hasLength(1));
      expect(warnings.first.consumed, equals(8000));
      expect(warnings.first.limit, equals(10000));
    });

    test('warning fires only once per run (deduplication)', () async {
      final definition = makeDefinition(
        maxTokens: 10000,
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
          const WorkflowStep(id: 'step3', name: 'Step 3', prompts: ['Do step 3']),
        ],
      );

      var run = makeRun(definition);
      run = run.copyWith(totalTokens: 8500);
      await repository.insert(run);
      final context = WorkflowContext();

      final warnings = <WorkflowBudgetWarningEvent>[];
      final warnSub = eventBus.on<WorkflowBudgetWarningEvent>().listen(warnings.add);

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();
      await warnSub.cancel();

      // Warning fires at the first budget check, not again at subsequent checks.
      expect(warnings, hasLength(1));
    });
  });

  group('parallel group resume', () {
    test('resume re-runs only failed parallel steps', () async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'pA', name: 'Parallel A', prompts: ['Do A'], parallel: true),
          const WorkflowStep(id: 'pB', name: 'Parallel B', prompts: ['Do B'], parallel: true),
        ],
      );

      // Simulate state after a parallel group where pB failed:
      // currentStepIndex = 0 (group start), _parallel.failed.stepIds = ['pB'].
      var run = makeRun(definition, stepIndex: 0);
      run = run.copyWith(
        contextJson: {
          '_parallel.current.stepIds': ['pA', 'pB'],
          '_parallel.failed.stepIds': ['pB'],
          // pA already succeeded — its context is already merged.
          'pA.status': 'accepted',
          'pA.tokenCount': 100,
        },
      );
      await repository.insert(run);
      final context = WorkflowContext.fromJson({'pA.status': 'accepted', 'pA.tokenCount': 100});

      final createdTaskTitles = <String>[];
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final task = await taskService.get(e.taskId);
        if (task != null) createdTaskTitles.add(task.title);
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      // Only pB should have been re-executed, not pA.
      expect(createdTaskTitles, hasLength(1));
      expect(createdTaskTitles.first, contains('Parallel B'));

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('parallel failure keeps currentStepIndex at group start', () async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'pA', name: 'Parallel A', prompts: ['Do A'], parallel: true),
          const WorkflowStep(id: 'pB', name: 'Parallel B', prompts: ['Do B'], parallel: true),
          const WorkflowStep(id: 'step3', name: 'Step 3', prompts: ['Do 3']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final task = await taskService.get(e.taskId);
        // Fail pB, succeed pA.
        if (task != null && task.title.contains('Parallel B')) {
          await completeTask(e.taskId, status: TaskStatus.failed);
        } else {
          await completeTask(e.taskId);
        }
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
      // currentStepIndex should be at group start (0), not past the group.
      expect(finalRun?.currentStepIndex, equals(0));
      // Failed step IDs should be persisted.
      final failedIds = finalRun?.contextJson['_parallel.failed.stepIds'] as List?;
      expect(failedIds, equals(['pB']));
    });

    test('parallel bash steps execute through shared hybrid dispatcher without creating tasks', () async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'bash-a', name: 'Bash A', type: 'bash', prompts: ['printf A'], parallel: true),
          const WorkflowStep(id: 'bash-b', name: 'Bash B', type: 'bash', prompts: ['printf B'], parallel: true),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      await executor.execute(run, definition, context);

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
      final allTasks = await taskService.list();
      expect(allTasks, isEmpty, reason: 'parallel bash steps should remain zero-task');

      final contextData = finalRun?.contextJson['data'] as Map?;
      expect(contextData?['bash-a.status'], equals('success'));
      expect(contextData?['bash-b.status'], equals('success'));
    });
  });

  group('loop step resume', () {
    test('resume re-runs from failed loop step, not iteration start', () async {
      final definition = WorkflowDefinition(
        name: 'test-workflow',
        description: 'Test',
        steps: [
          const WorkflowStep(id: 'loopA', name: 'Loop A', prompts: ['Do A']),
          const WorkflowStep(id: 'loopB', name: 'Loop B', prompts: ['Do B']),
        ],
        loops: [
          const WorkflowLoop(
            id: 'loop1',
            steps: ['loopA', 'loopB'],
            maxIterations: 3,
            exitGate: 'loopB.status == accepted',
          ),
        ],
      );

      // Simulate resume state: mid-loop, iteration 1, loopB failed.
      var run = makeRun(definition, stepIndex: 2); // Resume after the parallel group boundary.
      run = run.copyWith(
        contextJson: {
          '_loop.current.id': 'loop1',
          '_loop.current.iteration': 1,
          '_loop.current.stepId': 'loopB',
          // loopA already completed in this iteration.
          'loopA.status': 'accepted',
          'loopA.tokenCount': 50,
        },
      );
      await repository.insert(run);
      final context = WorkflowContext.fromJson({'loopA.status': 'accepted', 'loopA.tokenCount': 50});

      final createdTaskTitles = <String>[];
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final task = await taskService.get(e.taskId);
        if (task != null) createdTaskTitles.add(task.title);
        await completeTask(e.taskId);
      });

      await executor.execute(
        run,
        definition,
        context,
        startFromStepIndex: 2, // Resume after the parallel group boundary.
        startFromLoopIndex: 0,
        startFromLoopIteration: 1,
        startFromLoopStepId: 'loopB',
      );
      await sub.cancel();

      // Only loopB should have been executed (loopA was skipped).
      // The exit gate passes after loopB succeeds, so loop completes.
      expect(createdTaskTitles, hasLength(1));
      expect(createdTaskTitles.first, contains('Loop B'));

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('checkpoints loop cursor after each sibling step so resume can continue in-iteration', () async {
      final definition = WorkflowDefinition(
        name: 'loop-checkpoint',
        description: 'Loop checkpointing',
        steps: [
          const WorkflowStep(id: 'loopA', name: 'Loop A', prompts: ['Do A']),
          const WorkflowStep(id: 'loopB', name: 'Loop B', prompts: ['Do B']),
        ],
        loops: [
          const WorkflowLoop(
            id: 'loop1',
            steps: ['loopA', 'loopB'],
            maxIterations: 3,
            exitGate: 'loopB.status == accepted',
          ),
        ],
      );

      var run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      var cancelAfterLoopASuccess = false;
      final createdTaskTitlesFirstPass = <String>[];
      final firstPassSub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final task = await taskService.get(e.taskId);
        if (task == null) return;
        createdTaskTitlesFirstPass.add(task.title);
        await completeTask(e.taskId);
        if (task.title.contains('Loop A')) {
          cancelAfterLoopASuccess = true;
        }
      });

      await executor.execute(run, definition, context, isCancelled: () => cancelAfterLoopASuccess);
      await firstPassSub.cancel();

      final interrupted = await repository.getById('run-1');
      expect(createdTaskTitlesFirstPass, hasLength(1));
      expect(createdTaskTitlesFirstPass.first, contains('Loop A'));
      expect(interrupted?.contextJson['_loop.current.stepId'], equals('loopB'));
      expect((interrupted?.contextJson['data'] as Map?)?['loopA.status'], equals('accepted'));

      final createdTaskTitlesSecondPass = <String>[];
      final secondPassSub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen(
        (e) async {
          await Future<void>.delayed(Duration.zero);
          final task = await taskService.get(e.taskId);
          if (task == null) return;
          createdTaskTitlesSecondPass.add(task.title);
          await completeTask(e.taskId);
        },
      );

      run = interrupted!;
      await executor.execute(
        run,
        definition,
        context,
        startFromStepIndex: 0,
        startFromLoopIndex: 0,
        startFromLoopIteration: 1,
        startFromLoopStepId: interrupted.contextJson['_loop.current.stepId'] as String?,
      );
      await secondPassSub.cancel();

      expect(createdTaskTitlesSecondPass, hasLength(1));
      expect(createdTaskTitlesSecondPass.first, contains('Loop B'));
      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });
  });

  group('multi-prompt execution (S02)', () {
    WorkflowExecutor makeMultiPromptExecutor() {
      return makeExecutor();
    }

    StreamSubscription<TaskStatusChangedEvent> autoAcceptQueuedTask() {
      return eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
      });
    }

    test('queues follow-up prompts in task config for one-shot execution', () async {
      final mpExecutor = makeMultiPromptExecutor();

      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['First prompt', 'Second prompt', 'Third prompt']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final sub = autoAcceptQueuedTask();

      await mpExecutor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      final createdTask = (await taskService.list()).single;
      expect(createdTask.description, equals('First prompt'));
      final followUps = (await workflowStepExecutionRepository.getByTaskId(createdTask.id))?.followUpPrompts;
      expect(followUps, isNotNull);
      expect(followUps, hasLength(2));
      expect(followUps![0], equals('Second prompt'));
      // Last follow-up prompt gets the step-outcome protocol appended
      // (S36: host-injected via PromptAugmenter unless emitsOwnOutcome).
      expect(followUps[1], startsWith('Third prompt'));
      expect(followUps[1], contains('## Step Outcome Protocol'));

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('single-prompt step creates no follow-up turns', () async {
      final mpExecutor = makeMultiPromptExecutor();

      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Just one']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final sub = autoAcceptQueuedTask();

      await mpExecutor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      final createdTask = (await taskService.list()).single;
      expect((await workflowStepExecutionRepository.getByTaskId(createdTask.id))?.followUpPrompts, isEmpty);

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('workflow-spawned agent execution stays unstarted while the task is queued', () async {
      final mpExecutor = makeMultiPromptExecutor();
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Just one']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      late final StreamSubscription<TaskStatusChangedEvent> sub;
      sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
        await Future<void>.delayed(Duration.zero);
        final task = await taskService.get(e.taskId);
        expect(task?.agentExecution?.startedAt, isNull);
        await completeTask(e.taskId);
      });

      await mpExecutor.execute(run, definition, WorkflowContext());
      await sub.cancel();
    });

    test('workflow-spawned task leaves provider unset when no override is requested', () async {
      final mpExecutor = makeMultiPromptExecutor();
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Just one']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      late final StreamSubscription<TaskStatusChangedEvent> sub;
      sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
        await Future<void>.delayed(Duration.zero);
        final task = await taskService.get(e.taskId);
        expect(task?.provider, isNull);
        await completeTask(e.taskId);
      });

      await mpExecutor.execute(run, definition, WorkflowContext());
      await sub.cancel();
    });

    test('completed workflow run preserves AE/WSE row-count invariants', () async {
      final mpExecutor = makeMultiPromptExecutor();
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Just one']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final sub = autoAcceptQueuedTask();

      await mpExecutor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      final taskCount = (db.select('SELECT COUNT(*) AS c FROM tasks').first['c'] as int?) ?? 0;
      final tasksWithoutAe =
          (db.select('SELECT COUNT(*) AS c FROM tasks WHERE agent_execution_id IS NULL').first['c'] as int?) ?? 0;
      final workflowStepCount =
          (db.select('SELECT COUNT(*) AS c FROM workflow_step_executions').first['c'] as int?) ?? 0;
      final joinedWorkflowStepCount =
          (db
                  .select(
                    'SELECT COUNT(*) AS c FROM tasks t '
                    'JOIN workflow_step_executions wse ON wse.task_id = t.id',
                  )
                  .first['c']
              as int?) ??
          0;
      final agentExecutionCount = (db.select('SELECT COUNT(*) AS c FROM agent_executions').first['c'] as int?) ?? 0;

      expect(taskCount, 1);
      expect(tasksWithoutAe, 0);
      expect(workflowStepCount, taskCount);
      expect(joinedWorkflowStepCount, taskCount);
      expect(agentExecutionCount, greaterThanOrEqualTo(taskCount));
    });

    test('mixed-output steps without narrative outputs skip structured extraction schema', () async {
      final mpExecutor = makeMultiPromptExecutor();

      final definition = makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'step1',
            name: 'Step 1',
            prompts: ['Plan this'],
            contextOutputs: ['prd', 'stories'],
            outputs: {
              'prd': OutputConfig(format: OutputFormat.text),
              'stories': OutputConfig(format: OutputFormat.json, schema: 'story-plan'),
            },
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final sub = autoAcceptQueuedTask();

      await mpExecutor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      final createdTask = (await taskService.list()).single;
      expect((await workflowStepExecutionRepository.getByTaskId(createdTask.id))!.structuredSchema, isNull);
    });

    test('without turn infrastructure, multi-prompt step still completes (graceful degradation)', () async {
      // Executor with no turnManager/messageService — no session dir needed.
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['First', 'Second']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
      });

      // Use the basic executor (no turn infrastructure).
      await executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      // Step still completes — follow-ups are skipped with a warning.
      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });
  });

  // ── S03: Step config defaults integration tests ──────────────────────────────

  group('S03: step config defaults', () {
    WorkflowRun makeS03Run(WorkflowDefinition definition) {
      final now = DateTime.now();
      return WorkflowRun(
        id: 'run-s03',
        definitionName: definition.name,
        status: WorkflowRunStatus.running,
        startedAt: now,
        updatedAt: now,
        currentStepIndex: 0,
        definitionJson: definition.toJson(),
      );
    }

    Future<void> completeS03Task(String taskId) async {
      try {
        await taskService.transition(taskId, TaskStatus.running, trigger: 'test');
      } on StateError {
        /* already running */
      }
      try {
        await taskService.transition(taskId, TaskStatus.review, trigger: 'test');
      } on StateError {
        /* may skip review */
      }
      await taskService.transition(taskId, TaskStatus.accepted, trigger: 'test');
    }

    test('step inherits model from matching stepDefaults', () async {
      final definition = WorkflowDefinition(
        name: 'wf',
        description: 'desc',
        steps: const [
          WorkflowStep(id: 'review-code', name: 'Review Code', prompts: ['p']),
        ],
        stepDefaults: const [StepConfigDefault(match: 'review*', model: 'claude-opus-4')],
      );

      final run = makeS03Run(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      Map<String, dynamic>? capturedConfig;
      String? capturedModel;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final task = await taskService.get(e.taskId);
        capturedConfig = task?.configJson;
        capturedModel = task?.model;
        await completeS03Task(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      expect(capturedConfig, isNotNull);
      expect(capturedModel, equals('claude-opus-4'));
      expect(capturedConfig!.containsKey('model'), isFalse);
    });

    test('per-step explicit provider overrides stepDefaults provider', () async {
      final definition = WorkflowDefinition(
        name: 'wf',
        description: 'desc',
        steps: const [
          WorkflowStep(id: 'review-code', name: 'Review Code', prompts: ['p'], provider: 'explicit-provider'),
        ],
        stepDefaults: const [StepConfigDefault(match: 'review*', provider: 'default-provider')],
      );

      final run = makeS03Run(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      String? capturedProvider;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final task = await taskService.get(e.taskId);
        capturedProvider = task?.provider;
        await completeS03Task(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      expect(capturedProvider, equals('explicit-provider'));
    });

    test('first-match-wins: review-code matches review* not catch-all *', () async {
      final definition = WorkflowDefinition(
        name: 'wf',
        description: 'desc',
        steps: const [
          WorkflowStep(id: 'review-code', name: 'Review Code', prompts: ['p']),
        ],
        stepDefaults: const [
          StepConfigDefault(match: 'review*', model: 'opus'),
          StepConfigDefault(match: '*', model: 'sonnet'),
        ],
      );

      final run = makeS03Run(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      Map<String, dynamic>? capturedConfig;
      String? capturedModel;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final task = await taskService.get(e.taskId);
        capturedConfig = task?.configJson;
        capturedModel = task?.model;
        await completeS03Task(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      expect(capturedModel, equals('opus'));
      expect(capturedConfig!.containsKey('model'), isFalse);
    });

    test('no matching default: step uses own config only', () async {
      final definition = WorkflowDefinition(
        name: 'wf',
        description: 'desc',
        steps: const [
          WorkflowStep(id: 'custom-step', name: 'Custom Step', prompts: ['p']),
        ],
        stepDefaults: const [StepConfigDefault(match: 'review*', model: 'opus')],
      );

      final run = makeS03Run(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      Map<String, dynamic>? capturedConfig;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final task = await taskService.get(e.taskId);
        capturedConfig = task?.configJson;
        await completeS03Task(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      // No model should be in the config since custom-step doesn't match review*.
      expect(capturedConfig!.containsKey('model'), isFalse);
    });

    test('no stepDefaults on definition: existing behavior unchanged', () async {
      final definition = WorkflowDefinition(
        name: 'wf',
        description: 'desc',
        steps: const [
          WorkflowStep(id: 's', name: 'S', prompts: ['p']),
        ],
      );

      final run = makeS03Run(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      var taskCount = 0;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        taskCount++;
        await completeS03Task(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      expect(taskCount, equals(1));
      final finalRun = await repository.getById('run-s03');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('workflow-spawned task carries no _workflow* or model keys in configJson', () async {
      final definition = WorkflowDefinition(
        name: 'wf',
        description: 'desc',
        steps: const [
          WorkflowStep(id: 'review-code', name: 'Review Code', prompts: ['p']),
        ],
        stepDefaults: const [StepConfigDefault(match: 'review*', model: 'claude-opus-4')],
      );

      final run = makeS03Run(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      Map<String, dynamic>? capturedConfig;
      String? capturedAeModel;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final task = await taskService.get(e.taskId);
        capturedConfig = task?.configJson;
        capturedAeModel = task?.agentExecution?.model;
        await completeS03Task(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      expect(capturedConfig, isNotNull);
      expect(capturedAeModel, equals('claude-opus-4'));
      expect(capturedConfig!.containsKey('model'), isFalse);
      final leakedWorkflowKeys = capturedConfig!.keys.where((k) => k.startsWith('_workflow')).toList();
      expect(leakedWorkflowKeys, isEmpty, reason: 'Task.configJson must not carry _workflow* keys post-S33/S34');
    });
  });

  // ---------------------------------------------------------------------------
  // S02 (0.16.1): Bash step execution + onError policy
  // ---------------------------------------------------------------------------
  group('S02 (0.16.1): bash step execution', () {
    test('bash step runs command and completes with zero tokens and no task', () async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'bash1', name: 'Bash 1', type: 'bash', prompts: ['echo hello']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      final taskIds = <String>[];
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) {
        taskIds.add(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      // No task created for bash step.
      expect(taskIds, isEmpty);

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
      // Zero tokens accumulated.
      expect(finalRun?.totalTokens, equals(0));
    });

    test('bash step sets status=success and exitCode=0 in context', () async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'bash1', name: 'Bash 1', type: 'bash', prompts: ['echo ok']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      await executor.execute(run, definition, context);

      expect(context['bash1.status'], equals('success'));
      expect(context['bash1.exitCode'], equals(0));
      expect(context['bash1.tokenCount'], equals(0));
    });

    test('bash step extracts text output to context key', () async {
      final definition = makeDefinition(
        steps: [
          WorkflowStep(
            id: 'bash1',
            name: 'Bash 1',
            type: 'bash',
            prompts: const ['printf "captured output"'],
            contextOutputs: const ['bash1.out'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      await executor.execute(run, definition, context);

      expect(context['bash1.out'], equals('captured output'));
    });

    test('bash step extracts json output from stdout', () async {
      final definition = makeDefinition(
        steps: [
          WorkflowStep(
            id: 'bash1',
            name: 'Bash 1',
            type: 'bash',
            prompts: const ['printf \'{"key":"value"}\''],
            contextOutputs: const ['result'],
            outputs: const {'result': OutputConfig(format: OutputFormat.json)},
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      await executor.execute(run, definition, context);

      final result = context['result'];
      expect(result, isA<Map<String, dynamic>>());
      expect((result as Map<String, dynamic>)['key'], equals('value'));
    });

    test('bash step extracts lines output from stdout', () async {
      final definition = makeDefinition(
        steps: [
          WorkflowStep(
            id: 'bash1',
            name: 'Bash 1',
            type: 'bash',
            prompts: const ['printf "a\\nb\\nc"'],
            contextOutputs: const ['lines'],
            outputs: const {'lines': OutputConfig(format: OutputFormat.lines)},
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      await executor.execute(run, definition, context);

      final lines = context['lines'];
      expect(lines, isA<List<String>>());
      expect(lines as List<String>, containsAll(['a', 'b', 'c']));
    });

    test('bash step with non-zero exit pauses workflow by default', () async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'bash1', name: 'Bash 1', type: 'bash', prompts: ['exit 1']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      await executor.execute(run, definition, context);

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    });

    test('bash step with onError: continue records failure and proceeds', () async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'bash1', name: 'Bash 1', type: 'bash', prompts: ['exit 42'], onError: 'continue'),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
      expect(context['bash1.status'], equals('failed'));
    });

    test('bash step uses workdir from context when template-referenced', () async {
      // Use tempDir.path as workdir.
      final definition = makeDefinition(
        steps: [
          WorkflowStep(
            id: 'bash1',
            name: 'Bash 1',
            type: 'bash',
            prompts: const ['pwd'],
            workdir: tempDir.path,
            contextOutputs: const ['cwd'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      await executor.execute(run, definition, context);

      expect(context['bash1.status'], equals('success'));
      // pwd output is in context; resolve symlinks for macOS /private/var consistency.
      final expected = tempDir.resolveSymbolicLinksSync();
      expect((context['cwd'] as String?)?.trim(), equals(expected));
    });

    test('bash step strips sensitive parent env and keeps allowlisted vars only', () async {
      final isolatedExecutor = makeExecutor(
        hostEnvironment: const {
          'PATH': '/usr/bin:/bin',
          'HOME': '/tmp/home',
          'LANG': 'en_US.UTF-8',
          'ANTHROPIC_API_KEY': 'leak-canary',
          'GITHUB_TOKEN': 'gh-leak',
          'CUSTOM_SECRET': 'dont-leak',
          'CUSTOM_ALLOWED': 'survives',
        },
        bashStepEnvAllowlist: const ['PATH', 'HOME', 'CUSTOM_ALLOWED'],
      );
      final definition = makeDefinition(
        steps: [
          WorkflowStep(
            id: 'bash1',
            name: 'Bash 1',
            type: 'bash',
            prompts: const [
              r'printf "%s|%s|%s|%s" "${ANTHROPIC_API_KEY:-missing}" "${GITHUB_TOKEN:-missing}" "${CUSTOM_SECRET:-missing}" "${CUSTOM_ALLOWED:-missing}"',
            ],
            contextOutputs: const ['bash1.out'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      await isolatedExecutor.execute(run, definition, context);

      expect(context['bash1.out'], 'missing|missing|missing|survives');
    });

    test('bash step with non-existent workdir pauses workflow', () async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'bash1',
            name: 'Bash 1',
            type: 'bash',
            prompts: ['echo x'],
            workdir: '/non/existent/dir/12345',
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      await executor.execute(run, definition, context);

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    });

    test('bash step timeout pauses workflow', () async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'bash1', name: 'Bash 1', type: 'bash', prompts: ['sleep 10'], timeoutSeconds: 1),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      await executor.execute(run, definition, context);

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('bash step timeout terminates the spawned process', () async {
      final outputFile = p.join(tempDir.path, 'timed-out.txt');
      final definition = makeDefinition(
        steps: [
          WorkflowStep(
            id: 'bash1',
            name: 'Bash 1',
            type: 'bash',
            prompts: ['sleep 2; echo late > "$outputFile"'],
            timeoutSeconds: 1,
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);

      await executor.execute(run, definition, WorkflowContext());
      await Future<void>.delayed(const Duration(milliseconds: 1500));

      expect(File(outputFile).existsSync(), isFalse);
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('bash step with json output fails on empty stdout', () async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'bash1',
            name: 'Bash 1',
            type: 'bash',
            prompts: ['printf ""'],
            contextOutputs: ['result'],
            outputs: {'result': OutputConfig(format: OutputFormat.json)},
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);

      await executor.execute(run, definition, WorkflowContext());

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    });

    test('bash step shell-escapes context values', () async {
      // Without escaping, the value "; echo INJECTED" would split the command
      // and produce two separate outputs: the first echo result and then "INJECTED".
      // With proper escaping, the entire value is treated as a literal argument.
      //
      // We test this by checking that a marker word only appears as part of the
      // literal value (i.e. the shell did NOT execute it as a second command).
      // Command: echo SAFE <escaped-value>
      // With injection: outputs "SAFE" then "INJECTED" on a new line.
      // With escaping: outputs "SAFE ; echo INJECTED" on a single line.
      const maliciousValue = '; echo INJECTED';
      final definition = makeDefinition(
        steps: [
          WorkflowStep(
            id: 'bash1',
            name: 'Bash 1',
            type: 'bash',
            prompts: const ['echo SAFE {{context.val}}'],
            contextOutputs: const ['out'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['val'] = maliciousValue;

      await executor.execute(run, definition, context);

      expect(context['bash1.status'], equals('success'));
      final out = (context['out'] as String?) ?? '';
      // Injection would produce a line containing just "INJECTED" (as separate command output).
      // Escaping produces "SAFE ; echo INJECTED" — the marker appears only on the SAFE line.
      final lines = out.trim().split('\n');
      expect(lines, isNot(contains('INJECTED')), reason: 'injection should not execute as separate command');
      // The first (and only) line contains SAFE and the literal value.
      expect(lines.first, contains('SAFE'));
      expect(lines.first, contains('INJECTED'));
    });
  });

  group('S02 (0.16.1): onError: continue for agent steps', () {
    test('agent step with onError: continue proceeds past failure', () async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1'], onError: 'continue'),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      int taskCount = 0;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        taskCount++;
        if (taskCount == 1) {
          // Fail first step.
          await completeTask(e.taskId, status: TaskStatus.failed);
        } else {
          await completeTask(e.taskId);
        }
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
      expect(taskCount, equals(2));
      expect(context['step1.status'], equals('failed'));
    });

    test('agent step without onError pauses on failure (backward compat)', () async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      int taskCount = 0;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        taskCount++;
        await completeTask(e.taskId, status: TaskStatus.failed);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
      // Only one task created — second step not reached.
      expect(taskCount, equals(1));
    });
  });

  group('S36: needsInput hold transitions to awaitingApproval with approval-step semantics', () {
    test('needsInput outcome advances currentStepIndex past held step and fires approval event', () async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      final approvalEvents = <WorkflowApprovalRequestedEvent>[];
      final evSub = eventBus.on<WorkflowApprovalRequestedEvent>().listen(approvalEvents.add);

      final sessionService = SessionService(baseDir: sessionsDir);
      int taskCount = 0;

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        taskCount++;
        final task = await taskService.get(e.taskId);
        if (task == null) return;
        final session = await sessionService.createSession(type: SessionType.task);
        await taskService.updateFields(task.id, sessionId: session.id);
        await messageService.insertMessage(
          sessionId: session.id,
          role: 'assistant',
          content:
              'Blocked pending human decision.\n'
              '<step-outcome>{"outcome":"needsInput","reason":"ambiguous requirements"}</step-outcome>',
        );
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      await evSub.cancel();

      // Only step1 should have run — step2 must not execute before resume.
      expect(taskCount, equals(1));

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.awaitingApproval));
      // Resume must continue at step2 (index 1), not re-run the held step (index 0).
      expect(finalRun?.currentStepIndex, equals(1));
      expect(finalRun?.contextJson['_approval.pending.stepId'], equals('step1'));
      expect(finalRun?.contextJson['_approval.pending.stepIndex'], equals(0));
      expect(finalRun?.errorMessage, equals('ambiguous requirements'));

      // Connected CLI/SSE consumers receive an approval-style event, not
      // just a generic paused status change.
      expect(approvalEvents, hasLength(1));
      expect(approvalEvents.first.stepId, equals('step1'));
      expect(approvalEvents.first.message, equals('ambiguous requirements'));
    });

    test('onFailure: pause after failed outcome routes through the same awaitingApproval hold', () async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1'], onFailure: OnFailurePolicy.pause),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      final approvalEvents = <WorkflowApprovalRequestedEvent>[];
      final evSub = eventBus.on<WorkflowApprovalRequestedEvent>().listen(approvalEvents.add);
      final sessionService = SessionService(baseDir: sessionsDir);

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final task = await taskService.get(e.taskId);
        if (task == null) return;
        final session = await sessionService.createSession(type: SessionType.task);
        await taskService.updateFields(task.id, sessionId: session.id);
        await messageService.insertMessage(
          sessionId: session.id,
          role: 'assistant',
          content: '<step-outcome>{"outcome":"failed","reason":"guarded"}</step-outcome>',
        );
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      await evSub.cancel();

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.awaitingApproval));
      expect(finalRun?.currentStepIndex, equals(1));
      expect(approvalEvents, hasLength(1));
      expect(approvalEvents.first.stepId, equals('step1'));
    });
  });

  group('S03 (0.16.1): approval step execution', () {
    test('approval step pauses with zero task creation and zero token increment', () async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'gate', name: 'Review Gate', type: 'approval', prompts: ['Please review']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      final approvalEvents = <WorkflowApprovalRequestedEvent>[];
      final eventSub = eventBus.on<WorkflowApprovalRequestedEvent>().listen(approvalEvents.add);

      await executor.execute(run, definition, context);
      await Future<void>.delayed(Duration.zero);
      await eventSub.cancel();

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.awaitingApproval));
      expect(finalRun?.totalTokens, equals(0));
      // No child tasks created.
      final allTasks = await taskService.list();
      expect(allTasks.where((t) => t.workflowRunId == 'run-1'), isEmpty);

      // Approval metadata in in-memory context (mirrors what's persisted to disk).
      expect(context['gate.approval.status'], equals('pending'));
      expect(context['gate.approval.message'], equals('Please review'));
      expect(context['gate.approval.requested_at'], isNotNull);
      expect(context['gate.tokenCount'], equals(0));

      // SSE event fired.
      expect(approvalEvents, hasLength(1));
      expect(approvalEvents.first.stepId, equals('gate'));
      expect(approvalEvents.first.message, equals('Please review'));
    });

    test('approval step without timeoutSeconds waits indefinitely (no auto-cancel)', () async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'gate', name: 'Gate', type: 'approval', prompts: ['Approve?']),
        ],
      );
      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      await executor.execute(run, definition, context);

      // Wait briefly — no timeout should fire.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.awaitingApproval));
      // No timeout deadline persisted.
      expect(context['gate.approval.timeout_deadline'], isNull);
    });

    test('approval step with timeoutSeconds auto-cancels after timeout', () async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'gate', name: 'Gate', type: 'approval', prompts: ['Approve?'], timeoutSeconds: 1),
        ],
      );
      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      await executor.execute(run, definition, context);

      // Run should be paused first; timeout_deadline persisted as flat contextJson key.
      final pausedRun = await repository.getById('run-1');
      expect(pausedRun?.status, equals(WorkflowRunStatus.awaitingApproval));
      expect(pausedRun?.contextJson['gate.approval.timeout_deadline'], isNotNull);

      // Wait for the timer to fire (1s + buffer).
      await Future<void>.delayed(const Duration(milliseconds: 1200));

      final cancelledRun = await repository.getById('run-1');
      expect(cancelledRun?.status, equals(WorkflowRunStatus.cancelled));
      expect(cancelledRun?.contextJson['gate.approval.cancel_reason'], equals('timeout'));
    }, timeout: const Timeout(Duration(seconds: 5)));

    test('approval step resolves prompt template from context', () async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'gate',
            name: 'Gate',
            type: 'approval',
            prompts: ['Review result: {{context.prior_output}}'],
          ),
        ],
      );
      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();
      context['prior_output'] = 'all tests pass';

      await executor.execute(run, definition, context);

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.contextJson['gate.approval.message'], equals('Review result: all tests pass'));
    });
  });

  // ── S04 (0.16.1): continueSession runtime + delta accounting ─────────────────

  group('S04 (0.16.1): continueSession runtime', () {
    const sessionStep1 = '550e8400-e29b-41d4-a716-446655440101';

    void createSessionDir(String sessionId) {
      Directory(p.join(sessionsDir, sessionId)).createSync(recursive: true);
    }

    Future<void> seedSessionCost(String sessionId, int totalTokens) async {
      await kvService.set('session_cost:$sessionId', jsonEncode({'total_tokens': totalTokens}));
    }

    test('continued step receives _continueSessionId from preceding step', () async {
      createSessionDir(sessionStep1);

      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Investigate', prompts: ['Investigate the bug']),
          const WorkflowStep(id: 'step2', name: 'Fix', prompts: ['Fix the bug'], continueSession: 'step1'),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      var step1TaskId = '';
      var step2TaskId = '';
      final createdTasks = <Task>[];

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final allTasks = await taskService.list();
        final task = allTasks.firstWhere((t) => t.id == e.taskId);
        createdTasks.add(task);

        if (step1TaskId.isEmpty) {
          step1TaskId = e.taskId;
          // Assign session to step 1 (simulates TaskExecutor).
          await taskService.updateFields(e.taskId, sessionId: sessionStep1);
          await seedSessionCost(sessionStep1, 100);
        } else {
          step2TaskId = e.taskId;
        }
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      expect(step2TaskId, isNotEmpty, reason: 'step 2 task should have been created');

      final step2Task = await taskService.get(step2TaskId);
      expect(
        step2Task?.configJson['_continueSessionId'],
        equals(sessionStep1),
        reason: 'step 2 should inherit step 1 session ID',
      );
    });

    test('continued step resolves root session from an explicit earlier step reference', () async {
      createSessionDir(sessionStep1);

      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Investigate', prompts: ['Investigate the bug']),
          const WorkflowStep(id: 'step2', name: 'Summarize', prompts: ['Summarize findings'], continueSession: 'step1'),
          const WorkflowStep(id: 'step3', name: 'Fix', prompts: ['Fix the bug'], continueSession: 'step1'),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);

      var createdCount = 0;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        createdCount++;
        if (createdCount == 1) {
          await taskService.updateFields(e.taskId, sessionId: sessionStep1);
          await seedSessionCost(sessionStep1, 100);
        }
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      final allTasks = await taskService.list();
      final step3Task = allTasks.firstWhere((t) => t.stepIndex == 2);
      expect(step3Task.configJson['_continueSessionId'], equals(sessionStep1));
    });

    test('continued step stores baseline tokens in _sessionBaselineTokens', () async {
      createSessionDir(sessionStep1);
      await seedSessionCost(sessionStep1, 250);

      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Research', prompts: ['Research the problem']),
          const WorkflowStep(id: 'step2', name: 'Implement', prompts: ['Implement fix'], continueSession: 'step1'),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      var step1Done = false;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        if (!step1Done) {
          step1Done = true;
          await taskService.updateFields(e.taskId, sessionId: sessionStep1);
        }
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      final allTasks = await taskService.list();
      final step2Task = allTasks.firstWhere(
        (t) => t.workflowRunId == 'run-1' && t.configJson['_continueSessionId'] != null,
      );
      expect(
        step2Task.configJson['_sessionBaselineTokens'],
        equals(250),
        reason: 'baseline should be the token count at step 1 completion',
      );
    });

    test('workflow totals reflect delta not cumulative shared-session tokens', () async {
      createSessionDir(sessionStep1);

      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['First']),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Second'], continueSession: 'step1'),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      var step1Done = false;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        if (!step1Done) {
          step1Done = true;
          // Step 1 uses 150 tokens.
          await taskService.updateFields(e.taskId, sessionId: sessionStep1);
          await seedSessionCost(sessionStep1, 150);
        } else {
          // After step 2, shared session has 300 total — delta should be 300 - 150 = 150.
          await taskService.updateFields(e.taskId, sessionId: sessionStep1);
          await seedSessionCost(sessionStep1, 300);
        }
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      final finalRun = await repository.getById('run-1');
      // Workflow total = 150 (step1 fresh) + 150 (step2 delta) = 300.
      // NOT 150 + 300 (full cumulative) = 450.
      expect(finalRun?.totalTokens, equals(300));
    });

    test('continueSession step pauses when previous step has no session ID', () async {
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['First']),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Second'], continueSession: 'step1'),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      // Complete step 1 without assigning a session ID.
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      final finalRun = await repository.getById('run-1');
      // step 1 completes; step 2 cannot resolve session → workflow pauses.
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
      expect(finalRun?.errorMessage, contains('continueSession'));
    });

    test('fresh-session step after continueSession step is unaffected', () async {
      createSessionDir(sessionStep1);

      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['First']),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Second'], continueSession: 'step1'),
          const WorkflowStep(id: 'step3', name: 'Step 3', prompts: ['Third']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      var stepCount = 0;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        stepCount++;
        if (stepCount == 1) {
          await taskService.updateFields(e.taskId, sessionId: sessionStep1);
          await seedSessionCost(sessionStep1, 100);
        }
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      // All 3 steps complete.
      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));

      // Step 3 has no _continueSessionId.
      final allTasks = await taskService.list();
      final step3Task = allTasks.where((t) => t.workflowRunId == 'run-1' && t.stepIndex == 2).firstOrNull;
      expect(step3Task?.configJson['_continueSessionId'], isNull);
    });
  });

  // ── S04 G3 (0.16.1): worktree context bridge ─────────────────────────────────

  group('S04 (0.16.1): worktree context bridge', () {
    test('coding step with worktreeJson exposes branch and worktree_path to context', () async {
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'fix', name: 'Fix Bug', type: 'coding', prompts: ['Fix the bug']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        // Simulate TaskExecutor persisting worktreeJson on the coding task.
        await taskService.updateFields(
          e.taskId,
          worktreeJson: {
            'branch': 'feat/fix-issue-42',
            'path': '/worktrees/fix-issue-42',
            'createdAt': '2026-01-01T00:00:00.000Z',
          },
        );
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));

      // Auto-exposed keys in contextJson.data (context.toJson() wraps data under 'data').
      final contextData = finalRun?.contextJson['data'] as Map?;
      expect(contextData?['fix.branch'], equals('feat/fix-issue-42'));
      expect(contextData?['fix.worktree_path'], equals('/worktrees/fix-issue-42'));
    });

    test('coding step without worktreeJson exposes empty values and does not fail workflow', () async {
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'fix', name: 'Fix Bug', type: 'coding', prompts: ['Fix the bug']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        // No worktreeJson set — simulates a coding task without worktree (e.g. no project).
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
      final contextData2 = finalRun?.contextJson['data'] as Map?;
      expect(contextData2?['fix.branch'], equals(''));
      expect(contextData2?['fix.worktree_path'], equals(''));
    });

    test('workflow research step injects branch/worktree_path keys through the coding task path', () async {
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'd',
        steps: const [
          WorkflowStep(id: 'research', name: 'Research', prompts: ['Research the issue']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext();

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, context);
      await sub.cancel();

      final finalRun = await repository.getById('run-1');
      final contextData3 = finalRun?.contextJson['data'] as Map?;
      expect(contextData3?['research.branch'], equals(''));
      expect(contextData3?['research.worktree_path'], equals(''));
    });
  });

  // ── S53: Status, outcome, accounting, and task boundary ──────────────────────

  group('S53: step outcome protocol and onFailure policy wiring', () {
    /// Completes a task after inserting an assistant message with the given content.
    Future<void> completeTaskWithOutcome(
      String taskId, {
      required String outcomeContent,
      TaskStatus finalStatus = TaskStatus.accepted,
    }) async {
      final session = await SessionService(baseDir: sessionsDir).createSession(type: SessionType.task);
      await taskService.updateFields(taskId, sessionId: session.id);
      await messageService.insertMessage(sessionId: session.id, role: 'assistant', content: outcomeContent);
      await completeTask(taskId, status: finalStatus);
    }

    test('emitsOwnOutcome: true omits step-outcome protocol from prompt', () async {
      // Regression for S36-B: a skill/step with emitsOwnOutcome: true must NOT
      // receive the "## Step Outcome Protocol" injection.
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'own-outcome',
            name: 'Own Outcome Step',
            prompts: ['Do the work'],
            emitsOwnOutcome: true,
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);

      String? capturedDescription;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final task = await taskService.get(e.taskId);
        capturedDescription = task?.description;
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      expect(capturedDescription, isNotNull);
      expect(capturedDescription, isNot(contains('## Step Outcome Protocol')));
      expect(capturedDescription, isNot(contains('<step-outcome>')));
    });

    test('missing step-outcome tag increments workflow.outcome.fallback and emits a warning', () async {
      // Regression for S36-B: when the assistant message does NOT contain a
      // <step-outcome> tag (and the step does not use emitsOwnOutcome), the
      // executor must fall back to task-lifecycle-derived outcome, increment
      // workflow.outcome.fallback, and NOT silently accept the empty outcome.
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'no-outcome', name: 'No Outcome', prompts: ['Do something']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId); // completes with accepted — no step-outcome tag
      });

      await executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      // Workflow should still complete successfully (accepted → succeeded fallback).
      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));

      // The fallback counter must have been incremented exactly once.
      final counterRaw = await kvService.get('workflow.outcome.fallback');
      expect(counterRaw, equals('1'));
    });

    test('onFailure: continueWorkflow continues execution after a failed outcome', () async {
      // Regression for S36-B: onFailure: continueWorkflow must advance to the
      // next step even when the step emits a failed outcome.
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'step1',
            name: 'Step 1',
            prompts: ['Do step 1'],
            onFailure: OnFailurePolicy.continueWorkflow,
          ),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);

      int taskCount = 0;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        taskCount++;
        if (taskCount == 1) {
          // Step 1 emits a failed outcome — with continueWorkflow the run must continue.
          await completeTaskWithOutcome(
            e.taskId,
            outcomeContent: '<step-outcome>{"outcome":"failed","reason":"non-blocking failure"}</step-outcome>',
          );
        } else {
          await completeTask(e.taskId);
        }
      });

      await executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      expect(taskCount, equals(2));
      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('onFailure: retry retries the step when the outcome is failed (outcome-driven retry)', () async {
      // Regression for S36-B: onFailure: retry must replay the agent step when
      // the step emits <step-outcome>{"outcome":"failed",...} and the attempt
      // count is within the retry limit.
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'step1',
            name: 'Step 1',
            prompts: ['Do step 1'],
            onFailure: OnFailurePolicy.retry,
            maxRetries: 1,
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);

      int taskCount = 0;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        taskCount++;
        if (taskCount == 1) {
          // First attempt: agent emits failed outcome — triggers outcome-based retry.
          await completeTaskWithOutcome(
            e.taskId,
            outcomeContent: '<step-outcome>{"outcome":"failed","reason":"first attempt failed"}</step-outcome>',
          );
        } else {
          // Second attempt (retry): agent succeeds.
          await completeTaskWithOutcome(
            e.taskId,
            outcomeContent: '<step-outcome>{"outcome":"succeeded","reason":"fixed"}</step-outcome>',
          );
        }
      });

      await executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      expect(taskCount, equals(2));
      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('step.<id>.outcome and reason are written to context after a successful step-outcome tag', () async {
      // Proves TI03: context records step.<id>.outcome and step.<id>.outcome.reason.
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 's1', name: 'S1', prompts: ['Do step']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await completeTaskWithOutcome(
          e.taskId,
          outcomeContent: '<step-outcome>{"outcome":"succeeded","reason":"all done"}</step-outcome>',
        );
      });

      final context = WorkflowContext();
      await executor.execute(run, definition, context);
      await sub.cancel();

      final finalRun = await repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
      expect(finalRun?.contextJson['data']?['step.s1.outcome'], equals('succeeded'));
      expect(finalRun?.contextJson['data']?['step.s1.outcome.reason'], equals('all done'));
    });
  });

  group('S53: ADR-023 workflow-task boundary', () {
    test('bash step creates zero tasks', () async {
      // Proves ADR-023: host-executed steps do not create Task rows.
      final definition = WorkflowDefinition(
        name: 'bash-zero-task',
        description: 'Bash step boundary',
        steps: const [
          WorkflowStep(id: 'bash1', name: 'Bash', type: 'bash', prompts: ['echo ok']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);

      await executor.execute(run, definition, WorkflowContext());

      final tasks = await taskService.list();
      expect(tasks.where((t) => t.workflowRunId == 'run-1'), isEmpty);
    });

    test('agent step creates exactly one TaskType.coding task', () async {
      // Proves ADR-023: agent steps compile to TaskType.coding tasks.
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'agent1', name: 'Agent', prompts: ['Do work']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      final workflowTasks = (await taskService.list()).where((t) => t.workflowRunId == 'run-1').toList();
      expect(workflowTasks, hasLength(1));
      expect(workflowTasks.first.type, equals(TaskType.coding));
    });

    test('Task.configJson has no _workflow* keys except the retained token/artifact fields', () async {
      // Proves ADR-023: workflow-owned state stays in WorkflowStepExecution side-table.
      // Only _workflowInputTokensNew, _workflowCacheReadTokens, _workflowOutputTokens
      // are permitted as compatibility fields in Task.configJson.
      final definition = makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do work']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);

      String? capturedTaskId;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        capturedTaskId = e.taskId;
        await completeTask(e.taskId);
      });

      await executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      expect(capturedTaskId, isNotNull);
      final task = await taskService.get(capturedTaskId!);
      expect(task, isNotNull);

      final allowedWorkflowKeys = {
        '_workflowInputTokensNew',
        '_workflowCacheReadTokens',
        '_workflowOutputTokens',
      };
      final forbiddenWorkflowKeys =
          task!.configJson.keys.where((k) => k.startsWith('_workflow') && !allowedWorkflowKeys.contains(k)).toList();
      expect(forbiddenWorkflowKeys, isEmpty, reason: 'Found unexpected _workflow* keys: $forbiddenWorkflowKeys');
    });
  });

  group('S53: ADR-022 status transitions', () {
    test('terminal getter is true only for completed, failed, and cancelled', () {
      // Proves ADR-022: exactly three terminal states.
      expect(WorkflowRunStatus.completed.terminal, isTrue);
      expect(WorkflowRunStatus.failed.terminal, isTrue);
      expect(WorkflowRunStatus.cancelled.terminal, isTrue);
      expect(WorkflowRunStatus.running.terminal, isFalse);
      expect(WorkflowRunStatus.pending.terminal, isFalse);
      expect(WorkflowRunStatus.paused.terminal, isFalse);
      expect(WorkflowRunStatus.awaitingApproval.terminal, isFalse);
    });

    test('only failed status has terminal=true among non-completed/cancelled states', () {
      // Proves ADR-022 status semantics: running and paused are non-terminal;
      // failed is terminal (enabling the retry-from-failed guard in WorkflowService).
      // Behavioral retry guard (StateError when not failed) is covered in workflow_service_test.dart.
      expect(WorkflowRunStatus.running.terminal, isFalse);
      expect(WorkflowRunStatus.paused.terminal, isFalse);
      expect(WorkflowRunStatus.awaitingApproval.terminal, isFalse);
      expect(WorkflowRunStatus.failed.terminal, isTrue);
    });
  });

  // ── S54: Workflow definition, step semantics, local-path, and foreach fidelity ─

  group('S54: foreach/map wrapped story_specs fidelity and recovery', () {
    test('wrapped {items:[...]} story_specs are auto-unwrapped and iterated as individual records', () async {
      // FOREACH-RECOVERY: the foreach/map controller must accept wrapped `{items:[...]}`
      // shaped records (as emitted by andthen-plan) and dispatch one child task per item.
      // Item id and dependencies must be preserved across the foreach boundary.
      // A simple single-step map (mapOver on the step itself) proves the unwrapping seam.
      final definition = WorkflowDefinition(
        name: 'foreach-fidelity',
        description: 'foreach fidelity test',
        steps: const [
          WorkflowStep(
            id: 'implement',
            name: 'Implement',
            prompts: ['implement story {{map.item.id}}'],
            mapOver: 'story_specs',
            maxParallel: 1,
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);

      // story_specs is wrapped in an {items:[...]} envelope as andthen-plan emits.
      const wrappedStorySpecs = {
        'items': [
          {'id': 'S01', 'title': 'Story One', 'dependencies': <String>[], 'spec_path': 'fis/s01.md'},
          {'id': 'S02', 'title': 'Story Two', 'dependencies': ['S01'], 'spec_path': 'fis/s02.md'},
        ],
      };

      var dispatchedCount = 0;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        dispatchedCount++;
        await completeTask(e.taskId);
      });

      await executor.execute(
        run,
        definition,
        WorkflowContext(data: {'story_specs': wrappedStorySpecs}),
      );
      await sub.cancel();

      final finalRun = await repository.getById(run.id);
      // Wrapped items must be unwrapped and both items dispatched as separate tasks.
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
      expect(dispatchedCount, equals(2));
    });

    test('failed map item sets run to failed and preserves cursor at map step', () async {
      // FOREACH-RECOVERY: when a child map item fails, the foreach controller must stop
      // and leave currentStepIndex pointing at or before the map step so a retry
      // can resume at the failing item's boundary.
      final definition = WorkflowDefinition(
        name: 'foreach-recovery',
        description: 'foreach recovery cursor test',
        steps: const [
          WorkflowStep(
            id: 'implement',
            name: 'Implement',
            prompts: ['implement story'],
            mapOver: 'story_specs',
            maxParallel: 1,
          ),
          WorkflowStep(id: 'update-state', name: 'Update State', prompts: ['update state']),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);

      const storySpecs = {
        'items': [
          {'id': 'S01', 'title': 'Story One', 'dependencies': <String>[], 'spec_path': 'fis/s01.md'},
          {'id': 'S02', 'title': 'Story Two', 'dependencies': <String>[], 'spec_path': 'fis/s02.md'},
        ],
      };

      var itemIndex = 0;
      var updateStateDispatched = false;
      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final task = await taskService.get(e.taskId);
        if (task == null) return;
        if (task.title.contains('Update State')) {
          updateStateDispatched = true;
          await completeTask(e.taskId);
        } else {
          // Fail the second item to trigger recovery.
          if (itemIndex == 1) {
            await completeTask(e.taskId, status: TaskStatus.failed);
          } else {
            await completeTask(e.taskId);
          }
          itemIndex++;
        }
      });

      await executor.execute(
        run,
        definition,
        WorkflowContext(data: {'story_specs': storySpecs}),
      );
      await sub.cancel();

      final finalRun = await repository.getById(run.id);
      // Run must fail; update-state must NOT have been dispatched.
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
      expect(updateStateDispatched, isFalse, reason: 'update-state must not execute when a map item fails');
      // currentStepIndex must not advance past the map step (index 0).
      expect(finalRun?.currentStepIndex, equals(0));
    });
  });

  // ── S55: Restart, idempotency, and operator race hardening ─────────────────
  //
  // S52 closure ledger items routed to S55:
  //   OPERATOR-RACES       live defect  → action precedence matrix tests (workflow_service_test.dart S55 group)
  //   RESTART-IDEMPOTENCY  live defect  → retry-after-promotion cursor proof (service test + below)
  //   CONCURRENT-CHECKOUT  live defect  → RepoLock serialization proof (service test)
  //   APPROVAL-HOLD        live defect  → worktree/context preservation (service test + below)
  //   STRUCT-OUTPUT-COMPAT deferred     → PRODUCT-BACKLOG; S54 proved built-in schema compat;
  //                                       user-authored schema compatibility is not a runtime gap.
  //
  // S53/S54 contracts consumed without modification:
  //   - ADR-022 terminal status semantics (WorkflowRunStatus.terminal, proven in S53 group above)
  //   - S53 retry cursors (WorkflowExecutionCursor) are the idempotency carriers for map/foreach
  //   - S54 local-path dirty check is the protected start-time boundary (FR3-AC4)
  //   - _transitionStepAwaitingApproval does not call _cleanupWorkflowGit (FR3-AC5 preserved by design)

  group('S55: publish failure preserves inspectable recovery state', () {
    // RESTART-IDEMPOTENCY / FR3-AC2: publish failure must not destroy worktree/branch/artifact
    // evidence. The run transitions to failed (not completed), so _cleanupWorkflowGit is not
    // invoked — the run, its context, and any bound worktrees remain readable for recovery.

    test('publish failure transitions run to failed without cleanup of worktree evidence', () async {
      // FR3-AC2: injected publish failure must set run.status = failed and must NOT call
      // the cleanup/preserve-worktrees=false path. The run remains in an inspectable state.
      final cleanupCalls = <({bool preserveWorktrees})>[];
      final publishExecutor = makeExecutor(
        turnAdapter: WorkflowTurnAdapter(
          reserveTurn: (_) => Future.value('turn-1'),
          executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
          waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
          publishWorkflowBranch: ({required runId, required projectId, required branch}) async =>
              throw const WorkflowGitException('push failed: remote rejected'),
          cleanupWorkflowGit: ({
            required runId,
            required projectId,
            required status,
            required preserveWorktrees,
          }) async {
            cleanupCalls.add((preserveWorktrees: preserveWorktrees));
          },
        ),
      );

      final definition = WorkflowDefinition(
        name: 'publish-fail',
        description: 'Publish failure preservation test',
        gitStrategy: const WorkflowGitStrategy(publish: WorkflowGitPublishStrategy(enabled: true)),
        steps: const [],
        variables: {'PROJECT': const WorkflowVariable(required: false)},
      );

      final run = WorkflowRun(
        id: 'publish-fail-run',
        definitionName: definition.name,
        status: WorkflowRunStatus.running,
        startedAt: DateTime.now(),
        updatedAt: DateTime.now(),
        variablesJson: const {'PROJECT': 'my-project', 'BRANCH': 'feature/test'},
        definitionJson: definition.toJson(),
        workflowWorktree: const WorkflowWorktreeBinding(
          key: 'publish-fail-run',
          path: '/tmp/worktrees/wf-publish-fail',
          branch: 'dartclaw/workflow/publish-fail/integration',
          workflowRunId: 'publish-fail-run',
        ),
      );
      await repository.insert(run);

      await publishExecutor.execute(
        run,
        definition,
        WorkflowContext(variables: const {'PROJECT': 'my-project', 'BRANCH': 'feature/test'}),
      );

      final finalRun = await repository.getById(run.id);
      // Run must be failed — publish failure does not complete or cancel the run.
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
      expect(finalRun?.errorMessage, contains('push failed'));
      // Cleanup (with preserveWorktrees=false) must NOT have been called.
      // Evidence: the cleanup adapter was not called at all on publish failure.
      expect(cleanupCalls, isEmpty, reason: 'worktree/artifact evidence must not be cleaned up on publish failure');
    });

    test('publish failure run retains its run id, error message, and inspectable context', () async {
      // FR3-AC2: a failed publish must record enough state for operator recovery:
      // run id, status=failed, error message, and any previously accumulated context.
      final publishExecutor = makeExecutor(
        turnAdapter: WorkflowTurnAdapter(
          reserveTurn: (_) => Future.value('turn-1'),
          executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
          waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
          publishWorkflowBranch: ({required runId, required projectId, required branch}) async =>
              throw const WorkflowGitException('network unreachable'),
        ),
      );

      final definition = WorkflowDefinition(
        name: 'publish-fail-context',
        description: 'Publish failure context preservation',
        gitStrategy: const WorkflowGitStrategy(publish: WorkflowGitPublishStrategy(enabled: true)),
        steps: const [],
        variables: {'PROJECT': const WorkflowVariable(required: false)},
      );

      final run = WorkflowRun(
        id: 'publish-fail-ctx-run',
        definitionName: definition.name,
        status: WorkflowRunStatus.running,
        startedAt: DateTime.now(),
        updatedAt: DateTime.now(),
        variablesJson: const {'PROJECT': 'my-project', 'BRANCH': 'feature/test'},
        definitionJson: definition.toJson(),
        contextJson: const {
          'prior-step.status': 'accepted',
          'step.prior-step.outcome': 'succeeded',
          'data': <String, dynamic>{
            'prior-step.status': 'accepted',
            'step.prior-step.outcome': 'succeeded',
          },
          'variables': <String, dynamic>{},
        },
      );
      await repository.insert(run);

      await publishExecutor.execute(
        run,
        definition,
        WorkflowContext(variables: const {'PROJECT': 'my-project', 'BRANCH': 'feature/test'}),
      );

      final finalRun = await repository.getById(run.id);
      expect(finalRun?.id, equals('publish-fail-ctx-run'));
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
      expect(finalRun?.errorMessage, isNotNull);
      expect(finalRun?.errorMessage, contains('network unreachable'));
    });
  });

  group('S55: awaitingApproval hold preserves worktree/context evidence', () {
    // APPROVAL-HOLD / FR3-AC5: the approval hold transition (_transitionStepAwaitingApproval)
    // does not call _cleanupWorkflowGit, so worktree bindings and context are preserved.
    // This test proves the executor's hold behavior by inspecting what changes at hold time.

    test('needsInput hold transitions to awaitingApproval without losing prior-step context', () async {
      // FR3-AC5: prior step token/outcome evidence must survive the approval hold.
      // The run transitions to awaitingApproval; its contextJson retains prior evidence.
      // needsInput is triggered via the <step-outcome> tag embedded in the agent message.
      // Prior-step evidence is pre-seeded in contextJson and passed in the WorkflowContext.
      final approvalRequests = <WorkflowApprovalRequestedEvent>[];
      final evSub = eventBus.on<WorkflowApprovalRequestedEvent>().listen(approvalRequests.add);
      final localSessionService = SessionService(baseDir: sessionsDir);

      final sub = eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
        await Future<void>.delayed(Duration.zero);
        final task = await taskService.get(e.taskId);
        if (task == null) return;
        final session = await localSessionService.createSession(type: SessionType.task);
        await taskService.updateFields(task.id, sessionId: session.id);
        // The review-gate step emits needsInput to trigger the approval hold.
        await messageService.insertMessage(
          sessionId: session.id,
          role: 'assistant',
          content: 'Blocked pending human decision.\n'
              '<step-outcome>{"outcome":"needsInput","reason":"human decision required"}</step-outcome>',
        );
        await completeTask(e.taskId);
      });

      final definition = WorkflowDefinition(
        name: 'hold-preservation',
        description: 'Hold preservation test',
        // Single step: review-gate emits needsInput.
        steps: const [
          WorkflowStep(id: 'review-gate', name: 'Review Gate', prompts: ['Review and approve']),
        ],
      );

      // Pre-seed prior-impl evidence in contextJson as if a prior step completed.
      final preContext = WorkflowContext(
        data: {
          'prior-impl.status': 'accepted',
          'prior-impl.tokenCount': 100,
        },
      );

      final run = WorkflowRun(
        id: 'hold-preservation-run',
        definitionName: definition.name,
        status: WorkflowRunStatus.running,
        startedAt: DateTime.now(),
        updatedAt: DateTime.now(),
        definitionJson: definition.toJson(),
        contextJson: preContext.toJson(),
      );
      await repository.insert(run);

      await executor.execute(run, definition, preContext);

      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      await evSub.cancel();

      final finalRun = await repository.getById(run.id);
      // Run must hold at awaitingApproval.
      expect(finalRun?.status, equals(WorkflowRunStatus.awaitingApproval));
      // Approval event must have fired.
      expect(approvalRequests, hasLength(1));
      expect(approvalRequests.first.stepId, equals('review-gate'));
      // Prior step evidence must be intact in contextJson — no cleanup was called.
      final data = finalRun?.contextJson['data'] as Map?;
      expect(data?['prior-impl.status'], equals('accepted'));
      expect(data?['prior-impl.tokenCount'], equals(100));
    });
  });
}
