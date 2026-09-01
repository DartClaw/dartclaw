import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        ContextExtractor,
        OutputConfig,
        OutputFormat,
        SqliteWorkflowRunRepository,
        WorkflowRun,
        WorkflowStep,
        WorkflowWorktreeBinding;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'task_executor_test_support.dart';

void main() {
  late FakeTaskWorker worker;
  late WorkflowTaskExecutorTestContext ctx;
  late MessageService messages;
  late TaskService tasks;
  late SqliteWorkflowRunRepository workflowRuns;
  late SqliteWorkflowStepExecutionRepository workflowStepExecutions;

  setUp(() async {
    worker = FakeTaskWorker();
    ctx = WorkflowTaskExecutorTestContext(worker);
    await ctx.setUp();
    messages = ctx.messages;
    tasks = ctx.tasks;
    workflowRuns = ctx.workflowRuns;
    workflowStepExecutions = ctx.workflowStepExecutions;
  });

  tearDown(() async {
    await ctx.tearDown(workerDispose: worker.dispose);
  });

  Future<void> seedWorkflowExecution(
    String taskId, {
    String? agentExecutionId,
    required String workflowRunId,
    String stepId = 'plan',
    String stepType = 'coding',
    Map<String, dynamic>? git,
    Map<String, dynamic>? structuredSchema,
    int? mapIterationIndex,
    String? providerSessionId,
  }) => ctx.seedWorkflowExecution(
    taskId,
    agentExecutionId: agentExecutionId,
    workflowRunId: workflowRunId,
    stepId: stepId,
    stepType: stepType,
    git: git,
    structuredSchema: structuredSchema,
    mapIterationIndex: mapIterationIndex,
    providerSessionId: providerSessionId,
  );

  TaskExecutor buildWorkflowExecutor({
    ProjectService? projectService,
    WorktreeManager? worktreeManager,
    SqliteWorkflowRunRepository? workflowRunRepository,
    SqliteWorkflowStepExecutionRepository? workflowStepExecutionRepository,
    String? currentDirectory,
  }) => ctx.harness.buildWorkflowExecutor(
    projectService: projectService,
    worktreeManager: worktreeManager,
    workflowRunRepository: workflowRunRepository ?? workflowRuns,
    workflowStepExecutionRepository: workflowStepExecutionRepository ?? workflowStepExecutions,
    kvService: ctx.kvService,
    currentDirectory: currentDirectory,
  );

  test('keeps project-backed tasks queued while the project is still cloning', () async {
    worker.responseText = 'Done.';
    final projectService = fakeProjectServiceFor(cloningProject());
    final projectExecutor = buildWorkflowExecutor(
      projectService: projectService,
      workflowStepExecutionRepository: workflowStepExecutions,
    );
    addTearDown(projectExecutor.stop);

    await tasks.create(
      id: 'task-project',
      title: 'Project task',
      description: 'Wait for clone.',
      autoStart: true,
      projectId: 'my-app',
    );
    await tasks.create(id: 'task-ready', title: 'Ready task', description: 'Still runnable.', autoStart: true);

    final processed = await projectExecutor.pollOnce();
    await projectExecutor.drain();

    expect(processed, isTrue);
    expect((await tasks.get('task-project'))!.status, TaskStatus.queued);
    expect((await waitForTaskStatus(tasks, 'task-ready', until: const {TaskStatus.review}))?.status, TaskStatus.review);
  });

  test('fails queued project-backed tasks when the project clone has errored', () async {
    final projectService = fakeProjectServiceFor(erroredProject());
    final projectExecutor = buildWorkflowExecutor(
      projectService: projectService,
      workflowStepExecutionRepository: workflowStepExecutions,
    );
    addTearDown(projectExecutor.stop);

    await tasks.create(
      id: 'task-project-failed',
      title: 'Project task',
      description: 'Should fail.',
      autoStart: true,
      projectId: 'my-app',
    );

    final processed = await projectExecutor.pollOnce();
    await projectExecutor.drain();

    expect(processed, isTrue);
    final failed = await waitForTaskStatus(tasks, 'task-project-failed', until: const {TaskStatus.failed});
    expect(failed!.status, TaskStatus.failed);
    expect(failed.configJson['errorSummary'], contains('failed to clone'));
    expect(failed.configJson['errorSummary'], contains('Authentication denied'));
  });

  test('workflow worktree tasks pass configured _baseRef to project freshness and worktree creation', () async {
    worker.responseText = 'Done.';
    final projectService = fakeProjectServiceFor(readyProject());
    final worktreeManager = CapturingWorktreeManager();
    final projectExecutor = buildWorkflowExecutor(
      projectService: projectService,
      worktreeManager: worktreeManager,
      workflowStepExecutionRepository: workflowStepExecutions,
    );
    addTearDown(projectExecutor.stop);

    await tasks.create(
      id: 'task-workflow-branch',
      title: 'Workflow worktree task',
      description: 'Should use workflow branch base ref.',
      autoStart: true,
      agentExecutionId: 'ae-task-workflow-branch',
      projectId: 'my-app',
      workflowRunId: 'run-123',
      configJson: const {'_baseRef': 'release/0.16', 'needsWorktree': true},
    );
    await seedWorkflowExecution(
      'task-workflow-branch',
      agentExecutionId: 'ae-task-workflow-branch',
      workflowRunId: 'run-123',
      stepType: 'coding',
    );

    final processed = await projectExecutor.pollOnce();
    await projectExecutor.drain();

    expect(processed, isTrue);
    final ensureFreshCall = projectService.ensureFreshCalls.single;
    expect(ensureFreshCall.ref, 'release/0.16');
    expect(ensureFreshCall.strict, isTrue);
    expect(worktreeManager.lastBaseRef, 'release/0.16');
  });

  test('workflow local worktree task defaults _baseRef to current symbolic HEAD branch', () async {
    worker.responseText = 'Done.';

    final localRepo = await initGitRepo(branch: 'develop', prefix: 'task_executor_local_repo_');
    addTearDown(() {
      if (localRepo.existsSync()) localRepo.deleteSync(recursive: true);
    });

    final projectService = FakeProjectService(
      projects: const [],
      localProject: Project(
        id: '_local',
        name: 'local',
        remoteUrl: '',
        localPath: localRepo.path,
        defaultBranch: 'main',
        status: ProjectStatus.ready,
        createdAt: DateTime.parse('2026-03-10T09:00:00Z'),
      ),
      defaultProjectId: '_local',
    );
    final worktreeManager = CapturingWorktreeManager();
    final projectExecutor = buildWorkflowExecutor(
      projectService: projectService,
      worktreeManager: worktreeManager,
      workflowStepExecutionRepository: workflowStepExecutions,
    );
    addTearDown(projectExecutor.stop);

    await tasks.create(
      id: 'task-workflow-local-branch',
      title: 'Workflow local worktree task',
      description: 'Should derive branch from local symbolic HEAD.',
      autoStart: true,
      agentExecutionId: 'ae-task-workflow-local-branch',
      workflowRunId: 'run-local',
      projectId: '_local',
      configJson: const {'needsWorktree': true},
    );
    await seedWorkflowExecution(
      'task-workflow-local-branch',
      agentExecutionId: 'ae-task-workflow-local-branch',
      workflowRunId: 'run-local',
      stepType: 'coding',
    );

    final processed = await projectExecutor.pollOnce();
    await projectExecutor.drain();

    expect(processed, isTrue);
    final ensureFreshCall = projectService.ensureFreshCalls.single;
    expect(ensureFreshCall.ref, 'develop');
    expect(ensureFreshCall.strict, isTrue);
    expect(worktreeManager.lastBaseRef, 'develop');
  });

  test('shared workflow tasks attach to the workflow-owned branch and worktree', () async {
    worker.responseText = 'Done.';
    final projectService = fakeProjectServiceFor(readyProject());
    final worktreeManager = CapturingWorktreeManager();
    final projectExecutor = buildWorkflowExecutor(
      projectService: projectService,
      worktreeManager: worktreeManager,
      workflowStepExecutionRepository: workflowStepExecutions,
    );
    addTearDown(projectExecutor.stop);

    const integrationBranch = 'dartclaw/workflow/run123/integration';
    await tasks.create(
      id: 'task-shared-1',
      title: 'Shared workflow step',
      description: 'Should attach to workflow-owned branch.',
      autoStart: true,
      agentExecutionId: 'ae-task-shared-1',
      projectId: 'my-app',
      workflowRunId: 'run-123',
      configJson: const {'_baseRef': integrationBranch, 'needsWorktree': true},
    );
    await seedWorkflowExecution(
      'task-shared-1',
      agentExecutionId: 'ae-task-shared-1',
      workflowRunId: 'run-123',
      git: const {'worktree': 'shared'},
    );

    await projectExecutor.pollOnce();
    await projectExecutor.drain();

    final first = await tasks.get('task-shared-1');
    expect(worktreeManager.lastCreateBranch, isFalse);
    expect(worktreeManager.createCallCount, 1);
    expect(first?.worktreeJson?['branch'], integrationBranch);

    await tasks.create(
      id: 'task-shared-2',
      title: 'Shared workflow step 2',
      description: 'Must reuse same workflow worktree.',
      autoStart: true,
      agentExecutionId: 'ae-task-shared-2',
      projectId: 'my-app',
      workflowRunId: 'run-123',
      configJson: const {'_baseRef': integrationBranch, 'needsWorktree': true},
    );
    await seedWorkflowExecution(
      'task-shared-2',
      agentExecutionId: 'ae-task-shared-2',
      workflowRunId: 'run-123',
      git: const {'worktree': 'shared'},
    );
    await projectExecutor.pollOnce();
    await projectExecutor.drain();
    final second = await tasks.get('task-shared-2');
    expect(worktreeManager.createCallCount, 1, reason: 'shared workflow must reuse the same workflow worktree');
    expect(second?.worktreeJson?['path'], first?.worktreeJson?['path']);
    expect(second?.worktreeJson?['branch'], integrationBranch);
  });

  test('shared workflow worktree binding persists on the workflow run', () async {
    worker.responseText = 'Done.';
    final worktreeManager = CapturingWorktreeManager();
    final projectExecutor = buildWorkflowExecutor(
      worktreeManager: worktreeManager,
      workflowRunRepository: workflowRuns,
      workflowStepExecutionRepository: workflowStepExecutions,
    );
    addTearDown(projectExecutor.stop);

    const workflowRunId = 'run-binding';
    await tasks.create(
      id: 'task-shared-binding',
      title: 'Shared workflow step',
      description: 'Persists its shared worktree binding.',
      autoStart: true,
      workflowRunId: workflowRunId,
      agentExecutionId: 'ae-task-shared-binding',
      configJson: const {'_baseRef': 'dartclaw/workflow/runbinding/integration', 'needsWorktree': true},
    );
    await seedWorkflowExecution(
      'task-shared-binding',
      workflowRunId: workflowRunId,
      agentExecutionId: 'ae-task-shared-binding',
      git: const {'worktree': 'shared'},
    );

    await projectExecutor.pollOnce();
    await projectExecutor.drain();

    final binding = await workflowRuns.getWorktreeBinding(workflowRunId);
    expect(binding, isNotNull);
    expect(binding?.key, workflowRunId);
    expect(binding?.path, '/tmp/worktrees/wf-6032d6adb94f37fe');
    expect(binding?.branch, 'dartclaw/workflow/runbinding/integration');
    expect(binding?.workflowRunId, workflowRunId);
  });

  test('hydrated shared workflow worktree binding reuses the persisted worktree without create()', () async {
    worker.responseText = 'Done.';
    final worktreeManager = CapturingWorktreeManager();
    final projectExecutor = buildWorkflowExecutor(
      worktreeManager: worktreeManager,
      workflowRunRepository: workflowRuns,
      workflowStepExecutionRepository: workflowStepExecutions,
    );
    addTearDown(projectExecutor.stop);

    const workflowRunId = 'run-hydrated';
    const binding = WorkflowWorktreeBinding(
      key: workflowRunId,
      path: '/tmp/worktrees/wf-run-hydrated',
      branch: 'dartclaw/workflow/runhydrated/integration',
      workflowRunId: workflowRunId,
    );
    final now = DateTime.now();
    await workflowRuns.insert(
      WorkflowRun(
        id: workflowRunId,
        definitionName: 'task-executor-test',
        status: WorkflowRunStatus.running,
        startedAt: now,
        updatedAt: now,
        definitionJson: const {'name': 'task-executor-test', 'steps': []},
      ),
    );
    await workflowRuns.setWorktreeBinding(workflowRunId, binding);
    projectExecutor.hydrateWorkflowSharedWorktreeBinding(binding);

    await tasks.create(
      id: 'task-shared-hydrated',
      title: 'Hydrated shared workflow step',
      description: 'Must reuse hydrated binding.',
      autoStart: true,
      workflowRunId: workflowRunId,
      agentExecutionId: 'ae-task-shared-hydrated',
      configJson: const {'_baseRef': 'dartclaw/workflow/runhydrated/integration', 'needsWorktree': true},
    );
    await seedWorkflowExecution(
      'task-shared-hydrated',
      workflowRunId: workflowRunId,
      agentExecutionId: 'ae-task-shared-hydrated',
      git: const {'worktree': 'shared'},
    );

    await projectExecutor.pollOnce();
    await projectExecutor.drain();

    final task = await tasks.get('task-shared-hydrated');
    expect(worktreeManager.createCallCount, 0);
    expect(task?.worktreeJson?['path'], binding.path);
    expect(task?.worktreeJson?['branch'], binding.branch);
  });

  test('inline workflow tasks reuse the project checkout without creating a worktree', () async {
    worker.responseText = 'Done.';

    const integrationBranch = 'dartclaw/workflow/runinline';
    final localRepo = await initGitRepo(
      branch: 'main',
      prefix: 'task_executor_inline_repo_',
      integrationBranch: integrationBranch,
    );
    addTearDown(() {
      if (localRepo.existsSync()) localRepo.deleteSync(recursive: true);
    });

    final projectService = fakeProjectServiceFor(readyProject(remoteUrl: '', localPath: localRepo.path));
    final worktreeManager = CapturingWorktreeManager();
    final projectExecutor = buildWorkflowExecutor(
      projectService: projectService,
      worktreeManager: worktreeManager,
      workflowStepExecutionRepository: workflowStepExecutions,
    );
    addTearDown(projectExecutor.stop);

    await tasks.create(
      id: 'task-inline-workflow',
      title: 'Inline workflow step',
      description: 'Should run on the workflow branch without a separate worktree.',
      autoStart: true,
      agentExecutionId: 'ae-task-inline-workflow',
      projectId: 'my-app',
      workflowRunId: 'run-inline',
      configJson: const {'_baseRef': integrationBranch, 'needsWorktree': true},
    );
    await seedWorkflowExecution(
      'task-inline-workflow',
      agentExecutionId: 'ae-task-inline-workflow',
      workflowRunId: 'run-inline',
      git: const {'worktree': 'inline'},
    );

    await projectExecutor.pollOnce();
    await projectExecutor.drain();

    final task = await tasks.get('task-inline-workflow');
    final head = await Process.run('git', [
      'symbolic-ref',
      '--quiet',
      '--short',
      'HEAD',
    ], workingDirectory: localRepo.path);
    expect(worktreeManager.createCallCount, 0);
    expect(task?.worktreeJson?['path'], localRepo.path);
    expect(task?.worktreeJson?['branch'], integrationBranch);
    expect((head.stdout as String).trim(), integrationBranch);
  });

  test('envelope workflow path outputs resolve against project checkout', () async {
    const integrationBranch = 'dartclaw/workflow/runinline-path';
    final localRepo = await initGitRepo(
      branch: 'main',
      prefix: 'task_executor_inline_path_repo_',
      extraFiles: const {'docs/prd.md': '# PRD\n'},
      integrationBranch: integrationBranch,
    );
    addTearDown(() {
      if (localRepo.existsSync()) localRepo.deleteSync(recursive: true);
    });

    final projectService = fakeProjectServiceFor(readyProject(remoteUrl: '', localPath: localRepo.path));
    final worktreeManager = CapturingWorktreeManager();
    final projectExecutor = buildWorkflowExecutor(
      projectService: projectService,
      worktreeManager: worktreeManager,
      workflowStepExecutionRepository: workflowStepExecutions,
    );
    addTearDown(projectExecutor.stop);

    await tasks.create(
      id: 'task-inline-path',
      title: 'Envelope workflow path step',
      description: 'Emit a path output from the project checkout.',
      autoStart: true,
      agentExecutionId: 'ae-task-inline-path',
      projectId: 'my-app',
      workflowRunId: 'run-inline-path',
      configJson: const {
        '_baseRef': integrationBranch,
        'needsWorktree': true,
        'allowedTools': ['shell', 'file_read'],
        'readOnly': true,
      },
    );
    await seedWorkflowExecution(
      'task-inline-path',
      agentExecutionId: 'ae-task-inline-path',
      workflowRunId: 'run-inline-path',
      git: const {'worktree': 'inline'},
      structuredSchema: const {
        'type': 'object',
        'additionalProperties': false,
        'required': ['outputs', 'step_outcome'],
        'properties': {
          'outputs': {
            'type': 'object',
            'additionalProperties': false,
            'required': ['prd'],
            'properties': {
              'prd': {'type': 'string'},
            },
          },
          'step_outcome': {
            'type': 'object',
            'additionalProperties': false,
            'required': ['outcome', 'reason'],
            'properties': {
              'outcome': {'type': 'string'},
              'reason': {'type': 'string'},
            },
          },
        },
      },
    );

    worker
      ..structuredOutputSupported = true
      ..providerSessionResumeSupported = true
      ..providerSessionId = 'inline-path-session'
      ..structuredOutput = {
        'outputs': {'prd': 'docs/prd.md'},
        'step_outcome': {'outcome': 'succeeded', 'reason': 'ok'},
      };

    await projectExecutor.pollOnce();
    await projectExecutor.drain();

    final task = (await tasks.get('task-inline-path'))!;
    expect(task.status, TaskStatus.review, reason: task.configJson.toString());
    expect((await workflowStepExecutions.getByTaskId('task-inline-path'))?.structuredOutput, isNotNull);
    final extractor = ContextExtractor(
      taskService: tasks,
      messageService: messages,
      dataDir: ctx.tempDir.path,
      workflowStepExecutionRepository: workflowStepExecutions,
    );
    final outputs = await extractor.extract(
      const WorkflowStep(
        id: 'discover-plan-state',
        name: 'Discover Plan State',
        outputs: {'prd': OutputConfig(format: OutputFormat.path)},
      ),
      task,
    );

    expect(worktreeManager.createCallCount, 0);
    expect(task.worktreeJson?['path'], localRepo.path);
    expect(outputs['prd'], 'docs/prd.md');
  });

  test('per-map-item post-map coding step attaches to integration branch, map iteration does not', () async {
    worker.responseText = 'Done.';
    final projectService = fakeProjectServiceFor(readyProject());
    final worktreeManager = CapturingWorktreeManager();
    final projectExecutor = buildWorkflowExecutor(
      projectService: projectService,
      worktreeManager: worktreeManager,
      workflowStepExecutionRepository: workflowStepExecutions,
    );
    addTearDown(projectExecutor.stop);

    const integrationBranch = 'dartclaw/workflow/run456/integration';
    await tasks.create(
      id: 'task-map-iter',
      title: 'Map iteration coding step',
      description: 'Iteration keeps story-isolated branch.',
      autoStart: true,
      agentExecutionId: 'ae-task-map-iter',
      projectId: 'my-app',
      workflowRunId: 'run-456',
      configJson: const {'_baseRef': integrationBranch, 'needsWorktree': true},
    );
    await seedWorkflowExecution(
      'task-map-iter',
      agentExecutionId: 'ae-task-map-iter',
      workflowRunId: 'run-456',
      git: const {'worktree': 'per-map-item'},
      mapIterationIndex: 0,
    );
    await projectExecutor.pollOnce();
    await projectExecutor.drain();
    expect(worktreeManager.lastCreateBranch, isTrue);

    await tasks.create(
      id: 'task-post-map',
      title: 'Post-map remediation',
      description: 'Should attach integration branch.',
      autoStart: true,
      agentExecutionId: 'ae-task-post-map',
      projectId: 'my-app',
      workflowRunId: 'run-456',
      configJson: const {'_baseRef': integrationBranch, 'needsWorktree': true},
    );
    await seedWorkflowExecution(
      'task-post-map',
      agentExecutionId: 'ae-task-post-map',
      workflowRunId: 'run-456',
      git: const {'worktree': 'per-map-item'},
    );
    await projectExecutor.pollOnce();
    await projectExecutor.drain();
    final postMap = await tasks.get('task-post-map');
    expect(worktreeManager.lastCreateBranch, isFalse);
    expect(postMap?.worktreeJson?['branch'], integrationBranch);
  });

  test('per-map-item worktree is prepared with nothing copied in from another project clone', () async {
    worker.responseText = 'Done.';
    final tempRoot = Directory.systemTemp.createTempSync('s07_worktree_');
    addTearDown(() => tempRoot.deleteSync(recursive: true));
    // A second project clone holding the kind of artifact the retired
    // cross-clone mount used to copy into every per-story worktree.
    final otherProject = Directory(p.join(tempRoot.path, 'projects', 'docs-project', 'specs'))
      ..createSync(recursive: true);
    File(p.join(otherProject.path, 's01.md')).writeAsStringSync('# S01 FIS');

    final projectService = fakeProjectServiceFor(readyProject());
    final worktreeManager = MaterializingWorktreeManager(tempRoot.path);
    final projectExecutor = buildWorkflowExecutor(
      projectService: projectService,
      worktreeManager: worktreeManager,
      workflowStepExecutionRepository: workflowStepExecutions,
    );
    addTearDown(projectExecutor.stop);

    await tasks.create(
      id: 'task-story-mount',
      title: 'Story implement',
      description: 'Coding step bound to map item 0.',
      autoStart: true,
      agentExecutionId: 'ae-task-story-mount',
      projectId: 'my-app',
      workflowRunId: 'run-mount',
      configJson: const {'_baseRef': 'dartclaw/workflow/runmount/integration', 'needsWorktree': true},
    );
    await seedWorkflowExecution(
      'task-story-mount',
      agentExecutionId: 'ae-task-story-mount',
      workflowRunId: 'run-mount',
      git: const {'worktree': 'per-map-item'},
      mapIterationIndex: 0,
    );

    await projectExecutor.pollOnce();
    await projectExecutor.drain();

    final task = await tasks.get('task-story-mount');
    expect(task?.status, TaskStatus.review);
    final worktreePath = task?.worktreeJson?['path'] as String?;
    expect(worktreePath, isNotNull, reason: 'the per-map-item worktree must still be created');
    expect(Directory(worktreePath!).existsSync(), isTrue);
    expect(
      Directory(worktreePath).listSync(recursive: true),
      isEmpty,
      reason: 'no file arrives in the worktree from a second project clone',
    );
    expect(File(p.join(otherProject.path, 's01.md')).existsSync(), isTrue);
  });

  test('per-map-item map iteration reuses the same story worktree across coding steps', () async {
    worker.responseText = 'Done.';
    final projectService = fakeProjectServiceFor(readyProject());
    final worktreeManager = CapturingWorktreeManager();
    final projectExecutor = buildWorkflowExecutor(
      projectService: projectService,
      worktreeManager: worktreeManager,
      workflowStepExecutionRepository: workflowStepExecutions,
    );
    addTearDown(projectExecutor.stop);

    const integrationBranch = 'dartclaw/workflow/run999/integration';
    await tasks.create(
      id: 'task-story-implement',
      title: 'Story implement',
      description: 'First coding step for story 0.',
      autoStart: true,
      agentExecutionId: 'ae-task-story-implement',
      projectId: 'my-app',
      workflowRunId: 'run-999',
      configJson: const {'_baseRef': integrationBranch, 'needsWorktree': true},
    );
    await seedWorkflowExecution(
      'task-story-implement',
      agentExecutionId: 'ae-task-story-implement',
      workflowRunId: 'run-999',
      git: const {'worktree': 'per-map-item'},
      mapIterationIndex: 0,
    );

    await projectExecutor.pollOnce();
    await projectExecutor.drain();

    final implement = await tasks.get('task-story-implement');
    expect(worktreeManager.createCallCount, 1);
    expect(worktreeManager.lastCreateBranch, isTrue);

    await tasks.create(
      id: 'task-story-verify',
      title: 'Story verify',
      description: 'Second coding step for story 0.',
      autoStart: true,
      agentExecutionId: 'ae-task-story-verify',
      projectId: 'my-app',
      workflowRunId: 'run-999',
      configJson: const {'_baseRef': integrationBranch, 'needsWorktree': true},
    );
    await seedWorkflowExecution(
      'task-story-verify',
      agentExecutionId: 'ae-task-story-verify',
      workflowRunId: 'run-999',
      git: const {'worktree': 'per-map-item'},
      mapIterationIndex: 0,
    );

    await projectExecutor.pollOnce();
    await projectExecutor.drain();

    final verify = await tasks.get('task-story-verify');
    expect(worktreeManager.createCallCount, 1, reason: 'story follow-up steps should reuse the same worktree');
    expect(verify?.worktreeJson?['path'], implement?.worktreeJson?['path']);
    expect(verify?.worktreeJson?['branch'], implement?.worktreeJson?['branch']);
  });

  test('per-map-item map iteration reuses the same story worktree for analysis steps that request one', () async {
    worker.responseText = 'Done.';
    final projectService = fakeProjectServiceFor(readyProject());
    final worktreeManager = CapturingWorktreeManager();
    final projectExecutor = buildWorkflowExecutor(
      projectService: projectService,
      worktreeManager: worktreeManager,
      workflowStepExecutionRepository: workflowStepExecutions,
    );
    addTearDown(projectExecutor.stop);

    const integrationBranch = 'dartclaw/workflow/run1000/integration';
    await tasks.create(
      id: 'task-story-implement-analysis-prelude',
      title: 'Story implement',
      description: 'First coding step for story 0.',
      autoStart: true,
      agentExecutionId: 'ae-task-story-implement-analysis-prelude',
      projectId: 'my-app',
      workflowRunId: 'run-1000',
      configJson: const {'_baseRef': integrationBranch, 'needsWorktree': true},
    );
    await seedWorkflowExecution(
      'task-story-implement-analysis-prelude',
      agentExecutionId: 'ae-task-story-implement-analysis-prelude',
      workflowRunId: 'run-1000',
      git: const {'worktree': 'per-map-item'},
      mapIterationIndex: 0,
    );

    await projectExecutor.pollOnce();
    await projectExecutor.drain();
    final implement = await tasks.get('task-story-implement-analysis-prelude');
    expect(worktreeManager.createCallCount, 1);

    await tasks.create(
      id: 'task-story-review-analysis',
      title: 'Story review',
      description: 'Analysis step that still needs the story worktree.',
      autoStart: true,
      agentExecutionId: 'ae-task-story-review-analysis',
      projectId: 'my-app',
      workflowRunId: 'run-1000',
      configJson: const {'_baseRef': integrationBranch, 'needsWorktree': true, 'readOnly': true},
    );
    await seedWorkflowExecution(
      'task-story-review-analysis',
      agentExecutionId: 'ae-task-story-review-analysis',
      workflowRunId: 'run-1000',
      stepType: 'analysis',
      git: const {'worktree': 'per-map-item'},
      mapIterationIndex: 0,
    );

    await projectExecutor.pollOnce();
    await projectExecutor.drain();

    final review = await tasks.get('task-story-review-analysis');
    expect(worktreeManager.createCallCount, 1, reason: 'analysis follow-up should reuse the same worktree');
    expect(review?.worktreeJson?['path'], implement?.worktreeJson?['path']);
    expect(review?.worktreeJson?['branch'], implement?.worktreeJson?['branch']);
  });

  test('workflow read-only tasks skip strict freshness fetch for local workflow-owned refs', () async {
    worker.responseText = 'Done.';
    final projectService = fakeProjectServiceFor(readyProject());
    final projectExecutor = buildWorkflowExecutor(
      projectService: projectService,
      workflowStepExecutionRepository: workflowStepExecutions,
    );
    addTearDown(projectExecutor.stop);

    const integrationBranch = 'dartclaw/workflow/run789/integration';
    await tasks.create(
      id: 'task-readonly-workflow-ref',
      title: 'Workflow spec step',
      description: 'Should trust the workflow-owned local ref.',
      autoStart: true,
      agentExecutionId: 'ae-task-readonly-workflow-ref',
      projectId: 'my-app',
      workflowRunId: 'run-789',
      configJson: const {'readOnly': true, '_baseRef': integrationBranch},
    );
    await seedWorkflowExecution(
      'task-readonly-workflow-ref',
      agentExecutionId: 'ae-task-readonly-workflow-ref',
      workflowRunId: 'run-789',
      git: const {'worktree': 'per-map-item'},
      mapIterationIndex: 0,
    );

    final processed = await projectExecutor.pollOnce();
    await projectExecutor.drain();

    expect(processed, isTrue);
    expect(projectService.ensureFreshCalls, isEmpty);
    expect(
      (await waitForTaskStatus(tasks, 'task-readonly-workflow-ref', until: const {TaskStatus.review}))?.status,
      TaskStatus.review,
    );
  });

  test('read-only project task fails when the repo becomes dirty during the turn', () async {
    worker.responseText = 'Done.';

    final projectDir = await initGitRepo(branch: 'main', prefix: 'task_executor_readonly_repo_');
    addTearDown(() {
      if (projectDir.existsSync()) {
        projectDir.deleteSync(recursive: true);
      }
    });

    worker.onTurnWithDirectory = (_, directory) {
      final repoPath = directory ?? projectDir.path;
      final notesDir = Directory(p.join(repoPath, 'notes'))..createSync(recursive: true);
      File(p.join(notesDir.path, 'leak.md')).writeAsStringSync('# leaked\n\n- mutation\n');
    };

    final projectService = fakeProjectServiceFor(readyProject(localPath: projectDir.path));
    final projectExecutor = buildWorkflowExecutor(projectService: projectService);
    addTearDown(projectExecutor.stop);

    await tasks.create(
      id: 'task-readonly-dirty',
      title: 'Read-only task',
      description: 'Must not mutate the repo.',
      autoStart: true,
      projectId: 'my-app',
      configJson: const {'readOnly': true},
    );

    final processed = await projectExecutor.pollOnce();
    await projectExecutor.drain();

    expect(processed, isTrue);
    final failed = await waitForTaskStatus(tasks, 'task-readonly-dirty', until: const {TaskStatus.failed});
    expect(failed!.status, TaskStatus.failed);
    expect(failed.configJson['errorSummary'], contains('Read-only task modified project files'));
    expect(failed.configJson['errorSummary'], contains('notes/leak.md'));
  });

  test('read-only worktree task ignores pre-existing dirt in its inherited worktree', () async {
    final worktreeDir = Directory.systemTemp.createTempSync('task_executor_readonly_worktree_');
    final projectDir = await initGitRepo(branch: 'main', prefix: 'task_executor_readonly_project_');
    addTearDown(() {
      if (projectDir.existsSync()) {
        projectDir.deleteSync(recursive: true);
      }
      if (worktreeDir.existsSync()) {
        worktreeDir.deleteSync(recursive: true);
      }
    });

    final cloneResult = await Process.run('git', ['clone', projectDir.path, worktreeDir.path]);
    expect(cloneResult.exitCode, 0, reason: cloneResult.stderr.toString());

    File(p.join(worktreeDir.path, 'plan.md')).writeAsStringSync('# Plan\n\n- [x] Story 1\n');
    final notesDir = Directory(p.join(worktreeDir.path, 'notes'))..createSync(recursive: true);
    File(p.join(notesDir.path, 'artifact.md')).writeAsStringSync('# Artifact\n\n- mutation from implement\n');

    final projectService = fakeProjectServiceFor(readyProject(localPath: projectDir.path));
    final projectExecutor = buildWorkflowExecutor(
      projectService: projectService,
      worktreeManager: StaticPathWorktreeManager(worktreeDir.path),
      workflowStepExecutionRepository: workflowStepExecutions,
    );
    addTearDown(projectExecutor.stop);

    await tasks.create(
      id: 'task-readonly-inherited-worktree',
      title: 'Read-only worktree task',
      description: 'Should treat inherited worktree dirt as baseline, not a new mutation.',
      autoStart: true,
      agentExecutionId: 'ae-task-readonly-inherited-worktree',
      projectId: 'my-app',
      workflowRunId: 'wf-readonly-inherited-worktree',
      configJson: const {'readOnly': true, '_baseRef': 'main', 'needsWorktree': true},
    );
    await seedWorkflowExecution(
      'task-readonly-inherited-worktree',
      agentExecutionId: 'ae-task-readonly-inherited-worktree',
      workflowRunId: 'wf-readonly-inherited-worktree',
      git: const {'worktree': 'per-map-item'},
      mapIterationIndex: 0,
    );

    final processed = await projectExecutor.pollOnce();
    await projectExecutor.drain();

    expect(processed, isTrue);
    final updated = await waitForTaskStatus(
      tasks,
      'task-readonly-inherited-worktree',
      until: const {TaskStatus.review},
    );
    expect(updated, isNotNull);
    expect(updated!.status, TaskStatus.review);
    expect(updated.configJson['errorSummary'], isNull);
  });

  test('workflow required input path preflight fails before a harness turn starts', () async {
    final worktreeDir = Directory.systemTemp.createTempSync('dartclaw_missing_spec_worktree_');
    addTearDown(() {
      if (worktreeDir.existsSync()) worktreeDir.deleteSync(recursive: true);
    });
    final turnsBefore = worker.turnCallCount;
    final projectExecutor = buildWorkflowExecutor(
      worktreeManager: StaticPathWorktreeManager(worktreeDir.path),
      workflowRunRepository: workflowRuns,
      workflowStepExecutionRepository: workflowStepExecutions,
    );
    addTearDown(projectExecutor.stop);

    await tasks.create(
      id: 'task-missing-required-input',
      title: 'Implement Story',
      description: 'Implement fis/s01.md',
      autoStart: true,
      agentExecutionId: 'ae-task-missing-required-input',
      workflowRunId: 'wf-missing-required-input',
      configJson: const {'needsWorktree': true, 'requiredInputPath': 'fis/s01.md'},
    );
    await seedWorkflowExecution(
      'task-missing-required-input',
      agentExecutionId: 'ae-task-missing-required-input',
      workflowRunId: 'wf-missing-required-input',
      stepId: 'implement',
      git: const {'worktree': 'per-map-item'},
      mapIterationIndex: 0,
    );

    final processed = await projectExecutor.pollOnce();
    await projectExecutor.drain();

    expect(processed, isTrue);
    expect(worker.turnCallCount, turnsBefore);
    final updated = await waitForTaskStatus(tasks, 'task-missing-required-input', until: const {TaskStatus.failed});
    expect(updated?.status, TaskStatus.failed);
    expect(updated?.configJson['errorSummary'], contains('required input path "fis/s01.md" is missing'));
  });

  test('standalone required input path preflight resolves against the live checkout cwd', () async {
    // Standalone/inline runs register no project and create no per-story
    // worktree, so the required artifact lives in the current working directory
    // (the live checkout) — the same dir the agent runs in. Regression: the
    // preflight must not reject a spec that is present in cwd.
    final cwd = ctx.tempDir.path;
    final specDir = Directory(p.join(cwd, '.dart_tool'))..createSync(recursive: true);
    addTearDown(() {
      if (specDir.existsSync()) specDir.deleteSync(recursive: true);
    });
    final specFile = File(p.join(specDir.path, 's01.md'))..writeAsStringSync('# FIS');
    final relativeSpecPath = p.relative(specFile.path, from: cwd);

    // No projectService and no worktreeManager → project and worktree both
    // resolve to null, exactly as in a standalone/inline run.
    final standaloneExecutor = buildWorkflowExecutor(
      workflowRunRepository: workflowRuns,
      workflowStepExecutionRepository: workflowStepExecutions,
      currentDirectory: cwd,
    );
    addTearDown(standaloneExecutor.stop);

    await tasks.create(
      id: 'task-standalone-required-input',
      title: 'Implement Story',
      description: 'Implement $relativeSpecPath',
      autoStart: true,
      agentExecutionId: 'ae-task-standalone-required-input',
      workflowRunId: 'wf-standalone-required-input',
      provider: 'claude',
      configJson: {'needsWorktree': true, 'requiredInputPath': relativeSpecPath},
    );
    await seedWorkflowExecution(
      'task-standalone-required-input',
      agentExecutionId: 'ae-task-standalone-required-input',
      workflowRunId: 'wf-standalone-required-input',
      stepId: 'implement',
      git: const {'worktree': 'inline'},
      mapIterationIndex: 0,
    );

    final processed = await standaloneExecutor.pollOnce();
    await standaloneExecutor.drain();
    final updated = await waitForTaskStatus(tasks, 'task-standalone-required-input');

    expect(processed, isTrue);
    expect(
      worker.turnCallCount,
      greaterThan(0),
      reason: 'preflight should pass when the spec exists in the live checkout cwd',
    );
    expect(updated?.status, isNot(TaskStatus.failed));
    expect(updated?.configJson['errorSummary'], isNot(contains('artifact-propagation')));
  });
}
