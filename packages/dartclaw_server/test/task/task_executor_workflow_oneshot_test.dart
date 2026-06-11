import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_server/src/turn_runner.dart' show TurnRunner;
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'task_executor_test_support.dart';

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
        'Glob(*)',
        'Grep(*)',
        'LS(*)',
        'Read(*)',
      ],
      'deny': ['Edit(*)', 'MultiEdit(*)', 'NotebookEdit(*)', 'Write(*)'],
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
}
