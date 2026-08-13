import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_server/src/task/workflow_cli_runner.dart' show RootProcessTerminationObserver;
import 'package:dartclaw_server/src/turn_manager.dart' show TurnManager;
import 'package:dartclaw_server/src/turn_runner.dart' show TurnRunner;
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show WorkflowTaskConfig, executionEnvelopeMarkerKey, executionEnvelopeVersion;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'task_executor_test_support.dart';
import 'workflow_cli_runner_test_support.dart'
    show FakeContainerExecutor, fakeContainerAuthorities, testBridgedMcpTools;

/// Strict execution-envelope schema (top-level `outputs` → envelope path) with a
/// single declared narrative output `summary` plus the engine-owned `step_outcome`.
final _summaryEnvelopeSchema = <String, dynamic>{
  'type': 'object',
  'additionalProperties': false,
  'required': ['outputs', 'step_outcome'],
  'properties': {
    'outputs': {
      'type': 'object',
      'additionalProperties': false,
      'required': ['summary'],
      'properties': {
        'summary': {'type': 'string'},
      },
    },
    'step_outcome': {
      'type': 'object',
      'additionalProperties': false,
      'required': ['outcome', 'reason'],
      'properties': {
        'outcome': {
          'type': 'string',
          'enum': ['succeeded', 'failed', 'needsInput'],
        },
        'reason': {'type': 'string'},
      },
    },
  },
};

/// The `structured_output` a finalizer turn returns for [_summaryEnvelopeSchema].
final _finalizerEnvelopeOutput = <String, dynamic>{
  'outputs': {'summary': 'final'},
  'step_outcome': {'outcome': 'succeeded', 'reason': 'ok'},
};

void main() {
  late FakeTaskWorker worker;
  late WorkflowTaskExecutorTestContext ctx;
  late String workspaceDir;
  late SessionService sessions;
  late MessageService messages;
  late TaskService tasks;
  late KvService kvService;
  late SqliteWorkflowStepExecutionRepository workflowStepExecutions;
  late TurnManager workflowTurns;

  setUp(() async {
    worker = FakeTaskWorker();
    ctx = WorkflowTaskExecutorTestContext(worker);
    await ctx.setUp();
    workspaceDir = ctx.workspaceDir;
    sessions = ctx.sessions;
    messages = ctx.messages;
    tasks = ctx.tasks;
    kvService = ctx.kvService;
    workflowStepExecutions = ctx.workflowStepExecutions;
    final primary = ctx.turns.executions.primary!;
    workflowTurns = TurnManager.fromCoordinator(
      coordinator: ExecutionCoordinator(
        providerCapacities: const {'claude': 1, 'codex': 1},
        primary: primary,
        admitExecution: (request) => primary.admitTurn(request.sessionId, isHumanInput: request.isHumanInput),
        releaseAdmission: primary.releaseAdmission,
        createWorker: (_) => throw StateError('Workflow one-shot tests must not create reusable workers'),
      ),
    );
  });

  tearDown(() async {
    await ctx.tearDown(workerDispose: worker.dispose);
  });

  TaskExecutor buildExecutor({
    ProjectService? projectService,
    WorkflowCliRunner? workflowCliRunner,
    TaskEventRecorder? eventRecorder,
    TaskExecutorLimits limits = const TaskExecutorLimits(),
    ExecutionPolicyResolver? policyResolver,
  }) => ctx.harness.buildWorkflowExecutor(
    turnManager: workflowTurns,
    projectService: projectService,
    workflowCliRunner: workflowCliRunner,
    workflowRunRepository: ctx.workflowRuns,
    workflowStepExecutionRepository: workflowStepExecutions,
    eventRecorder: eventRecorder,
    kvService: kvService,
    limits: limits,
    policyResolver: policyResolver,
  );

  Future<void> seedWorkflowExecution(
    String taskId, {
    String? agentExecutionId,
    required String workflowRunId,
    String stepId = 'plan',
    Map<String, dynamic>? structuredSchema,
    List<String>? followUpPrompts,
    String? providerSessionId,
  }) => ctx.seedWorkflowExecution(
    taskId,
    agentExecutionId: agentExecutionId,
    workflowRunId: workflowRunId,
    stepId: stepId,
    structuredSchema: structuredSchema,
    followUpPrompts: followUpPrompts,
    providerSessionId: providerSessionId,
  );

  test('workflow oneshot mode executes prompt chain and stores structured payload', () async {
    final cliRunner = echoCliRunner(
      (args) => args.contains('--json-schema')
          ? jsonEncode({
              'session_id': 'cli-session-1',
              'input_tokens': 600,
              'output_tokens': 400,
              'cache_read_tokens': 300,
              'structured_output': {
                'verdict': {
                  'pass': true,
                  'findings_count': 0,
                  'findings': <Map<String, dynamic>>[],
                  'summary': 'Clean',
                },
              },
            })
          : jsonEncode({
              'session_id': 'cli-session-1',
              'input_tokens': 200,
              'output_tokens': 50,
              'cache_read_tokens': 50,
              'result': 'Working...',
            }),
    );
    final oneShotExecutor = buildExecutor(workflowCliRunner: cliRunner);
    addTearDown(oneShotExecutor.stop);

    await tasks.create(
      id: 'task-oneshot',
      title: 'One-shot workflow step',
      description: 'Run the workflow step.',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-task-oneshot',
      workflowRunId: 'wf-1',
      provider: 'claude',
    );
    await seedWorkflowExecution(
      'task-oneshot',
      agentExecutionId: 'ae-task-oneshot',
      workflowRunId: 'wf-1',
      followUpPrompts: ['Follow up'],
      structuredSchema: const {
        'type': 'object',
        'additionalProperties': false,
        'required': ['verdict'],
        'properties': {
          'verdict': {
            'type': 'object',
            'additionalProperties': false,
            'required': ['pass', 'findings_count', 'findings', 'summary'],
            'properties': {
              'pass': {'type': 'boolean'},
              'findings_count': {'type': 'integer'},
              'findings': {
                'type': 'array',
                'items': {'type': 'object', 'additionalProperties': false},
              },
              'summary': {'type': 'string'},
            },
          },
        },
      },
    );

    await oneShotExecutor.pollOnce();
    await oneShotExecutor.drain();

    final updated = await waitForTaskStatus(tasks, 'task-oneshot', until: const {TaskStatus.review});
    expect(updated?.status, TaskStatus.review);
    expect(updated?.configJson['_workflowInputTokensNew'], 600);
    expect(updated?.configJson['_workflowCacheReadTokens'], 400);
    expect(updated?.configJson['_workflowOutputTokens'], 500);
    expect((await workflowStepExecutions.getByTaskId('task-oneshot'))?.providerSessionId, 'cli-session-1');
    expect((await workflowStepExecutions.getByTaskId('task-oneshot'))?.stepTokenBreakdown, {
      'inputTokensNew': 600,
      'cacheReadTokens': 400,
      'outputTokens': 500,
    });
    expect((await workflowStepExecutions.getByTaskId('task-oneshot'))?.structuredOutput, isA<Map<Object?, Object?>>());
  });

  test('unreported root termination across prompt turns quarantines capacity and blocks the next task', () async {
    final provider = _ConfirmationSequenceCliProvider([true, null]);
    final cliRunner = WorkflowCliRunner(
      providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')},
      providerImpls: {'claude': provider},
    );
    final behavior = BehaviorFileService(workspaceDir: workspaceDir);
    final primaryRunner = TurnRunner(harness: worker, messages: messages, behavior: behavior, sessions: sessions);
    var workerCreations = 0;
    final executions = ExecutionCoordinator(
      providerCapacities: const {'claude': 1},
      primary: primaryRunner,
      createWorker: (_) async {
        workerCreations++;
        throw StateError('capacity-only workflow must not create a reusable worker');
      },
    );
    final turns = TurnManager.fromCoordinator(coordinator: executions);
    final oneShotExecutor = ctx.harness.buildWorkflowExecutor(
      turnManager: turns,
      workflowCliRunner: cliRunner,
      workflowRunRepository: ctx.workflowRuns,
      workflowStepExecutionRepository: workflowStepExecutions,
      limits: const TaskExecutorLimits(defaultProviderId: 'claude'),
    );
    addTearDown(oneShotExecutor.stop);

    await tasks.create(
      id: 'task-unconfirmed-root',
      title: 'Unconfirmed root termination',
      description: 'Quarantine capacity after any unconfirmed CLI turn.',
      type: TaskType.research,
      provider: 'claude',
      autoStart: true,
      agentExecutionId: 'ae-task-unconfirmed-root',
      workflowRunId: 'wf-unconfirmed-root',
    );
    await seedWorkflowExecution(
      'task-unconfirmed-root',
      agentExecutionId: 'ae-task-unconfirmed-root',
      workflowRunId: 'wf-unconfirmed-root',
      followUpPrompts: ['second turn'],
    );

    await oneShotExecutor.pollOnce();
    await oneShotExecutor.drain();

    expect((await tasks.get('task-unconfirmed-root'))!.status, TaskStatus.review);
    expect(provider.runCount, 2);
    expect(executions.snapshot.providers['claude']?.effective, 0);
    expect(executions.snapshot.providers['claude']?.quarantined, 1);
    expect(workerCreations, 0);

    await tasks.create(
      id: 'task-after-quarantine',
      title: 'Blocked after quarantine',
      description: 'No replacement CLI root may start in the quarantined slot.',
      type: TaskType.research,
      provider: 'claude',
      autoStart: true,
      agentExecutionId: 'ae-task-after-quarantine',
      workflowRunId: 'wf-unconfirmed-root',
    );
    await seedWorkflowExecution(
      'task-after-quarantine',
      agentExecutionId: 'ae-task-after-quarantine',
      workflowRunId: 'wf-unconfirmed-root',
    );

    expect(await oneShotExecutor.pollOnce(), isFalse);
    expect((await tasks.get('task-after-quarantine'))!.status, TaskStatus.queued);
    expect(provider.runCount, 2);
    expect(workerCreations, 0);
  });

  test(
    'one-shot spawn carries the step-artifacts env, merged over merge-resolve env, and pre-creates the dir',
    () async {
      Map<String, String>? capturedEnv;
      final cliRunner = echoCliRunner(
        (_) => jsonEncode({'session_id': 'cli-session-env', 'result': 'Done.'}),
        onEnv: (env) => capturedEnv = env,
      );
      final oneShotExecutor = buildExecutor(workflowCliRunner: cliRunner);
      addTearDown(oneShotExecutor.stop);

      final stepArtifactsDir = p.join(ctx.tempDir.path, 'runs', 'wf-env', 'runtime-artifacts', 'steps', 'review');
      expect(Directory(stepArtifactsDir).existsSync(), isFalse, reason: 'precondition: host must create the dir');
      await tasks.create(
        id: 'task-step-artifacts-env',
        title: 'Review step',
        description: 'Review --output-dir "\$DARTCLAW_STEP_ARTIFACTS_DIR"',
        type: TaskType.coding,
        autoStart: true,
        agentExecutionId: 'ae-step-artifacts-env',
        workflowRunId: 'wf-env',
        provider: 'claude',
        configJson: {
          WorkflowTaskConfig.mergeResolveEnv: const {'MERGE_KEY': 'merge-val'},
          WorkflowTaskConfig.stepArtifactsEnv: {'DARTCLAW_STEP_ARTIFACTS_DIR': stepArtifactsDir},
        },
      );
      await seedWorkflowExecution(
        'task-step-artifacts-env',
        agentExecutionId: 'ae-step-artifacts-env',
        workflowRunId: 'wf-env',
      );

      await oneShotExecutor.pollOnce();
      await oneShotExecutor.drain();

      expect(capturedEnv, isNotNull);
      // Host-computed step artifacts dir reaches the spawn env, scoped to this task.
      expect(capturedEnv!['DARTCLAW_STEP_ARTIFACTS_DIR'], stepArtifactsDir);
      // Step-artifacts env merges over, not replacing, the merge-resolve entries.
      expect(capturedEnv!['MERGE_KEY'], 'merge-val');
      // The host owns dir creation — it exists before the agent's first turn.
      expect(Directory(stepArtifactsDir).existsSync(), isTrue);
    },
  );

  test('a containerized step gets its production step-artifacts dir mounted, so it spawns at all', () async {
    // Production shape: `<dataDir>/workflows/runs/<runId>/…`, a sibling of the
    // workspace and inside no profile's mount set until the authority mounts it.
    final dataDir = p.join(ctx.tempDir.path, 'data');
    final stepArtifactsDir = p.join(
      dataDir,
      'workflows',
      'runs',
      'wf-container',
      'runtime-artifacts',
      'steps',
      'review',
    );
    final container = FakeContainerExecutor(
      hostRoot: Directory.current.path,
      containerRoot: '/project',
      stdout: jsonEncode({'type': 'result', 'session_id': 'cli-session-container', 'result': 'Done.'}),
    );
    final mountedArtifactsDirs = <String?>[];
    final cliRunner = WorkflowCliRunner(
      providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')},
      containerAuthorities: fakeContainerAuthorities(container, mountedArtifactsDirs: mountedArtifactsDirs),
      bridgedMcpToolsResolver: testBridgedMcpTools,
    );
    final oneShotExecutor = buildExecutor(
      workflowCliRunner: cliRunner,
      policyResolver: ExecutionPolicyResolver(
        config: DartclawConfig.defaults().copyWith(container: const ContainerConfig(enabled: true)),
        availableContainerProfiles: const {'workspace', 'restricted'},
      ),
    );
    addTearDown(oneShotExecutor.stop);

    await tasks.create(
      id: 'task-container-artifacts',
      title: 'Review step',
      description: 'Review --output-dir "\$DARTCLAW_STEP_ARTIFACTS_DIR"',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-container-artifacts',
      workflowRunId: 'wf-container',
      provider: 'claude',
      configJson: {
        WorkflowTaskConfig.stepArtifactsEnv: {'DARTCLAW_STEP_ARTIFACTS_DIR': stepArtifactsDir},
      },
    );
    await seedWorkflowExecution(
      'task-container-artifacts',
      agentExecutionId: 'ae-container-artifacts',
      workflowRunId: 'wf-container',
    );

    await oneShotExecutor.pollOnce();
    await oneShotExecutor.drain();

    expect(mountedArtifactsDirs, [stepArtifactsDir]);
    expect(container.lastEnv!['DARTCLAW_STEP_ARTIFACTS_DIR'], containerArtifactsPath);
    expect(
      (await tasks.get('task-container-artifacts'))!.status,
      isNot(TaskStatus.failed),
      reason: 'an unmountable artifacts dir used to throw before the spawn',
    );
  });

  test('workflow oneshot cancellation records cancelled without taskError', () async {
    final eventDb = openTaskDbInMemory();
    addTearDown(eventDb.close);
    final eventService = TaskEventService(eventDb);
    final recorder = TaskEventRecorder(eventService: eventService);
    final cliRunner = WorkflowCliRunner(
      providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')},
      providerImpls: const {'claude': _CancellingCliProvider()},
    );
    final oneShotExecutor = buildExecutor(workflowCliRunner: cliRunner, eventRecorder: recorder);
    addTearDown(oneShotExecutor.stop);

    await tasks.create(
      id: 'task-oneshot-cancelled',
      title: 'One-shot cancellation',
      description: 'Teardown cancellation should be resumable.',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-task-oneshot-cancelled',
      workflowRunId: 'wf-cancelled',
      provider: 'claude',
    );
    await seedWorkflowExecution(
      'task-oneshot-cancelled',
      agentExecutionId: 'ae-task-oneshot-cancelled',
      workflowRunId: 'wf-cancelled',
    );

    await oneShotExecutor.pollOnce();
    await oneShotExecutor.drain();

    final updated = await waitForTaskStatus(tasks, 'task-oneshot-cancelled', until: const {TaskStatus.cancelled});
    expect(updated?.status, TaskStatus.cancelled);
    final events = eventService.listForTask('task-oneshot-cancelled');
    expect(events.any((event) => event.kind == TaskEventKind.taskError), isFalse);
  });

  test('workflow oneshot genuine failure records failed with taskError', () async {
    final eventDb = openTaskDbInMemory();
    addTearDown(eventDb.close);
    final eventService = TaskEventService(eventDb);
    final recorder = TaskEventRecorder(eventService: eventService);
    final cliRunner = WorkflowCliRunner(
      providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')},
      providerImpls: const {'claude': _FailingCliProvider()},
    );
    final oneShotExecutor = buildExecutor(workflowCliRunner: cliRunner, eventRecorder: recorder);
    addTearDown(oneShotExecutor.stop);

    await tasks.create(
      id: 'task-oneshot-failed',
      title: 'One-shot failure',
      description: 'A genuine CLI failure should remain failed.',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-task-oneshot-failed',
      workflowRunId: 'wf-failed',
      provider: 'claude',
    );
    await seedWorkflowExecution(
      'task-oneshot-failed',
      agentExecutionId: 'ae-task-oneshot-failed',
      workflowRunId: 'wf-failed',
    );

    await oneShotExecutor.pollOnce();
    await oneShotExecutor.drain();

    final updated = await waitForTaskStatus(tasks, 'task-oneshot-failed', until: const {TaskStatus.failed});
    expect(updated?.status, TaskStatus.failed);
    final events = eventService.listForTask('task-oneshot-failed');
    final taskErrors = events.where((event) => event.kind == TaskEventKind.taskError).toList();
    expect(taskErrors.map((event) => event.details['message']), [
      'Workflow one-shot claude command failed with exit code 1',
    ]);
  });

  test('workflow oneshot genuine failure corrects dispose-cancelled task to failed', () async {
    final eventDb = openTaskDbInMemory();
    addTearDown(eventDb.close);
    final eventService = TaskEventService(eventDb);
    final recorder = TaskEventRecorder(eventService: eventService);
    final cliRunner = WorkflowCliRunner(
      providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')},
      providerImpls: {
        'claude': _CancelsThenFailsCliProvider(() {
          return tasks.transition('task-oneshot-cancelled-then-failed', TaskStatus.cancelled, trigger: 'dispose');
        }),
      },
    );
    final oneShotExecutor = buildExecutor(workflowCliRunner: cliRunner, eventRecorder: recorder);
    addTearDown(oneShotExecutor.stop);

    await tasks.create(
      id: 'task-oneshot-cancelled-then-failed',
      title: 'One-shot cancelled then failed',
      description: 'A genuine CLI failure should override a concurrent dispose cancellation.',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-task-oneshot-cancelled-then-failed',
      workflowRunId: 'wf-cancelled-then-failed',
      provider: 'claude',
    );
    await seedWorkflowExecution(
      'task-oneshot-cancelled-then-failed',
      agentExecutionId: 'ae-task-oneshot-cancelled-then-failed',
      workflowRunId: 'wf-cancelled-then-failed',
    );

    await oneShotExecutor.pollOnce();
    await oneShotExecutor.drain();

    final updated = await waitForTaskStatus(
      tasks,
      'task-oneshot-cancelled-then-failed',
      until: const {TaskStatus.failed},
    );
    expect(updated?.status, TaskStatus.failed);
    final events = eventService.listForTask('task-oneshot-cancelled-then-failed');
    final taskErrors = events.where((event) => event.kind == TaskEventKind.taskError).toList();
    expect(taskErrors.map((event) => event.details['message']), [
      'Workflow one-shot claude command failed with exit code 17',
    ]);
  });

  test('workflow oneshot non-zero exit completed before cancellation records failed with taskError', () async {
    final eventDb = openTaskDbInMemory();
    addTearDown(eventDb.close);
    final eventService = TaskEventService(eventDb);
    final recorder = TaskEventRecorder(eventService: eventService);
    late FakeProcess process;
    final processStarted = Completer<void>();
    final cliRunner = WorkflowCliRunner(
      providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')},
      processStarter: (exe, args, {workingDirectory, environment}) async {
        process = FakeProcess(killResult: false);
        processStarted.complete();
        return process;
      },
    );
    final oneShotExecutor = buildExecutor(workflowCliRunner: cliRunner, eventRecorder: recorder);
    addTearDown(oneShotExecutor.stop);

    await tasks.create(
      id: 'task-oneshot-race-failed',
      title: 'One-shot race failure',
      description: 'A CLI failure that already exited before teardown should remain failed.',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-task-oneshot-race-failed',
      workflowRunId: 'wf-race-failed',
      provider: 'claude',
    );
    await seedWorkflowExecution(
      'task-oneshot-race-failed',
      agentExecutionId: 'ae-task-oneshot-race-failed',
      workflowRunId: 'wf-race-failed',
    );

    final poll = oneShotExecutor.pollOnce();
    await processStarted.future;
    process.exit(17);
    await cliRunner.cancelInflight();
    await poll;
    await oneShotExecutor.stop();

    final updated = await tasks.get('task-oneshot-race-failed');
    expect(updated?.status, TaskStatus.failed);
    final events = eventService.listForTask('task-oneshot-race-failed');
    final taskErrors = events.where((event) => event.kind == TaskEventKind.taskError).toList();
    expect(taskErrors.map((event) => event.details['message']), [
      'Workflow one-shot claude command failed with exit code 17',
    ]);
  });

  test('provider-less workflow oneshot uses the configured default provider', () async {
    String? executable;
    final cliRunner = echoCliRunner(
      (_) => jsonEncode({'session_id': 'default-provider-session', 'result': 'Done.'}),
      onArgs: (exe, _) => executable = exe,
    );
    final oneShotExecutor = buildExecutor(
      workflowCliRunner: cliRunner,
      limits: const TaskExecutorLimits(defaultProviderId: 'codex'),
    );
    addTearDown(oneShotExecutor.stop);

    await tasks.create(
      id: 'task-oneshot-default-provider',
      title: 'One-shot workflow step',
      description: 'Run the workflow step.',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-task-oneshot-default-provider',
      workflowRunId: 'wf-default-provider',
    );
    await seedWorkflowExecution(
      'task-oneshot-default-provider',
      agentExecutionId: 'ae-task-oneshot-default-provider',
      workflowRunId: 'wf-default-provider',
    );

    final processed = await oneShotExecutor.pollOnce();
    await oneShotExecutor.drain();

    expect(processed, isTrue);
    expect(executable, 'codex');
    expect(
      (await waitForTaskStatus(tasks, 'task-oneshot-default-provider', until: const {TaskStatus.review}))?.status,
      TaskStatus.review,
    );
  });

  test('workflow oneshot resolves step timeout from task config before global default', () async {
    final provider = _RecordingTimeoutCliProvider();
    final cliRunner = WorkflowCliRunner(
      providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')},
      providerImpls: {'claude': provider},
    );
    final oneShotExecutor = buildExecutor(
      workflowCliRunner: cliRunner,
      limits: const TaskExecutorLimits(defaultStepTimeout: Duration(seconds: 42)),
    );
    addTearDown(oneShotExecutor.stop);

    Future<void> createAndPoll(String id, {Map<String, dynamic> configJson = const {}}) async {
      await tasks.create(
        id: id,
        title: 'One-shot workflow timeout',
        description: 'Run the workflow step.',
        type: TaskType.coding,
        autoStart: true,
        agentExecutionId: 'ae-$id',
        workflowRunId: 'wf-timeout',
        provider: 'claude',
        configJson: configJson,
      );
      await seedWorkflowExecution(id, agentExecutionId: 'ae-$id', workflowRunId: 'wf-timeout');
      await oneShotExecutor.pollOnce();
      await oneShotExecutor.drain();
    }

    await createAndPoll('task-global-timeout');
    await createAndPoll('task-step-timeout', configJson: const {WorkflowTaskConfig.workflowTimeoutSeconds: 7});

    expect(provider.stepTimeouts, [const Duration(seconds: 42), const Duration(seconds: 7)]);
  });

  test('workflow oneshot passes read-only allowedTools to CLI policy', () async {
    late List<String> arguments;
    final cliRunner = echoCliRunner(
      (_) => jsonEncode({'session_id': 'cli-session-policy', 'result': 'Done.'}),
      onArgs: (_, args) => arguments = args,
    );
    final oneShotExecutor = buildExecutor(workflowCliRunner: cliRunner);
    addTearDown(oneShotExecutor.stop);

    await tasks.create(
      id: 'task-oneshot-policy',
      title: 'One-shot workflow policy',
      description: 'Run read-only discovery.',
      type: TaskType.research,
      autoStart: true,
      agentExecutionId: 'ae-task-oneshot-policy',
      workflowRunId: 'wf-policy',
      provider: 'claude',
      configJson: const {
        'allowedTools': ['shell', 'file_read'],
        'readOnly': true,
      },
    );
    await seedWorkflowExecution(
      'task-oneshot-policy',
      agentExecutionId: 'ae-task-oneshot-policy',
      workflowRunId: 'wf-policy',
    );

    await oneShotExecutor.pollOnce();
    await oneShotExecutor.drain();

    expect(arguments, containsAll(['--permission-mode', 'dontAsk']));
    expect(arguments, isNot(contains('--dangerously-skip-permissions')));
    final settingsIndex = arguments.indexOf('--settings');
    expect(settingsIndex, isNonNegative);
    final settings = jsonDecode(arguments[settingsIndex + 1]) as Map<String, dynamic>;
    expect(settings['permissions'], {
      'allow': [
        'Bash(git ls-files)',
        'Bash(git rev-parse --abbrev-ref HEAD)',
        'Bash(git rev-parse --show-toplevel)',
        'Bash(git status --porcelain)',
        'Bash(git status --short)',
        'Bash(git status)',
        'Bash(pwd)',
        'Glob',
        'Grep',
        'LS',
        'Read',
      ],
      'deny': ['Edit', 'NotebookEdit', 'Write'],
    });
  });

  test('workflow oneshot token mirroring preserves config updates made while the task is running', () async {
    final cliRunner = WorkflowCliRunner(
      providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')},
      processStarter: (exe, args, {workingDirectory, environment}) async {
        final payload = args.contains('--json-schema')
            ? jsonEncode({
                'session_id': 'cli-session-race',
                'input_tokens': 600,
                'output_tokens': 400,
                'cache_read_tokens': 300,
                'structured_output': {
                  'verdict': {
                    'pass': true,
                    'findings_count': 0,
                    'findings': <Map<String, dynamic>>[],
                    'summary': 'Clean',
                  },
                },
              })
            : jsonEncode({
                'session_id': 'cli-session-race',
                'input_tokens': 200,
                'output_tokens': 50,
                'cache_read_tokens': 50,
                'result': 'Working...',
              });
        final script = "sleep 0.2; printf '%s' '${payload.replaceAll("'", "'\\''")}'";
        return Process.start('/bin/sh', ['-lc', script]);
      },
    );
    final oneShotExecutor = buildExecutor(workflowCliRunner: cliRunner);
    addTearDown(oneShotExecutor.stop);

    await tasks.create(
      id: 'task-oneshot-race',
      title: 'One-shot workflow step race',
      description: 'Run the workflow step.',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-task-oneshot-race',
      workflowRunId: 'wf-race',
      provider: 'claude',
    );
    await seedWorkflowExecution(
      'task-oneshot-race',
      agentExecutionId: 'ae-task-oneshot-race',
      workflowRunId: 'wf-race',
      followUpPrompts: ['Follow up'],
      structuredSchema: const {
        'type': 'object',
        'additionalProperties': false,
        'required': ['verdict'],
        'properties': {
          'verdict': {
            'type': 'object',
            'additionalProperties': false,
            'required': ['pass', 'findings_count', 'findings', 'summary'],
            'properties': {
              'pass': {'type': 'boolean'},
              'findings_count': {'type': 'integer'},
              'findings': {
                'type': 'array',
                'items': {'type': 'object', 'additionalProperties': false},
              },
              'summary': {'type': 'string'},
            },
          },
        },
      },
    );

    final pollFuture = oneShotExecutor.pollOnce();
    await waitForTaskStatus(tasks, 'task-oneshot-race', until: const {TaskStatus.running});
    final current = await tasks.get('task-oneshot-race');
    await tasks.updateFields(
      'task-oneshot-race',
      configJson: {...?current?.configJson, '_tokenBudgetWarningFired': true},
    );

    await pollFuture;
    await oneShotExecutor.drain();

    final updated = await waitForTaskStatus(tasks, 'task-oneshot-race', until: const {TaskStatus.review});
    expect(updated?.status, TaskStatus.review);
    expect(updated?.configJson['_tokenBudgetWarningFired'], isTrue);
    expect(updated?.configJson['_workflowInputTokensNew'], 600);
    expect(updated?.configJson['_workflowCacheReadTokens'], 400);
    expect(updated?.configJson['_workflowOutputTokens'], 500);
  });

  test('workflow oneshot session_cost uses canonical fresh-input schema and matches turn-runner shape', () async {
    final session = await sessions.createSession();
    final interactiveWorker = FakeAgentHarness(supportsCostReporting: false, supportsCachedTokens: true);
    addTearDown(interactiveWorker.dispose);
    final turnStateDb = sqlite3.openInMemory();
    addTearDown(turnStateDb.close);
    final turnState = TurnStateStore(turnStateDb);
    addTearDown(turnState.dispose);
    final interactiveRunner = TurnRunner(
      harness: interactiveWorker,
      messages: messages,
      behavior: BehaviorFileService(workspaceDir: workspaceDir),
      sessions: sessions,
      turnState: turnState,
      kv: kvService,
      providerId: 'claude',
    );

    unawaited(() async {
      await interactiveWorker.turnInvoked;
      interactiveWorker.completeSuccess({'input_tokens': 100, 'output_tokens': 50, 'cache_read_tokens': 80});
    }());

    final interactiveTurnId = await interactiveRunner.startTurn(session.id, [
      {'role': 'user', 'content': 'interactive'},
    ]);
    await interactiveRunner.waitForOutcome(session.id, interactiveTurnId);

    final cliRunner = WorkflowCliRunner(
      providers: const {'codex': WorkflowCliProviderConfig(executable: 'codex')},
      processStarter: (exe, args, {workingDirectory, environment}) async {
        final payload = [
          jsonEncode({'type': 'thread.started', 'thread_id': 'codex-thread-schema'}),
          jsonEncode({
            'type': 'item.completed',
            'item': {'type': 'agent_message', 'text': 'Done.'},
          }),
          jsonEncode({
            'type': 'turn.completed',
            'usage': {'input_tokens': 100, 'cached_input_tokens': 80, 'output_tokens': 50},
          }),
        ].join('\n').replaceAll("'", "'\\''");
        return Process.start('/bin/sh', ['-lc', "printf '%s' '$payload'"]);
      },
    );
    final oneShotExecutor = buildExecutor(workflowCliRunner: cliRunner);
    addTearDown(oneShotExecutor.stop);

    await tasks.create(
      id: 'task-session-cost-shape',
      title: 'Workflow schema parity',
      description: 'Verify workflow session_cost shape matches TurnRunner.',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-task-session-cost-shape',
      workflowRunId: 'wf-session-cost-shape',
      provider: 'codex',
      configJson: {'_continueSessionId': session.id},
    );
    await seedWorkflowExecution(
      'task-session-cost-shape',
      agentExecutionId: 'ae-task-session-cost-shape',
      workflowRunId: 'wf-session-cost-shape',
    );

    await oneShotExecutor.pollOnce();
    await oneShotExecutor.drain();

    final raw = await kvService.get('session_cost:${session.id}');
    expect(raw, isNotNull);
    final costData = jsonDecode(raw!) as Map<String, dynamic>;
    expect(costData.keys.toSet(), {
      'input_tokens',
      'output_tokens',
      'cache_read_tokens',
      'cache_write_tokens',
      'total_tokens',
      'effective_tokens',
      'estimated_cost_usd',
      'turn_count',
      'provider',
    });
    expect(costData.containsKey('new_input_tokens'), isFalse);
    expect(costData['input_tokens'], 120);
    expect(costData['output_tokens'], 100);
    expect(costData['cache_read_tokens'], 160);
    expect(costData['cache_write_tokens'], 0);
    expect(costData['total_tokens'], 220);
    expect(costData['effective_tokens'], 236);
    expect(costData['turn_count'], 2);
    expect(costData['provider'], 'claude');
  });

  test('workflow oneshot normalizes cumulative Codex usage across resumed follow-up and extraction turns', () async {
    final schema = <String, dynamic>{
      'type': 'object',
      'required': ['verdict'],
      'properties': {
        'verdict': {
          'type': 'object',
          'required': ['pass'],
          'properties': {
            'pass': {'type': 'boolean'},
          },
        },
      },
    };
    final capturedArgs = <List<String>>[];
    var invocation = 0;
    final cliRunner = WorkflowCliRunner(
      providers: const {'codex': WorkflowCliProviderConfig(executable: 'codex')},
      processStarter: (exe, args, {workingDirectory, environment}) async {
        capturedArgs.add(List<String>.from(args));
        invocation++;
        final List<String> lines;
        if (invocation == 1) {
          lines = [
            jsonEncode({'type': 'thread.started', 'thread_id': 'codex-thread-resume'}),
            jsonEncode({
              'type': 'item.completed',
              'item': {'type': 'agent_message', 'text': 'Initial analysis.'},
            }),
            jsonEncode({
              'type': 'turn.completed',
              'usage': {'input_tokens': 100, 'cached_input_tokens': 80, 'output_tokens': 10},
            }),
          ];
        } else if (invocation == 2) {
          lines = [
            jsonEncode({'type': 'thread.started', 'thread_id': 'codex-thread-resume'}),
            jsonEncode({
              'type': 'item.completed',
              'item': {'type': 'agent_message', 'text': 'Follow-up analysis.'},
            }),
            jsonEncode({
              'type': 'turn.completed',
              'usage': {'input_tokens': 140, 'cached_input_tokens': 100, 'output_tokens': 18},
            }),
          ];
        } else {
          lines = [
            jsonEncode({'type': 'thread.started', 'thread_id': 'codex-thread-resume'}),
            jsonEncode({
              'type': 'item.completed',
              'item': {
                'type': 'agent_message',
                'text': jsonEncode({
                  'verdict': {'pass': true},
                }),
              },
            }),
            jsonEncode({
              'type': 'turn.completed',
              'usage': {'input_tokens': 170, 'cached_input_tokens': 120, 'output_tokens': 25},
            }),
          ];
        }
        final stdout = lines.join('\n').replaceAll("'", "'\\''");
        return Process.start('/bin/sh', ['-lc', "printf '%s' '$stdout'"]);
      },
    );
    final oneShotExecutor = buildExecutor(workflowCliRunner: cliRunner);
    addTearDown(oneShotExecutor.stop);

    await tasks.create(
      id: 'task-codex-cumulative-deltas',
      title: 'Workflow cumulative Codex deltas',
      description: 'Normalize cumulative Codex usage into per-turn deltas.',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-task-codex-cumulative-deltas',
      workflowRunId: 'wf-codex-cumulative-deltas',
      provider: 'codex',
    );
    await seedWorkflowExecution(
      'task-codex-cumulative-deltas',
      agentExecutionId: 'ae-task-codex-cumulative-deltas',
      workflowRunId: 'wf-codex-cumulative-deltas',
      followUpPrompts: ['Follow up'],
      structuredSchema: schema,
      stepId: 'plan',
    );

    await oneShotExecutor.pollOnce();
    await oneShotExecutor.drain();

    expect(invocation, 3);
    expect(capturedArgs[0].contains('resume'), isFalse);
    expect(capturedArgs[1], containsAll(<String>['resume', 'codex-thread-resume']));
    expect(capturedArgs[2], containsAll(<String>['resume', 'codex-thread-resume']));

    final updated = await waitForTaskStatus(tasks, 'task-codex-cumulative-deltas', until: const {TaskStatus.review});
    expect(updated?.status, TaskStatus.review);
    expect(updated?.configJson['_workflowInputTokensNew'], 50);
    expect(updated?.configJson['_workflowCacheReadTokens'], 120);
    expect(updated?.configJson['_workflowOutputTokens'], 25);

    final stepExecution = await workflowStepExecutions.getByTaskId('task-codex-cumulative-deltas');
    expect(stepExecution?.providerSessionId, 'codex-thread-resume');
    expect(stepExecution?.stepTokenBreakdown, {'inputTokensNew': 50, 'cacheReadTokens': 120, 'outputTokens': 25});
    expect(stepExecution?.structuredOutput, {
      'verdict': {'pass': true},
    });

    final sessionId = updated?.sessionId;
    expect(sessionId, isNotNull);
    final raw = await kvService.get('session_cost:$sessionId');
    expect(raw, isNotNull);
    final costData = jsonDecode(raw!) as Map<String, dynamic>;
    expect(costData['input_tokens'], 50);
    expect(costData['output_tokens'], 25);
    expect(costData['cache_read_tokens'], 120);
    expect(costData['cache_write_tokens'], 0);
    expect(costData['total_tokens'], 75);
    expect(costData['effective_tokens'], 87);
    expect(costData['turn_count'], 3);
  });

  test('workflow oneshot subtracts existing session baseline on the first resumed Codex turn', () async {
    final continuedSession = await sessions.createSession();
    await kvService.set(
      'session_cost:${continuedSession.id}',
      jsonEncode({
        'input_tokens': 20,
        'output_tokens': 10,
        'cache_read_tokens': 80,
        'cache_write_tokens': 0,
        'total_tokens': 30,
        'effective_tokens': 38,
        'estimated_cost_usd': 0.0,
        'turn_count': 1,
        'provider': 'codex',
      }),
    );

    final cliRunner = WorkflowCliRunner(
      providers: const {'codex': WorkflowCliProviderConfig(executable: 'codex')},
      processStarter: (exe, args, {workingDirectory, environment}) async {
        final stdout = [
          jsonEncode({'type': 'thread.started', 'thread_id': 'codex-thread-resume'}),
          jsonEncode({
            'type': 'item.completed',
            'item': {'type': 'agent_message', 'text': 'Done.'},
          }),
          jsonEncode({
            'type': 'turn.completed',
            'usage': {'input_tokens': 170, 'cached_input_tokens': 120, 'output_tokens': 25},
          }),
        ].join('\n').replaceAll("'", "'\\''");
        return Process.start('/bin/sh', ['-lc', "printf '%s' '$stdout'"]);
      },
    );
    final oneShotExecutor = buildExecutor(workflowCliRunner: cliRunner);
    addTearDown(oneShotExecutor.stop);

    await tasks.create(
      id: 'task-codex-session-baseline',
      title: 'Workflow continued Codex baseline',
      description: 'Subtract the already-accounted shared-session baseline.',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-task-codex-session-baseline',
      workflowRunId: 'wf-codex-session-baseline',
      provider: 'codex',
      configJson: {'_continueSessionId': continuedSession.id},
    );
    await seedWorkflowExecution(
      'task-codex-session-baseline',
      agentExecutionId: 'ae-task-codex-session-baseline',
      workflowRunId: 'wf-codex-session-baseline',
      providerSessionId: 'codex-thread-resume',
    );

    await oneShotExecutor.pollOnce();
    await oneShotExecutor.drain();

    final updated = await waitForTaskStatus(tasks, 'task-codex-session-baseline', until: const {TaskStatus.review});
    expect(updated?.sessionId, continuedSession.id);
    expect(updated?.configJson['_workflowInputTokensNew'], 30);
    expect(updated?.configJson['_workflowCacheReadTokens'], 40);
    expect(updated?.configJson['_workflowOutputTokens'], 15);

    final stepExecution = await workflowStepExecutions.getByTaskId('task-codex-session-baseline');
    expect(stepExecution?.stepTokenBreakdown, {'inputTokensNew': 30, 'cacheReadTokens': 40, 'outputTokens': 15});

    final raw = await kvService.get('session_cost:${continuedSession.id}');
    expect(raw, isNotNull);
    final costData = jsonDecode(raw!) as Map<String, dynamic>;
    expect(costData['input_tokens'], 50);
    expect(costData['output_tokens'], 25);
    expect(costData['cache_read_tokens'], 120);
    expect(costData['cache_write_tokens'], 0);
    expect(costData['total_tokens'], 75);
    expect(costData['effective_tokens'], 87);
    expect(costData['turn_count'], 2);
  });

  test('workflow oneshot short-circuits extraction when inline <workflow-context> is valid', () async {
    final schema = <String, dynamic>{
      'type': 'object',
      'required': ['verdict'],
      'properties': {
        'verdict': {
          'type': 'object',
          'required': ['pass'],
          'properties': {
            'pass': {'type': 'boolean'},
          },
        },
      },
    };
    final inlinePayload = <String, dynamic>{
      'verdict': {'pass': true},
    };
    final capturedArgs = <List<String>>[];
    final cliRunner = echoCliRunner(
      (_) => jsonEncode({
        'session_id': 'cli-session-inline',
        'result': 'Working...\n<workflow-context>\n${jsonEncode(inlinePayload)}\n</workflow-context>',
      }),
      onArgs: (_, args) => capturedArgs.add(args),
    );
    final eventDb = openTaskDbInMemory();
    addTearDown(eventDb.close);
    final eventService = TaskEventService(eventDb);
    final recorder = TaskEventRecorder(eventService: eventService);

    final inlineExecutor = buildExecutor(workflowCliRunner: cliRunner, eventRecorder: recorder);
    addTearDown(inlineExecutor.stop);

    await tasks.create(
      id: 'task-inline',
      title: 'Inline short-circuit',
      description: 'Main turn emits a valid workflow-context block.',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-task-inline',
      workflowRunId: 'wf-inline',
      provider: 'claude',
    );
    await seedWorkflowExecution(
      'task-inline',
      agentExecutionId: 'ae-task-inline',
      workflowRunId: 'wf-inline',
      structuredSchema: schema,
      stepId: 'plan',
    );

    await inlineExecutor.pollOnce();
    await inlineExecutor.drain();

    expect(capturedArgs, hasLength(1), reason: 'extraction turn must be skipped when inline is valid');
    expect((await workflowStepExecutions.getByTaskId('task-inline'))?.structuredOutput, inlinePayload);
    final events = eventService.listForTask('task-inline');
    final inlineEvents = events.where((e) => e.kind.name == 'structuredOutputInlineUsed').toList();
    expect(inlineEvents, hasLength(1));
    expect(inlineEvents.single.details['stepId'], 'plan');
    expect(inlineEvents.single.details['outputKey'], 'verdict');
    expect(events.any((e) => e.kind.name == 'structuredOutputFallbackUsed'), isFalse);
  });

  test('workflow oneshot runs extraction turn when inline <workflow-context> is missing', () async {
    final schema = <String, dynamic>{
      'type': 'object',
      'required': ['verdict'],
      'properties': {
        'verdict': {
          'type': 'object',
          'required': ['pass'],
          'properties': {
            'pass': {'type': 'boolean'},
          },
        },
      },
    };
    final capturedArgs = <List<String>>[];
    final cliRunner = echoCliRunner(
      (args) => args.contains('--json-schema')
          ? jsonEncode({
              'session_id': 'cli-session-extract',
              'structured_output': {
                'verdict': {'pass': false},
              },
            })
          : jsonEncode({'session_id': 'cli-session-extract', 'result': 'Analysis without any context block.'}),
      onArgs: (_, args) => capturedArgs.add(args),
    );
    final eventDb = openTaskDbInMemory();
    addTearDown(eventDb.close);
    final eventService = TaskEventService(eventDb);
    final recorder = TaskEventRecorder(eventService: eventService);

    final fallbackExecutor = buildExecutor(workflowCliRunner: cliRunner, eventRecorder: recorder);
    addTearDown(fallbackExecutor.stop);

    await tasks.create(
      id: 'task-fallback',
      title: 'Extraction fallback',
      description: 'Main turn has no workflow-context block.',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-task-fallback',
      workflowRunId: 'wf-fallback',
      provider: 'claude',
    );
    await seedWorkflowExecution(
      'task-fallback',
      agentExecutionId: 'ae-task-fallback',
      workflowRunId: 'wf-fallback',
      structuredSchema: schema,
      stepId: 'plan',
    );

    await fallbackExecutor.pollOnce();
    await fallbackExecutor.drain();

    expect(capturedArgs, hasLength(2), reason: 'extraction turn must run when inline is missing');
    expect((await workflowStepExecutions.getByTaskId('task-fallback'))?.structuredOutput, {
      'verdict': {'pass': false},
    });
    final events = eventService.listForTask('task-fallback');
    expect(events.any((e) => e.kind.name == 'structuredOutputInlineUsed'), isFalse);
  });

  test('workflow oneshot runs extraction turn when inline structured payload is partial', () async {
    final schema = <String, dynamic>{
      'type': 'object',
      'required': ['summary', 'confidence'],
      'properties': {
        'summary': {'type': 'string'},
        'confidence': {'type': 'integer'},
      },
    };
    final capturedArgs = <List<String>>[];
    final cliRunner = echoCliRunner(
      (args) => args.contains('--json-schema')
          ? jsonEncode({
              'session_id': 'cli-session-partial',
              'structured_output': {'summary': 'Fallback summary', 'confidence': 7},
            })
          : jsonEncode({
              'session_id': 'cli-session-partial',
              'result': '<workflow-context>{"summary":"Inline summary"}</workflow-context>',
            }),
      onArgs: (_, args) => capturedArgs.add(args),
    );
    final partialExecutor = buildExecutor(workflowCliRunner: cliRunner);
    addTearDown(partialExecutor.stop);

    await tasks.create(
      id: 'task-partial-inline',
      title: 'Partial inline',
      description: 'Main turn emits only one required narrative key.',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-task-partial-inline',
      workflowRunId: 'wf-partial-inline',
      provider: 'claude',
    );
    await seedWorkflowExecution(
      'task-partial-inline',
      agentExecutionId: 'ae-task-partial-inline',
      workflowRunId: 'wf-partial-inline',
      structuredSchema: schema,
      stepId: 'summarize',
    );

    await partialExecutor.pollOnce();
    await partialExecutor.drain();

    expect(capturedArgs, hasLength(2), reason: 'partial inline payload must not suppress extraction turn');
    expect((await workflowStepExecutions.getByTaskId('task-partial-inline'))?.structuredOutput, {
      'summary': 'Fallback summary',
      'confidence': 7,
    });
  });

  test('workflow oneshot structured-output fallback turn emits correlated progress events', () async {
    // Regression guard for the gap where the fallback `runner.executeTurn(...)`
    // call omitted taskId/sessionId, causing WorkflowCliTurnProgressEvent to
    // emit empty identifiers on the second of two one-shot execution paths.
    final schema = <String, dynamic>{
      'type': 'object',
      'required': ['verdict'],
      'properties': {
        'verdict': {
          'type': 'object',
          'required': ['pass'],
          'properties': {
            'pass': {'type': 'boolean'},
          },
        },
      },
    };
    final eventBus = EventBus();
    addTearDown(eventBus.dispose);
    final progressEvents = <WorkflowCliTurnProgressEvent>[];
    final sub = eventBus.on<WorkflowCliTurnProgressEvent>().listen(progressEvents.add);
    addTearDown(sub.cancel);

    var invocation = 0;
    final cliRunner = WorkflowCliRunner(
      providers: const {'codex': WorkflowCliProviderConfig(executable: 'codex')},
      eventBus: eventBus,
      processStarter: (exe, args, {workingDirectory, environment}) async {
        invocation++;
        final List<String> lines;
        if (invocation == 1) {
          // Main turn: prose without a <workflow-context> block, forcing the
          // extraction fallback.
          lines = [
            jsonEncode({'type': 'thread.started', 'thread_id': 'codex-fallback-main'}),
            jsonEncode({
              'type': 'item.completed',
              'item': {'type': 'agent_message', 'text': 'Analysis without any context block.'},
            }),
            jsonEncode({
              'type': 'turn.completed',
              'usage': {'input_tokens': 50, 'output_tokens': 10},
            }),
          ];
        } else {
          // Fallback turn: emit the structured payload.
          lines = [
            jsonEncode({'type': 'thread.started', 'thread_id': 'codex-fallback-extract'}),
            jsonEncode({
              'type': 'item.completed',
              'item': {
                'type': 'agent_message',
                'text': jsonEncode({
                  'verdict': {'pass': false},
                }),
              },
            }),
            jsonEncode({
              'type': 'turn.completed',
              'usage': {'input_tokens': 70, 'output_tokens': 15},
            }),
          ];
        }
        final stdout = lines.join('\n').replaceAll("'", "'\\''");
        return Process.start('/bin/sh', ['-lc', "printf '%s' '$stdout'"]);
      },
    );
    final fallbackExecutor = buildExecutor(workflowCliRunner: cliRunner);
    addTearDown(fallbackExecutor.stop);

    await tasks.create(
      id: 'task-fallback-progress',
      title: 'Extraction fallback progress',
      description: 'Fallback path must carry taskId/sessionId into progress events.',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-task-fallback-progress',
      workflowRunId: 'wf-fallback-progress',
      provider: 'codex',
    );
    await seedWorkflowExecution(
      'task-fallback-progress',
      agentExecutionId: 'ae-task-fallback-progress',
      workflowRunId: 'wf-fallback-progress',
      structuredSchema: schema,
      stepId: 'plan',
    );

    await fallbackExecutor.pollOnce();
    await fallbackExecutor.drain();

    expect(invocation, 2, reason: 'fallback extraction turn must run when inline is missing');
    expect(progressEvents, hasLength(2), reason: 'both main and fallback turns must emit progress events');
    final sessionId = (await tasks.get('task-fallback-progress'))?.sessionId;
    expect(sessionId, isNotNull);
    for (final event in progressEvents) {
      expect(event.taskId, 'task-fallback-progress');
      expect(event.sessionId, sessionId);
      expect(event.provider, 'codex');
    }
  });

  test('workflow oneshot extraction turn receives appendSystemPrompt: null even when main turn received it', () async {
    final schema = <String, dynamic>{
      'type': 'object',
      'required': ['verdict'],
      'properties': {
        'verdict': {
          'type': 'object',
          'required': ['pass'],
          'properties': {
            'pass': {'type': 'boolean'},
          },
        },
      },
    };
    final capturedArgs = <List<String>>[];
    final cliRunner = echoCliRunner(
      (args) => args.contains('--json-schema')
          ? jsonEncode({
              'session_id': 'cli-session-append',
              'structured_output': {
                'verdict': {'pass': true},
              },
            })
          : jsonEncode({'session_id': 'cli-session-append', 'result': 'No context block here.'}),
      onArgs: (_, args) => capturedArgs.add(args),
    );
    final appendExecutor = buildExecutor(workflowCliRunner: cliRunner);
    addTearDown(appendExecutor.stop);

    await tasks.create(
      id: 'task-append',
      title: 'Extraction hygiene',
      description: 'appendSystemPrompt must not leak into the extraction turn.',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-task-append',
      workflowRunId: 'wf-append',
      configJson: {'appendSystemPrompt': 'PAYLOAD'},
      provider: 'claude',
    );
    await seedWorkflowExecution(
      'task-append',
      agentExecutionId: 'ae-task-append',
      workflowRunId: 'wf-append',
      structuredSchema: schema,
      stepId: 'plan',
    );

    await appendExecutor.pollOnce();
    await appendExecutor.drain();

    expect(capturedArgs, hasLength(2));
    final mainArgs = capturedArgs[0];
    final extractionArgs = capturedArgs[1];
    final mainAppendIndex = mainArgs.indexOf('--append-system-prompt');
    expect(mainAppendIndex, isNot(-1), reason: 'main turn must forward appendSystemPrompt');
    expect(mainArgs[mainAppendIndex + 1], 'PAYLOAD');
    expect(
      extractionArgs.contains('--append-system-prompt'),
      isFalse,
      reason: 'extraction turn must not carry appendSystemPrompt',
    );
  });

  test('workflow oneshot finalizer runs even with inline block / structured output', () async {
    final eventDb = openTaskDbInMemory();
    addTearDown(eventDb.close);
    final eventService = TaskEventService(eventDb);
    final recorder = TaskEventRecorder(eventService: eventService);
    final cliRunner = echoCliRunner(
      (args) => args.contains('--json-schema')
          ? jsonEncode({'session_id': 'cli-session-final', 'structured_output': _finalizerEnvelopeOutput})
          : jsonEncode({
              'session_id': 'cli-session-final',
              'result': 'Working...\n<workflow-context>{"summary":"inline"}</workflow-context>',
            }),
    );
    final finalizerExecutor = buildExecutor(workflowCliRunner: cliRunner, eventRecorder: recorder);
    addTearDown(finalizerExecutor.stop);

    await tasks.create(
      id: 'task-finalizer-inline',
      title: 'Finalizer over inline',
      description: 'Envelope step still finalizes even with a legacy inline block.',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-task-finalizer-inline',
      workflowRunId: 'wf-finalizer-inline',
      provider: 'claude',
    );
    await seedWorkflowExecution(
      'task-finalizer-inline',
      agentExecutionId: 'ae-task-finalizer-inline',
      workflowRunId: 'wf-finalizer-inline',
      structuredSchema: _summaryEnvelopeSchema,
      stepId: 'plan',
    );

    await finalizerExecutor.pollOnce();
    await finalizerExecutor.drain();

    final stored = (await workflowStepExecutions.getByTaskId('task-finalizer-inline'))?.structuredOutput;
    expect(stored, isNotNull, reason: 'finalizer envelope must be persisted');
    expect(stored![executionEnvelopeMarkerKey], executionEnvelopeVersion);
    expect(
      (stored['outputs'] as Map)['summary'],
      'final',
      reason: 'authoritative payload is the finalizer, not inline',
    );
    final events = eventService.listForTask('task-finalizer-inline');
    final finalizerEvents = events.where((e) => e.kind.name == 'structuredOutputFinalizerUsed').toList();
    expect(finalizerEvents, hasLength(1));
    expect(finalizerEvents.single.details['stepId'], 'plan');
    expect(finalizerEvents.single.details['outputKey'], 'summary');
    expect(events.any((e) => e.kind.name == 'structuredOutputInlineUsed'), isFalse);
  });

  test('workflow oneshot no-tools invocation arguments (finalizer)', () async {
    final capturedArgs = <List<String>>[];
    final cliRunner = echoCliRunner(
      (args) => args.contains('--json-schema')
          ? jsonEncode({'session_id': 'cli-session-final', 'structured_output': _finalizerEnvelopeOutput})
          : jsonEncode({'session_id': 'cli-session-final', 'result': 'Working...'}),
      onArgs: (_, args) => capturedArgs.add(args),
    );
    final finalizerExecutor = buildExecutor(workflowCliRunner: cliRunner);
    addTearDown(finalizerExecutor.stop);

    await tasks.create(
      id: 'task-finalizer-notools',
      title: 'Finalizer no-tools args',
      description: 'The finalizer turn caps turns and drops write tools.',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-task-finalizer-notools',
      workflowRunId: 'wf-finalizer-notools',
      provider: 'claude',
    );
    await seedWorkflowExecution(
      'task-finalizer-notools',
      agentExecutionId: 'ae-task-finalizer-notools',
      workflowRunId: 'wf-finalizer-notools',
      structuredSchema: _summaryEnvelopeSchema,
      stepId: 'plan',
    );

    await finalizerExecutor.pollOnce();
    await finalizerExecutor.drain();

    final finalizerArgs = capturedArgs.firstWhere((a) => a.contains('--json-schema'));
    final maxTurnsIndex = finalizerArgs.indexOf('--max-turns');
    expect(maxTurnsIndex, isNonNegative, reason: 'claude finalizer must carry a tight turn cap');
    expect(
      finalizerArgs[maxTurnsIndex + 1],
      '2',
      reason:
          'cap must allow one structured-output schema retry; a cap of 1 turns a single rejected '
          'StructuredOutput attempt into error_max_turns and fails the whole step',
    );
    expect(
      finalizerArgs,
      isNot(contains('5')),
      reason: 'legacy --max-turns 5 must not apply to the envelope finalizer',
    );
    // Read-only marker: the finalizer forces a deny-list policy regardless of the task's own readOnly.
    expect(finalizerArgs, containsAll(['--permission-mode', 'dontAsk']));
    final settingsIndex = finalizerArgs.indexOf('--settings');
    expect(settingsIndex, isNonNegative);
    final settings = jsonDecode(finalizerArgs[settingsIndex + 1]) as Map<String, dynamic>;
    expect((settings['permissions'] as Map)['deny'], ['Edit', 'NotebookEdit', 'Write']);
  });

  test('workflow oneshot finalizer token accounting over both turns', () async {
    final cliRunner = echoCliRunner(
      (args) => args.contains('--json-schema')
          ? jsonEncode({
              'session_id': 'cli-session-final',
              'input_tokens': 600,
              'output_tokens': 400,
              'cache_read_tokens': 300,
              'structured_output': _finalizerEnvelopeOutput,
            })
          : jsonEncode({
              'session_id': 'cli-session-final',
              'input_tokens': 200,
              'output_tokens': 50,
              'cache_read_tokens': 50,
              'result': 'Working...',
            }),
    );
    final finalizerExecutor = buildExecutor(workflowCliRunner: cliRunner);
    addTearDown(finalizerExecutor.stop);

    await tasks.create(
      id: 'task-finalizer-tokens',
      title: 'Finalizer token accounting',
      description: 'Token totals sum the main and finalizer turns.',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-task-finalizer-tokens',
      workflowRunId: 'wf-finalizer-tokens',
      provider: 'claude',
    );
    await seedWorkflowExecution(
      'task-finalizer-tokens',
      agentExecutionId: 'ae-task-finalizer-tokens',
      workflowRunId: 'wf-finalizer-tokens',
      structuredSchema: _summaryEnvelopeSchema,
      stepId: 'plan',
    );

    await finalizerExecutor.pollOnce();
    await finalizerExecutor.drain();

    final updated = await waitForTaskStatus(tasks, 'task-finalizer-tokens', until: const {TaskStatus.review});
    expect(updated?.status, TaskStatus.review);
    // main (200/50/50) + finalizer (600/400/300): input 800, cacheRead 350, output 450.
    expect(updated?.configJson['_workflowInputTokensNew'], 450);
    expect(updated?.configJson['_workflowCacheReadTokens'], 350);
    expect(updated?.configJson['_workflowOutputTokens'], 450);
    final step = await workflowStepExecutions.getByTaskId('task-finalizer-tokens');
    expect(step?.stepTokenBreakdown, {'inputTokensNew': 450, 'cacheReadTokens': 350, 'outputTokens': 450});
  });

  test('workflow oneshot finalizer missing provider session → failed', () async {
    final eventDb = openTaskDbInMemory();
    addTearDown(eventDb.close);
    final eventService = TaskEventService(eventDb);
    final recorder = TaskEventRecorder(eventService: eventService);
    final cliRunner = echoCliRunner(
      // Empty session_id everywhere: no resumable session ever materializes.
      (args) => args.contains('--json-schema')
          ? jsonEncode({'session_id': '', 'structured_output': _finalizerEnvelopeOutput})
          : jsonEncode({'session_id': '', 'result': 'Working...'}),
    );
    final finalizerExecutor = buildExecutor(workflowCliRunner: cliRunner, eventRecorder: recorder);
    addTearDown(finalizerExecutor.stop);

    await tasks.create(
      id: 'task-finalizer-nosession',
      title: 'Finalizer missing session',
      description: 'No resumable session is a finalizer failure.',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-task-finalizer-nosession',
      workflowRunId: 'wf-finalizer-nosession',
      provider: 'claude',
    );
    await seedWorkflowExecution(
      'task-finalizer-nosession',
      agentExecutionId: 'ae-task-finalizer-nosession',
      workflowRunId: 'wf-finalizer-nosession',
      structuredSchema: _summaryEnvelopeSchema,
      stepId: 'review',
    );

    await finalizerExecutor.pollOnce();
    await finalizerExecutor.drain();

    final updated = await waitForTaskStatus(tasks, 'task-finalizer-nosession', until: const {TaskStatus.failed});
    expect(updated?.status, TaskStatus.failed);
    final events = eventService.listForTask('task-finalizer-nosession');
    final failedEvents = events.where((e) => e.kind.name == 'structuredOutputValidationFailed').toList();
    expect(failedEvents, hasLength(1));
    expect(failedEvents.single.details['stepId'], 'review');
    expect(failedEvents.single.details['failureReason'], 'missing_provider_session');
    expect(events.any((e) => e.kind.name == 'structuredOutputFinalizerUsed'), isFalse);
    expect(
      (await workflowStepExecutions.getByTaskId('task-finalizer-nosession'))?.structuredOutput,
      isNull,
      reason: 'no structured payload is persisted on finalizer failure',
    );
  });

  test('workflow oneshot finalizer same-session re-ask then success', () async {
    final eventDb = openTaskDbInMemory();
    addTearDown(eventDb.close);
    final eventService = TaskEventService(eventDb);
    final recorder = TaskEventRecorder(eventService: eventService);
    var finalizerCalls = 0;
    final cliRunner = echoCliRunner((args) {
      if (args.contains('--json-schema')) {
        finalizerCalls++;
        // First finalizer turn yields no structured payload; the re-ask succeeds.
        return finalizerCalls == 1
            ? jsonEncode({'session_id': 'cli-session-final', 'result': 'I could not produce it yet.'})
            : jsonEncode({'session_id': 'cli-session-final', 'structured_output': _finalizerEnvelopeOutput});
      }
      return jsonEncode({'session_id': 'cli-session-final', 'result': 'Working...'});
    });
    final finalizerExecutor = buildExecutor(workflowCliRunner: cliRunner, eventRecorder: recorder);
    addTearDown(finalizerExecutor.stop);

    await tasks.create(
      id: 'task-finalizer-reask',
      title: 'Finalizer re-ask',
      description: 'A same-session re-ask recovers the envelope.',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-task-finalizer-reask',
      workflowRunId: 'wf-finalizer-reask',
      provider: 'claude',
    );
    await seedWorkflowExecution(
      'task-finalizer-reask',
      agentExecutionId: 'ae-task-finalizer-reask',
      workflowRunId: 'wf-finalizer-reask',
      structuredSchema: _summaryEnvelopeSchema,
      stepId: 'plan',
    );

    await finalizerExecutor.pollOnce();
    await finalizerExecutor.drain();

    expect(finalizerCalls, 2, reason: 'one re-ask after the first empty finalizer turn');
    final stored = (await workflowStepExecutions.getByTaskId('task-finalizer-reask'))?.structuredOutput;
    expect(stored, isNotNull);
    expect(stored![executionEnvelopeMarkerKey], executionEnvelopeVersion);
    expect((stored['outputs'] as Map)['summary'], 'final');
    final events = eventService.listForTask('task-finalizer-reask');
    expect(events.where((e) => e.kind.name == 'structuredOutputFinalizerUsed'), hasLength(1));
    expect(events.any((e) => e.kind.name == 'structuredOutputValidationFailed'), isFalse);
  });

  test('workflow oneshot finalizer rejects a malformed envelope instead of stamping it', () async {
    final eventDb = openTaskDbInMemory();
    addTearDown(eventDb.close);
    final eventService = TaskEventService(eventDb);
    final recorder = TaskEventRecorder(eventService: eventService);
    // A non-null but schema-invalid finalizer payload: `outputs` omits the
    // required declared key `summary`. A provider/CLI regression could return
    // this; stamping it would advance the step with empty declared outputs.
    final cliRunner = echoCliRunner(
      (args) => args.contains('--json-schema')
          ? jsonEncode({
              'session_id': 'cli-session-final',
              'structured_output': {
                'outputs': <String, dynamic>{},
                'step_outcome': {'outcome': 'succeeded', 'reason': 'ok'},
              },
            })
          : jsonEncode({'session_id': 'cli-session-final', 'result': 'Working...'}),
    );
    final finalizerExecutor = buildExecutor(workflowCliRunner: cliRunner, eventRecorder: recorder);
    addTearDown(finalizerExecutor.stop);

    await tasks.create(
      id: 'task-finalizer-malformed',
      title: 'Finalizer malformed envelope',
      description: 'A malformed envelope is a validation failure, not a success.',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-task-finalizer-malformed',
      workflowRunId: 'wf-finalizer-malformed',
      provider: 'claude',
    );
    await seedWorkflowExecution(
      'task-finalizer-malformed',
      agentExecutionId: 'ae-task-finalizer-malformed',
      workflowRunId: 'wf-finalizer-malformed',
      structuredSchema: _summaryEnvelopeSchema,
      stepId: 'plan',
    );

    await finalizerExecutor.pollOnce();
    await finalizerExecutor.drain();

    final updated = await waitForTaskStatus(tasks, 'task-finalizer-malformed', until: const {TaskStatus.failed});
    expect(updated?.status, TaskStatus.failed);
    final events = eventService.listForTask('task-finalizer-malformed');
    final failedEvents = events.where((e) => e.kind.name == 'structuredOutputValidationFailed').toList();
    expect(failedEvents, hasLength(1));
    expect(failedEvents.single.details['failureReason'], 'malformed_envelope');
    expect(events.any((e) => e.kind.name == 'structuredOutputFinalizerUsed'), isFalse);
    expect(
      (await workflowStepExecutions.getByTaskId('task-finalizer-malformed'))?.structuredOutput,
      isNull,
      reason: 'a malformed envelope must not be persisted',
    );
  });

  group('container lifetime (one authority per step)', () {
    ExecutionPolicyResolver containerPolicyResolver() => ExecutionPolicyResolver(
      config: DartclawConfig.defaults().copyWith(container: const ContainerConfig(enabled: true)),
      availableContainerProfiles: const {'workspace', 'restricted'},
    );

    Future<void> createStepTask(String id, {required String runId, List<String>? followUpPrompts}) async {
      await tasks.create(
        id: id,
        title: 'Step',
        description: 'Run the step.',
        type: TaskType.coding,
        autoStart: true,
        agentExecutionId: 'ae-$id',
        workflowRunId: runId,
        provider: 'claude',
      );
      await seedWorkflowExecution(
        id,
        agentExecutionId: 'ae-$id',
        workflowRunId: runId,
        followUpPrompts: followUpPrompts,
      );
    }

    test('holds one container for the whole step, reused across turns, released once (success)', () async {
      // Two turns (main + follow-up). Pre-fix leased a fresh authority per turn
      // and destroyed the session substrate between them, so the resume on turn
      // 2 targeted state that no longer existed.
      final acquires = <Set<String>>[];
      final releases = <String>[];
      final execCommands = <List<String>>[];
      final container = FakeContainerExecutor(
        hostRoot: Directory.current.path,
        containerRoot: '/project',
        stdout: jsonEncode({'type': 'result', 'session_id': 'cli-session-step', 'result': 'Done.'}),
      )..onExec = execCommands.add;
      final cliRunner = WorkflowCliRunner(
        providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')},
        containerAuthorities: fakeContainerAuthorities(container, grantedMcpTools: acquires, released: releases),
        bridgedMcpToolsResolver: testBridgedMcpTools,
      );
      final executor = buildExecutor(workflowCliRunner: cliRunner, policyResolver: containerPolicyResolver());
      addTearDown(executor.stop);

      await createStepTask('task-step-lifetime', runId: 'wf-step-lifetime', followUpPrompts: ['second turn']);
      await executor.pollOnce();
      await executor.drain();
      await waitForTaskStatus(tasks, 'task-step-lifetime', until: const {TaskStatus.review});

      expect(
        acquires,
        hasLength(1),
        reason: 'one container authority for the whole step — pre-fix leased one per turn',
      );
      expect(releases, hasLength(1), reason: 'the held lease is released exactly once at step end');
      expect(execCommands.length, greaterThanOrEqualTo(2), reason: 'both turns ran inside the same reused container');
      expect(
        execCommands.last.join(' '),
        contains('cli-session-step'),
        reason: 'turn 2 resumes the session the persisted container still holds',
      );
    });

    test('passes the one held lease to every turn and releases it once', () async {
      final runner = _LifecycleRunner();
      final executor = buildExecutor(workflowCliRunner: runner, policyResolver: containerPolicyResolver());
      addTearDown(executor.stop);

      await createStepTask('task-reuse-lease', runId: 'wf-reuse-lease', followUpPrompts: ['second turn']);
      await executor.pollOnce();
      await executor.drain();
      await waitForTaskStatus(tasks, 'task-reuse-lease', until: const {TaskStatus.review});

      expect(runner.leaseCount, 1, reason: 'execute leases exactly one authority — pre-fix never leased at step scope');
      expect(runner.turnCount, greaterThanOrEqualTo(2));
      expect(runner.observedStepContainers, everyElement(isNotNull), reason: 'every turn received the step container');
      expect(runner.observedStepContainers.toSet(), hasLength(1), reason: 'every turn reused the same lease');
      expect(runner.releaseCount, 1);
    });

    test('releases the held lease once when a turn fails', () async {
      final runner = _LifecycleRunner(turnBehavior: _TurnBehavior.fail);
      final executor = buildExecutor(workflowCliRunner: runner, policyResolver: containerPolicyResolver());
      addTearDown(executor.stop);

      await createStepTask('task-fail-lease', runId: 'wf-fail-lease');
      await executor.pollOnce();
      await executor.drain();
      await waitForTaskStatus(tasks, 'task-fail-lease', until: const {TaskStatus.failed});

      expect(runner.leaseCount, 1);
      expect(runner.releaseCount, 1, reason: 'the lease is released on the failure path, not leaked');
    });

    test('releases the held lease once when the turn is cancelled', () async {
      final runner = _LifecycleRunner(turnBehavior: _TurnBehavior.cancel);
      final executor = buildExecutor(workflowCliRunner: runner, policyResolver: containerPolicyResolver());
      addTearDown(executor.stop);

      await createStepTask('task-cancel-lease', runId: 'wf-cancel-lease');
      await executor.pollOnce();
      await executor.drain();
      await waitForTaskStatus(tasks, 'task-cancel-lease', until: const {TaskStatus.cancelled});

      expect(runner.leaseCount, 1);
      expect(runner.releaseCount, 1, reason: 'the lease is released on the cancel path, not leaked');
    });

    test('fails the step closed when the container authority cannot be acquired', () async {
      final runner = _LifecycleRunner(throwOnLease: true);
      final executor = buildExecutor(workflowCliRunner: runner, policyResolver: containerPolicyResolver());
      addTearDown(executor.stop);

      await createStepTask('task-closed', runId: 'wf-closed');
      await executor.pollOnce();
      await executor.drain();
      await waitForTaskStatus(tasks, 'task-closed', until: const {TaskStatus.failed});

      expect(runner.turnCount, 0, reason: 'a lease-acquire failure never falls back to host execution');
      expect(runner.releaseCount, 0, reason: 'nothing was leased, so nothing is released');
    });

    test('two steps never share a container authority', () async {
      final runner = _LifecycleRunner();
      final executor = buildExecutor(workflowCliRunner: runner, policyResolver: containerPolicyResolver());
      addTearDown(executor.stop);

      await createStepTask('task-share-a', runId: 'wf-share-a');
      await createStepTask('task-share-b', runId: 'wf-share-b');
      for (var i = 0; i < 4; i++) {
        await executor.pollOnce();
        await executor.drain();
      }
      await waitForTaskStatus(tasks, 'task-share-a', until: const {TaskStatus.review});
      await waitForTaskStatus(tasks, 'task-share-b', until: const {TaskStatus.review});

      expect(runner.leaseCount, 2);
      expect(runner.leases.toSet(), hasLength(2), reason: 'each step leases its own authority — never a shared one');
      expect(runner.releaseCount, 2);
    });
  });
}

/// A [WorkflowCliRunner] that counts step-container leases/releases and records
/// the lease each turn received, so the one-authority-per-step lifetime can be
/// asserted without Docker. Simulates the turn outcome deterministically.
final class _LifecycleRunner extends WorkflowCliRunner {
  _LifecycleRunner({this.turnBehavior = _TurnBehavior.succeed, this.throwOnLease = false})
    : super(providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')});

  final _TurnBehavior turnBehavior;
  final bool throwOnLease;
  final List<ContainerAuthorityLease> leases = [];
  final List<ContainerAuthorityLease?> observedStepContainers = [];
  int releaseCount = 0;
  int turnCount = 0;

  int get leaseCount => leases.length;

  @override
  Future<ContainerAuthorityLease?> leaseStepContainer(
    ExecutionPolicy policy, {
    required String provider,
    required String? sessionId,
    required String? taskId,
    required List<String>? allowedTools,
    required String? artifactsDir,
  }) async {
    if (throwOnLease) throw StateError('container authority acquire failed');
    if (!policy.isContainer) return null;
    final lease = _CountingLease(() => releaseCount++);
    leases.add(lease);
    return lease;
  }

  @override
  Future<WorkflowCliTurnResult> executeTurn({
    required String provider,
    required String prompt,
    required String workingDirectory,
    required ExecutionPolicy policy,
    String? taskId,
    String? sessionId,
    String? providerSessionId,
    String? model,
    String? effort,
    String? stepName,
    Duration stallTimeout = Duration.zero,
    TurnProgressAction stallAction = TurnProgressAction.warn,
    Duration? stepTimeout,
    List<String>? allowedTools,
    bool readOnly = false,
    int? maxTurns,
    RootProcessTerminationObserver? onRootProcessTerminationConfirmed,
    Map<String, dynamic>? jsonSchema,
    String? appendSystemPrompt,
    String? sandboxOverride,
    Map<String, String>? extraEnvironment,
    String? artifactsDir,
    ContainerAuthorityLease? stepContainer,
    WorkflowCliUsageBaseline usageBaseline = const WorkflowCliUsageBaseline(),
  }) async {
    turnCount++;
    observedStepContainers.add(stepContainer);
    return switch (turnBehavior) {
      _TurnBehavior.succeed => WorkflowCliTurnResult(
        providerSessionId: 'sess-$turnCount',
        responseText: 'ok',
        newInputTokens: 0,
      ),
      _TurnBehavior.fail => throw StateError('workflow turn failed'),
      _TurnBehavior.cancel => WorkflowCliTurnResult.cancelled(),
    };
  }
}

enum _TurnBehavior { succeed, fail, cancel }

final class _CountingLease implements ContainerAuthorityLease {
  _CountingLease(this._onRelease);

  final void Function() _onRelease;

  @override
  ContainerExecutor get container => throw UnimplementedError('the lifecycle lease container is never dereferenced');

  @override
  Future<void> release() async => _onRelease();
}

final class _RecordingTimeoutCliProvider implements CliProvider {
  final stepTimeouts = <Duration?>[];

  @override
  Future<void> cancelInflight({bool cancelFutureProcesses = false}) async {}

  @override
  Future<WorkflowCliTurnResult> run(CliTurnRequest request) async {
    await request.onRootProcessTerminationConfirmed?.call(true);
    stepTimeouts.add(request.stepTimeout);
    return WorkflowCliTurnResult(
      providerSessionId: 'recording-timeout-session',
      responseText: 'Done.',
      newInputTokens: 0,
    );
  }
}

final class _ConfirmationSequenceCliProvider implements CliProvider {
  _ConfirmationSequenceCliProvider(this._confirmations);

  final List<bool?> _confirmations;
  int runCount = 0;

  @override
  Future<void> cancelInflight({bool cancelFutureProcesses = false}) async {}

  @override
  Future<WorkflowCliTurnResult> run(CliTurnRequest request) async {
    final confirmation = _confirmations[runCount];
    if (confirmation != null) await request.onRootProcessTerminationConfirmed?.call(confirmation);
    runCount++;
    return WorkflowCliTurnResult(providerSessionId: 'confirmation-session', responseText: 'Done.', newInputTokens: 0);
  }
}

final class _CancellingCliProvider implements CliProvider {
  const _CancellingCliProvider();

  @override
  Future<void> cancelInflight({bool cancelFutureProcesses = false}) async {}

  @override
  Future<WorkflowCliTurnResult> run(CliTurnRequest request) async {
    await request.onRootProcessTerminationConfirmed?.call(true);
    return WorkflowCliTurnResult.cancelled();
  }
}

final class _FailingCliProvider implements CliProvider {
  const _FailingCliProvider();

  @override
  Future<void> cancelInflight({bool cancelFutureProcesses = false}) async {}

  @override
  Future<WorkflowCliTurnResult> run(CliTurnRequest request) async {
    await request.onRootProcessTerminationConfirmed?.call(true);
    throw StateError('Workflow one-shot claude command failed with exit code 1');
  }
}

final class _CancelsThenFailsCliProvider implements CliProvider {
  const _CancelsThenFailsCliProvider(this.cancelTask);

  final Future<void> Function() cancelTask;

  @override
  Future<void> cancelInflight({bool cancelFutureProcesses = false}) async {}

  @override
  Future<WorkflowCliTurnResult> run(CliTurnRequest request) async {
    await request.onRootProcessTerminationConfirmed?.call(true);
    await cancelTask();
    throw StateError('Workflow one-shot claude command failed with exit code 17');
  }
}
