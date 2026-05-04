// WorkflowExecutor sequential integration: single/multi-step sequencing,
// git-owned task lifecycle, project binding, context propagation, inline
// loops, cancellation, budget, and event emission.
@Tags(['component'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_models/dartclaw_models.dart' show Project, ProjectStatus, SessionType;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        ArtifactKind,
        ContextExtractor,
        OutputConfig,
        OutputFormat,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowGitArtifactsStrategy,
        WorkflowGitBootstrapResult,
        WorkflowGitPromotionSuccess,
        WorkflowGitPublishResult,
        WorkflowPublishStatus,
        WorkflowGitPublishStrategy,
        WorkflowGitStrategy,
        WorkflowGitWorktreeStrategy,
        WorkflowLoop,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowRunStatusChangedEvent,
        WorkflowStep,
        WorkflowStepCompletedEvent,
        WorkflowTurnAdapter,
        WorkflowTurnOutcome,
        WorkflowVariable;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeGitGateway, FakeProjectService;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'workflow_executor_test_support.dart';

void main() {
  final h = WorkflowExecutorHarness();
  setUp(h.setUp);
  tearDown(h.tearDown);

  test('workflow execution fails fast when AE/WSE persistence is not wired', () async {
    final bareExecutor = h.makeExecutor(
      wirePersistence: false,
      contextExtractor: ContextExtractor(
        taskService: h.taskService,
        messageService: h.messageService,
        dataDir: h.tempDir.path,
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
    await h.repository.insert(run);

    Object? captured;
    try {
      await bareExecutor.execute(run, definition, WorkflowContext());
    } catch (err) {
      captured = err;
    }
    if (captured == null) {
      final finalRun = await h.repository.getById('run-fail-fast');
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
      expect(finalRun?.errorMessage, contains('AgentExecution + WorkflowStepExecution persistence'));
    } else {
      expect(captured, isA<StateError>());
      expect((captured as StateError).message, contains('AgentExecution + WorkflowStepExecution persistence'));
    }
  });

  test('fatal artifact commit failure emits failed step and stops before downstream dispatch', () async {
    final repoDir = Directory(p.join(h.tempDir.path, 'projects', 'proj'))..createSync(recursive: true);
    File(p.join(repoDir.path, 'plan.md')).writeAsStringSync('plan');
    final git = FakeGitGateway()
      ..initWorktree(repoDir.path)
      ..addUntracked(repoDir.path, 'plan.md', content: 'plan')
      ..failNextAdd('add failed');
    h.executor = h.makeExecutor(
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
          allowedTools: ['file_read'],
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
    final run = h.makeRun(definition);
    await h.repository.insert(run);
    final stepEvents = <WorkflowStepCompletedEvent>[];
    final stepSub = h.eventBus.on<WorkflowStepCompletedEvent>().listen(stepEvents.add);
    final taskSub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, WorkflowContext(data: {'story_specs': <Map<String, Object?>>[]}));
    await taskSub.cancel();
    await stepSub.cancel();

    final stored = await h.repository.getById(run.id);
    expect(stored?.status, WorkflowRunStatus.failed);
    expect(stored?.currentStepIndex, 0);
    expect(stored?.errorMessage, contains('add failed'));
    expect(stepEvents.map((event) => (event.stepId, event.success)), [('plan', false)]);
  });

  test('3-step sequential workflow executes all steps', () async {
    final definition = h.makeDefinition(
      steps: [
        const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
        const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
        const WorkflowStep(id: 'step3', name: 'Step 3', prompts: ['Do step 3']),
      ],
    );

    final run = h.makeRun(definition);
    await h.repository.insert(run);
    final context = WorkflowContext();

    final taskIds = <String>[];
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      taskIds.add(e.taskId);
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, context);
    await sub.cancel();

    expect(taskIds.length, equals(3));

    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });

  test('entry-gated skip records skipped outcome and still executes following steps', () async {
    final definition = h.makeDefinition(
      steps: [
        const WorkflowStep(id: 'spec', name: 'Spec', entryGate: 'should_run == true', prompts: ['Write the spec']),
        const WorkflowStep(id: 'implement', name: 'Implement', prompts: ['Implement the change']),
      ],
    );

    final run = h.makeRun(definition);
    await h.repository.insert(run);
    final context = WorkflowContext(data: {'should_run': false});

    final queuedTaskIds = <String>[];
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      queuedTaskIds.add(e.taskId);
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, context);
    await sub.cancel();

    expect(queuedTaskIds, hasLength(1));
    final queuedTask = await h.taskService.get(queuedTaskIds.single);
    expect(queuedTask?.title, contains('Implement'));

    final finalRun = await h.repository.getById('run-1');
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
      project: '{{PROJECT}}',
      gitStrategy: const WorkflowGitStrategy(
        bootstrap: true,
        worktree: WorkflowGitWorktreeStrategy(mode: 'per-map-item'),
        promotion: 'merge',
        publish: WorkflowGitPublishStrategy(enabled: false),
      ),
      steps: const [
        WorkflowStep(id: 'implement', name: 'Implement', prompts: ['Implement the story']),
      ],
    );

    final run = h.makeRun(definition);
    await h.repository.insert(run);
    final context = WorkflowContext(variables: const {'PROJECT': 'my-project', 'BRANCH': 'main'});
    final promotionCalls = <Map<String, String?>>[];

    final runtimeExecutor = h.makeExecutor(
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

    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      await h.taskService.updateFields(
        e.taskId,
        worktreeJson: {
          'path': p.join(h.tempDir.path, 'worktrees', e.taskId),
          'branch': 'story-branch',
          'createdAt': DateTime.now().toIso8601String(),
        },
      );
      try {
        await h.taskService.transition(e.taskId, TaskStatus.running, trigger: 'test');
      } on StateError {
        // Already running.
      }
      await h.taskService.transition(e.taskId, TaskStatus.accepted, trigger: 'test');
    });

    await runtimeExecutor.execute(run, definition, context);
    await sub.cancel();

    final finalTask = (await h.taskService.list()).single;
    final finalRun = await h.repository.getById('run-1');
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

  test('context from step 1 is available in step 2 prompt', () async {
    final definition = h.makeDefinition(
      steps: [
        const WorkflowStep(
          id: 'step1',
          name: 'Research',
          prompts: ['Do research'],
          outputs: {'research_notes': OutputConfig()},
        ),
        const WorkflowStep(id: 'step2', name: 'Summarize', prompts: ['Summarize: {{context.research_notes}}']),
      ],
    );

    final run = h.makeRun(definition);
    await h.repository.insert(run);

    final capturedTaskIds = <String>[];
    final capturedDescriptions = <String>[];

    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      final task = await h.taskService.get(e.taskId);
      if (task != null) {
        capturedTaskIds.add(e.taskId);
        capturedDescriptions.add(task.description);

        if (capturedTaskIds.length == 1) {
          final artifactsDir = Directory(p.join(h.tempDir.path, 'tasks', e.taskId, 'artifacts'));
          artifactsDir.createSync(recursive: true);
          final mdFile = File(p.join(artifactsDir.path, 'output.md'));
          mdFile.writeAsStringSync('Key findings about the topic.');
          await h.taskService.addArtifact(
            id: 'art-1',
            taskId: e.taskId,
            name: 'output.md',
            kind: ArtifactKind.document,
            path: mdFile.path,
          );
        }
      }
      await h.completeTask(e.taskId);
    });

    final context = WorkflowContext();
    await h.executor.execute(run, definition, context);
    await sub.cancel();

    expect(capturedDescriptions.length, equals(2));
    expect(capturedDescriptions[1], contains('Key findings about the topic.'));
  });

  test('loop-body workflow-owned git coding task promotes after accepted completion', () async {
    final definition = WorkflowDefinition(
      name: 'loop-workflow-git-auto-accept',
      description: 'Loop-owned git tasks should promote after accepted completion.',
      project: '{{PROJECT}}',
      gitStrategy: const WorkflowGitStrategy(
        bootstrap: true,
        worktree: WorkflowGitWorktreeStrategy(mode: 'per-task'),
        publish: WorkflowGitPublishStrategy(enabled: false),
      ),
      steps: const [
        WorkflowStep(id: 'implement', name: 'Implement', prompts: ['Implement']),
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

    final run = h.makeRun(definition);
    await h.repository.insert(run);
    final context = WorkflowContext(data: {'implement.status': 'pending'}, variables: const {'PROJECT': 'my-project'});
    final promotionCalls = <Map<String, String?>>[];

    final runtimeExecutor = h.makeExecutor(
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

    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      await h.taskService.updateFields(
        e.taskId,
        worktreeJson: {
          'path': p.join(h.tempDir.path, 'worktrees', e.taskId),
          'branch': 'loop-branch',
          'createdAt': DateTime.now().toIso8601String(),
        },
      );
      try {
        await h.taskService.transition(e.taskId, TaskStatus.running, trigger: 'test');
      } on StateError {
        // Already running.
      }
      await h.taskService.transition(e.taskId, TaskStatus.accepted, trigger: 'test');
    });

    await runtimeExecutor.execute(run, definition, context);
    await sub.cancel();

    final finalTask = (await h.taskService.list()).single;
    final finalRun = await h.repository.getById('run-1');
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
    final definition = h.makeDefinition(
      steps: [
        const WorkflowStep(id: 'step1', name: 'Failing Step', prompts: ['Do the failing step']),
      ],
    );

    final run = h.makeRun(definition);
    await h.repository.insert(run);
    final sessionService = h.sessionService;

    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      final task = await h.taskService.get(e.taskId);
      if (task == null) return;

      final session = await sessionService.createSession(type: SessionType.task);
      await h.taskService.updateFields(task.id, sessionId: session.id);
      await h.kvService.set('session_cost:${session.id}', jsonEncode({'total_tokens': 7}));
      await h.taskService.transition(task.id, TaskStatus.running, trigger: 'test');
      await h.taskService.transition(task.id, TaskStatus.failed, trigger: 'test');
    });

    final context = WorkflowContext();
    await h.executor.execute(run, definition, context);
    await sub.cancel();

    final finalRun = await h.repository.getById(run.id);
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    expect(finalRun?.totalTokens, equals(7));
    expect(context['step1.status'], equals('failed'));
    expect(context['step1.tokenCount'], equals(7));
  });

  test('task description includes required output format for explicit json schema', () async {
    final definition = h.makeDefinition(
      steps: [
        const WorkflowStep(
          id: 'review',
          name: 'Review',
          prompts: ['Review the implementation.'],
          outputs: {'result': OutputConfig(format: OutputFormat.json, schema: 'verdict')},
        ),
      ],
    );

    final run = h.makeRun(definition);
    await h.repository.insert(run);
    final context = WorkflowContext();

    String? capturedDescription;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      final task = await h.taskService.get(e.taskId);
      capturedDescription = task?.description;
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, context);
    await sub.cancel();

    expect(capturedDescription, contains('Review the implementation.'));
    expect(capturedDescription, contains('## Workflow Output Contract'));
    expect(capturedDescription, contains('findings_count'));
  });

  test('workflow task config carries built-in workflow workspace path', () async {
    final definition = h.makeDefinition(
      steps: [
        const WorkflowStep(
          id: 'spec',
          name: 'Generate Spec',
          prompts: ['Write the specification.'],
          outputs: {'result': OutputConfig(format: OutputFormat.json)},
        ),
      ],
    );

    final run = h.makeRun(definition);
    await h.repository.insert(run);
    final context = WorkflowContext();

    String? capturedDescription;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      final task = await h.taskService.get(e.taskId);
      capturedDescription = task?.description;
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, context);
    await sub.cancel();

    final workflowWorkspaceDir = p.join(h.tempDir.path, 'workflow-workspace');
    expect(capturedDescription, contains('Write the specification.'));
    expect(
      (await h.agentExecutionRepository.get((await h.taskService.list()).single.agentExecutionId!))?.workspaceDir,
      workflowWorkspaceDir,
    );
    expect(File(p.join(workflowWorkspaceDir, 'AGENTS.md')).existsSync(), isTrue);
  });

  test('deterministic publish writes publish.* outputs when enabled', () async {
    final publishExecutor = h.makeExecutor(
      turnAdapter: WorkflowTurnAdapter(
        reserveTurn: (_) => Future.value('turn-1'),
        executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
        waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
        publishWorkflowBranch: ({required runId, required projectId, required branch}) async =>
            WorkflowGitPublishResult(
              status: WorkflowPublishStatus.success,
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
    await h.repository.insert(run);

    final context = WorkflowContext(variables: const {'PROJECT': 'my-project', 'BRANCH': 'feature/test'});
    await publishExecutor.execute(run, definition, context);

    final finalRun = await h.repository.getById(run.id);
    expect(finalRun?.status, WorkflowRunStatus.completed);
    expect(context['publish.status'], 'success');
    expect(context['publish.branch'], 'feature/test');
    expect(context['publish.remote'], 'origin');
    expect(context['publish.pr_url'], 'https://example.test/pr/123');
  });

  test('workflow git bootstrap passes an empty baseRef when BRANCH is absent', () async {
    String? capturedBaseRef;
    final bootstrapExecutor = h.makeExecutor(
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
    await h.repository.insert(run);

    await bootstrapExecutor.execute(run, definition, WorkflowContext(variables: const {'PROJECT': 'my-project'}));

    expect(capturedBaseRef, isEmpty);
  });

  test('artifact commit stages path outputs from the producing task worktree', () async {
    final projectDir = Directory(p.join(h.tempDir.path, 'projects', 'my-project'))..createSync(recursive: true);
    final worktreeDir = Directory(p.join(h.tempDir.path, 'worktree'));

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
      project: '{{PROJECT}}',
      gitStrategy: const WorkflowGitStrategy(
        artifacts: WorkflowGitArtifactsStrategy(commit: true, commitMessage: 'workflow artifacts {{runId}}'),
      ),
      variables: const {'PROJECT': WorkflowVariable(required: false)},
      steps: const [
        WorkflowStep(
          id: 'spec',
          name: 'Spec',
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
    await h.repository.insert(run);

    final context = WorkflowContext(variables: const {'PROJECT': 'my-project'});

    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      final outputPath = p.join(worktreeDir.path, 'docs', 'specs', 'test.md');
      File(outputPath).parent.createSync(recursive: true);
      File(outputPath).writeAsStringSync('# test\n');
      final task = await h.taskService.get(e.taskId);
      expect(task, isNotNull);
      final session = await h.sessionService.createSession(type: SessionType.task);
      await h.taskService.updateFields(
        task!.id,
        sessionId: session.id,
        worktreeJson: {
          'path': worktreeDir.path,
          'branch': 'dartclaw/workflow/run-1',
          'createdAt': DateTime.now().toIso8601String(),
        },
      );
      await h.messageService.insertMessage(
        sessionId: session.id,
        role: 'assistant',
        content: '<workflow-context>${jsonEncode({'spec_path': 'docs/specs/test.md'})}</workflow-context>',
      );
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, context);
    await sub.cancel();

    final logResult = runGit(worktreeDir.path, ['log', '-1', '--pretty=%s']);
    expect((logResult.stdout as String).trim(), 'workflow artifacts run-1');
    final showResult = runGit(worktreeDir.path, ['show', 'HEAD:docs/specs/test.md']);
    expect(showResult.stdout, contains('# test'));
  });

  test('artifact commit resolves localPath projects without relying on dataDir/projects', () async {
    final projectDir = Directory(p.join(h.tempDir.path, 'named-local-project'))..createSync(recursive: true);

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

    final localPathExecutor = h.makeExecutor(projectService: projectService);

    final definition = WorkflowDefinition(
      name: 'artifact-commit-local-path',
      description: 'Commits artifacts in named localPath projects',
      project: '{{PROJECT}}',
      gitStrategy: const WorkflowGitStrategy(
        artifacts: WorkflowGitArtifactsStrategy(commit: true, commitMessage: 'workflow artifacts {{runId}}'),
      ),
      variables: const {'PROJECT': WorkflowVariable(required: false)},
      steps: const [
        WorkflowStep(
          id: 'spec',
          name: 'Spec',
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
    await h.repository.insert(run);

    final context = WorkflowContext(variables: const {'PROJECT': 'my-project'});
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      final outputPath = p.join(projectDir.path, 'docs', 'specs', 'test.md');
      File(outputPath).parent.createSync(recursive: true);
      File(outputPath).writeAsStringSync('# local path test\n');
      final session = await h.sessionService.createSession(type: SessionType.task);
      await h.taskService.updateFields(e.taskId, sessionId: session.id, worktreeJson: {'path': projectDir.path});
      await h.messageService.insertMessage(
        sessionId: session.id,
        role: 'assistant',
        content: '<workflow-context>${jsonEncode({'spec_path': 'docs/specs/test.md'})}</workflow-context>',
      );
      await h.completeTask(e.taskId);
    });

    await localPathExecutor.execute(run, definition, context);
    await sub.cancel();

    final logResult = runGit(projectDir.path, ['log', '-1', '--pretty=%s']);
    expect((logResult.stdout as String).trim(), 'workflow artifacts run-local-path');
    final showResult = runGit(projectDir.path, ['show', 'HEAD:docs/specs/test.md']);
    expect(showResult.stdout, contains('# local path test'));
  });

  test('step failure pauses workflow', () async {
    final definition = h.makeDefinition(
      steps: [
        const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
        const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
      ],
    );

    final run = h.makeRun(definition);
    await h.repository.insert(run);
    final context = WorkflowContext();

    var stepCount = 0;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      stepCount++;
      if (stepCount == 1) {
        await h.completeTask(e.taskId, status: TaskStatus.failed);
      } else {
        await h.completeTask(e.taskId);
      }
    });

    await h.executor.execute(run, definition, context);
    await sub.cancel();

    expect(stepCount, equals(1));
    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    expect(finalRun?.errorMessage, contains('step1'));
  });

  test('gate failure pauses workflow', () async {
    final definition = h.makeDefinition(
      steps: [
        const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
        const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2'], gate: 'step1.approved == true'),
      ],
    );

    final run = h.makeRun(definition);
    await h.repository.insert(run);

    final context = WorkflowContext(data: {'step1.approved': 'false'});

    var stepCount = 0;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      stepCount++;
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, context);
    await sub.cancel();

    expect(stepCount, equals(1));
    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    expect(finalRun?.errorMessage, contains('Gate failed'));
  });

  test('workflow task config always uses auto-accept review mode', () async {
    Future<String?> captureReviewMode(WorkflowStep step, {TaskStatus completionStatus = TaskStatus.accepted}) async {
      final definition = WorkflowDefinition(
        name: 'review-mode-${step.id}',
        description: 'Review mode capture',
        steps: [step],
      );
      final run = h.makeRun(definition).copyWith(id: 'run-${step.id}');
      await h.repository.insert(run);
      final context = WorkflowContext();
      final modeCompleter = Completer<String?>();

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        final task = await h.taskService.get(e.taskId);
        if (task != null && !modeCompleter.isCompleted) {
          modeCompleter.complete(task.configJson['reviewMode'] as String?);
        }
        try {
          await h.taskService.transition(e.taskId, TaskStatus.running, trigger: 'test');
        } on StateError {
          // Already running.
        }
        if (completionStatus == TaskStatus.accepted) {
          await h.taskService.transition(e.taskId, TaskStatus.accepted, trigger: 'test');
        } else {
          await h.taskService.transition(e.taskId, completionStatus, trigger: 'test');
        }
      });

      await h.executor.execute(run, definition, context);
      await sub.cancel();
      return modeCompleter.future;
    }

    expect(
      await captureReviewMode(const WorkflowStep(id: 'default-step', name: 'Default Step', prompts: ['Implement'])),
      'auto-accept',
    );
  });

  test('workflow-level project does not bind read-only steps without project-index context', () async {
    const definition = WorkflowDefinition(
      name: 'workflow-project-analysis-unbound',
      description: 'Read-only workflow steps should not bind workflow-level project ids.',
      project: '{{PROJECT}}',
      steps: [
        WorkflowStep(id: 'review', name: 'Review', allowedTools: ['file_read'], prompts: ['Review the repo']),
      ],
    );

    final task = await h.executeAndCaptureSingleTask(
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
          allowedTools: ['file_read'],
          inputs: ['project_index'],
          prompts: ['Review the generated plan'],
        ),
      ],
    );

    final task = await h.executeAndCaptureSingleTask(
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

  test('workflow-level project still binds neutral agent steps without an explicit tool allowlist', () async {
    const definition = WorkflowDefinition(
      name: 'workflow-project-agent-bound',
      description: 'Neutral agent steps bind the workflow project.',
      project: '{{PROJECT}}',
      steps: [
        WorkflowStep(id: 'implement', name: 'Implement', prompts: ['Implement the change']),
      ],
    );

    final task = await h.executeAndCaptureSingleTask(
      definition: definition,
      context: WorkflowContext(variables: const {'PROJECT': 'demo-project'}),
      runId: 'run-agent-bound',
    );

    expect(task.projectId, 'demo-project');
    expect(task.configJson['_workflowNeedsWorktree'], isTrue);
  });

  test('workflow-level project binds project-index agent steps', () async {
    const definition = WorkflowDefinition(
      name: 'workflow-project-index-bound',
      description: 'Workflow project binding is declared once at workflow level.',
      project: '{{PROJECT}}',
      steps: [
        WorkflowStep(id: 'review', name: 'Review', inputs: ['project_index'], prompts: ['Review the repo']),
      ],
    );

    final task = await h.executeAndCaptureSingleTask(
      definition: definition,
      context: WorkflowContext(
        variables: const {'PROJECT': 'code-project'},
        data: const {
          'project_index': {'project_root': '/repo/code-project'},
        },
      ),
      runId: 'run-project-index-bound',
    );

    expect(task.projectId, 'code-project');
    expect(task.configJson['_workflowNeedsWorktree'], isTrue);
  });

  test('cancellation token stops execution between steps', () async {
    final definition = h.makeDefinition(
      steps: [
        const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
        const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
      ],
    );

    final run = h.makeRun(definition);
    await h.repository.insert(run);
    final context = WorkflowContext();

    var stepCount = 0;
    var cancelled = false;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      stepCount++;
      cancelled = true;
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, context, isCancelled: () => cancelled);
    await sub.cancel();

    expect(stepCount, equals(1));
  });

  test('workflow budget exceeded pauses workflow before next step', () async {
    final definition = h.makeDefinition(
      maxTokens: 1000,
      steps: [
        const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
        const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
      ],
    );

    var run = h.makeRun(definition);
    run = run.copyWith(totalTokens: 1000);
    await h.repository.insert(run);
    final context = WorkflowContext();

    var stepCount = 0;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      stepCount++;
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, context);
    await sub.cancel();

    expect(stepCount, lessThanOrEqualTo(1));
    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    expect(finalRun?.errorMessage, contains('budget'));
  });

  test('automatic metadata keys set after step completes', () async {
    final definition = h.makeDefinition(
      steps: [
        const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
      ],
    );

    final run = h.makeRun(definition);
    await h.repository.insert(run);
    final context = WorkflowContext();

    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, context);
    await sub.cancel();

    expect(context['step1.status'], equals('accepted'));
    expect(context['step1.tokenCount'], isNotNull);
  });

  test('WorkflowRunStatusChangedEvent fired on completion', () async {
    final definition = h.makeDefinition();
    final run = h.makeRun(definition);
    await h.repository.insert(run);
    final context = WorkflowContext();

    final statusEvents = <WorkflowRunStatusChangedEvent>[];
    final statusSub = h.eventBus.on<WorkflowRunStatusChangedEvent>().listen(statusEvents.add);

    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, context);
    await sub.cancel();
    await statusSub.cancel();

    expect(statusEvents, isNotEmpty);
    expect(statusEvents.last.newStatus, equals(WorkflowRunStatus.completed));
  });

  test('WorkflowStepCompletedEvent fired after each step', () async {
    final definition = h.makeDefinition(
      steps: [
        const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
        const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
      ],
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);
    final context = WorkflowContext();

    final stepEvents = <WorkflowStepCompletedEvent>[];
    final stepSub = h.eventBus.on<WorkflowStepCompletedEvent>().listen(stepEvents.add);

    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, context);
    await sub.cancel();
    await stepSub.cancel();

    expect(stepEvents.length, equals(2));
    expect(stepEvents[0].stepId, equals('step1'));
    expect(stepEvents[1].stepId, equals('step2'));
  });
}
