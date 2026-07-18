import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_server/src/turn_runner.dart' show TurnRunner;
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show WorkflowTaskConfig, executionEnvelopeMarkerKey, executionEnvelopeVersion;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'task_executor_test_support.dart';

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
  });

  tearDown(() async {
    await ctx.tearDown(workerDispose: worker.dispose);
  });

  TaskExecutor buildExecutor({
    ProjectService? projectService,
    WorkflowCliRunner? workflowCliRunner,
    TaskEventRecorder? eventRecorder,
    TaskExecutorLimits limits = const TaskExecutorLimits(),
  }) => ctx.buildExecutor(
    projectService: projectService,
    workflowCliRunner: workflowCliRunner,
    eventRecorder: eventRecorder,
    limits: limits,
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

    final updated = await tasks.get('task-oneshot');
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

      expect(capturedEnv, isNotNull);
      // Host-computed step artifacts dir reaches the spawn env, scoped to this task.
      expect(capturedEnv!['DARTCLAW_STEP_ARTIFACTS_DIR'], stepArtifactsDir);
      // Step-artifacts env merges over, not replacing, the merge-resolve entries.
      expect(capturedEnv!['MERGE_KEY'], 'merge-val');
      // The host owns dir creation — it exists before the agent's first turn.
      expect(Directory(stepArtifactsDir).existsSync(), isTrue);
    },
  );

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

    final updated = await tasks.get('task-oneshot-cancelled');
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

    final updated = await tasks.get('task-oneshot-failed');
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

    final updated = await tasks.get('task-oneshot-cancelled-then-failed');
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

  test('provider-less workflow oneshot uses configured default provider instead of pool runner provider', () async {
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

    expect(processed, isTrue);
    expect(executable, 'codex');
    expect((await tasks.get('task-oneshot-default-provider'))!.status, TaskStatus.review);
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
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final current = await tasks.get('task-oneshot-race');
    await tasks.updateFields(
      'task-oneshot-race',
      configJson: {...?current?.configJson, '_tokenBudgetWarningFired': true},
    );

    await pollFuture;

    final updated = await tasks.get('task-oneshot-race');
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

    expect(invocation, 3);
    expect(capturedArgs[0].contains('resume'), isFalse);
    expect(capturedArgs[1], containsAll(<String>['resume', 'codex-thread-resume']));
    expect(capturedArgs[2], containsAll(<String>['resume', 'codex-thread-resume']));

    final updated = await tasks.get('task-codex-cumulative-deltas');
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

    final updated = await tasks.get('task-codex-session-baseline');
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

    final updated = await tasks.get('task-finalizer-tokens');
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

    final updated = await tasks.get('task-finalizer-nosession');
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

    final updated = await tasks.get('task-finalizer-malformed');
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
}

final class _RecordingTimeoutCliProvider implements CliProvider {
  final stepTimeouts = <Duration?>[];

  @override
  Future<void> cancelInflight({bool cancelFutureProcesses = false}) async {}

  @override
  Future<WorkflowCliTurnResult> run(CliTurnRequest request) async {
    stepTimeouts.add(request.stepTimeout);
    return WorkflowCliTurnResult(
      providerSessionId: 'recording-timeout-session',
      responseText: 'Done.',
      newInputTokens: 0,
    );
  }
}

final class _CancellingCliProvider implements CliProvider {
  const _CancellingCliProvider();

  @override
  Future<void> cancelInflight({bool cancelFutureProcesses = false}) async {}

  @override
  Future<WorkflowCliTurnResult> run(CliTurnRequest request) async => WorkflowCliTurnResult.cancelled();
}

final class _FailingCliProvider implements CliProvider {
  const _FailingCliProvider();

  @override
  Future<void> cancelInflight({bool cancelFutureProcesses = false}) async {}

  @override
  Future<WorkflowCliTurnResult> run(CliTurnRequest request) async {
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
    await cancelTask();
    throw StateError('Workflow one-shot claude command failed with exit code 17');
  }
}
