import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String sessionsDir;
  late String workspaceDir;
  late SessionService sessions;
  late MessageService messages;
  late TaskService tasks;
  late _FakeTaskWorker worker;
  late TurnManager turns;
  late ArtifactCollector collector;
  late KvService kvService;
  late Database taskDb;
  late SqliteAgentExecutionRepository agentExecutions;
  late SqliteWorkflowRunRepository workflowRuns;
  late SqliteWorkflowStepExecutionRepository workflowStepExecutions;
  late SqliteExecutionRepositoryTransactor executionTransactor;
  late TaskExecutor executor;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_task_executor_test_');
    sessionsDir = p.join(tempDir.path, 'sessions');
    // Workspace must NOT be inside dataDir — ArtifactCollector excludes
    // files within dataDir to prevent collecting internal metadata.
    workspaceDir = Directory.systemTemp.createTempSync('dartclaw_task_ws_').path;
    Directory(sessionsDir).createSync(recursive: true);

    sessions = SessionService(baseDir: sessionsDir);
    messages = MessageService(baseDir: sessionsDir);
    taskDb = sqlite3.openInMemory();
    agentExecutions = SqliteAgentExecutionRepository(taskDb);
    workflowRuns = SqliteWorkflowRunRepository(taskDb);
    workflowStepExecutions = SqliteWorkflowStepExecutionRepository(taskDb);
    executionTransactor = SqliteExecutionRepositoryTransactor(taskDb);
    tasks = TaskService(
      SqliteTaskRepository(taskDb),
      agentExecutionRepository: agentExecutions,
      executionTransactor: executionTransactor,
    );
    worker = _FakeTaskWorker();
    turns = TurnManager(
      messages: messages,
      worker: worker,
      behavior: BehaviorFileService(workspaceDir: workspaceDir),
      sessions: sessions,
    );
    kvService = KvService(filePath: p.join(tempDir.path, 'kv.json'));
    collector = ArtifactCollector(
      tasks: tasks,
      messages: messages,
      sessionsDir: sessionsDir,
      dataDir: tempDir.path,
      workspaceDir: workspaceDir,
    );
    executor = TaskExecutor(
      tasks: tasks,
      sessions: sessions,
      messages: messages,
      turns: turns,
      artifactCollector: collector,
      workflowRunRepository: workflowRuns,
      workflowStepExecutionRepository: workflowStepExecutions,
      pollInterval: const Duration(milliseconds: 10),
    );
  });

  tearDown(() async {
    await executor.stop();
    await tasks.dispose();
    await messages.dispose();
    await kvService.dispose();
    await worker.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    final wsDir = Directory(workspaceDir);
    if (wsDir.existsSync()) wsDir.deleteSync(recursive: true);
  });

  TaskExecutor buildExecutor({
    Future<void> Function(String taskId)? onAutoAccept,
    ProjectService? projectService,
    WorkflowCliRunner? workflowCliRunner,
    TaskEventRecorder? eventRecorder,
    Duration pollInterval = const Duration(milliseconds: 10),
  }) {
    final namedArgs = <Symbol, dynamic>{
      #tasks: tasks,
      #sessions: sessions,
      #messages: messages,
      #turns: turns,
      #artifactCollector: collector,
      #workflowRunRepository: workflowRuns,
      #workflowStepExecutionRepository: workflowStepExecutions,
      #kvService: kvService,
      #pollInterval: pollInterval,
    };
    if (onAutoAccept != null) {
      namedArgs[#onAutoAccept] = onAutoAccept;
    }
    if (projectService != null) {
      namedArgs[#projectService] = projectService;
    }
    if (workflowCliRunner != null) {
      namedArgs[#workflowCliRunner] = workflowCliRunner;
    }
    if (eventRecorder != null) {
      namedArgs[#eventRecorder] = eventRecorder;
    }
    return Function.apply(TaskExecutor.new, const [], namedArgs) as TaskExecutor;
  }

  Future<void> seedWorkflowExecution(
    String taskId, {
    String? agentExecutionId,
    required String workflowRunId,
    String stepId = 'plan',
    String stepType = 'coding',
    Map<String, dynamic>? git,
    Map<String, dynamic>? structuredSchema,
    Map<String, dynamic>? structuredOutput,
    List<String>? followUpPrompts,
    Map<String, dynamic>? externalArtifactMount,
    int? mapIterationIndex,
    int? mapIterationTotal,
    String? providerSessionId,
    String? workspaceDirOverride,
  }) async {
    final executionId = agentExecutionId ?? 'ae-$taskId';
    final existingExecution = await agentExecutions.get(executionId);
    if (existingExecution == null) {
      await agentExecutions.create(
        AgentExecution(id: executionId, provider: 'claude', workspaceDir: workspaceDirOverride ?? workspaceDir),
      );
    } else if (workspaceDirOverride != null && existingExecution.workspaceDir != workspaceDirOverride) {
      await agentExecutions.update(existingExecution.copyWith(workspaceDir: workspaceDirOverride));
    }
    final existingRun = await workflowRuns.getById(workflowRunId);
    if (existingRun == null) {
      final now = DateTime.now();
      await workflowRuns.insert(
        WorkflowRun(
          id: workflowRunId,
          definitionName: 'task-executor-test',
          status: WorkflowRunStatus.running,
          startedAt: now,
          updatedAt: now,
          definitionJson: const {'name': 'task-executor-test', 'steps': []},
          variablesJson: const {'PROJECT': '_local'},
        ),
      );
    }
    await workflowStepExecutions.create(
      WorkflowStepExecution(
        taskId: taskId,
        agentExecutionId: executionId,
        workflowRunId: workflowRunId,
        stepIndex: 0,
        stepId: stepId,
        stepType: stepType,
        gitJson: git == null ? null : jsonEncode(git),
        providerSessionId: providerSessionId,
        structuredSchemaJson: structuredSchema == null ? null : jsonEncode(structuredSchema),
        structuredOutputJson: structuredOutput == null ? null : jsonEncode(structuredOutput),
        followUpPromptsJson: followUpPrompts == null ? null : jsonEncode(followUpPrompts),
        externalArtifactMount: externalArtifactMount == null ? null : jsonEncode(externalArtifactMount),
        mapIterationIndex: mapIterationIndex,
        mapIterationTotal: mapIterationTotal,
      ),
    );
  }

  test('executes queued tasks into review with task session and artifacts', () async {
    worker.responseText = 'Done.';
    worker.onTurn = (sessionId) {
      File(p.join(workspaceDir, 'output.md')).writeAsStringSync('# Output');
    };

    await tasks.create(
      id: 'task-1',
      title: 'Write summary',
      description: 'Create a markdown summary.',
      type: TaskType.research,
      autoStart: true,
      acceptanceCriteria: 'Produce output.md',
      now: DateTime.parse('2026-03-10T10:00:00Z'),
    );

    final processed = await executor.pollOnce();

    expect(processed, isTrue);
    final updated = await tasks.get('task-1');
    expect(updated!.status, TaskStatus.review);
    expect(updated.sessionId, isNotNull);

    final taskSessions = await sessions.listSessions(type: SessionType.task);
    expect(taskSessions, hasLength(1));
    final taskSession = taskSessions.single;
    expect(taskSession.channelKey, SessionKey.taskSession(taskId: 'task-1'));

    final defaultSessions = await sessions.listSessions();
    expect(defaultSessions.map((session) => session.type), isNot(contains(SessionType.task)));

    final taskMessages = await messages.getMessages(taskSession.id);
    expect(taskMessages.first.role, 'user');
    expect(taskMessages.first.content, contains('## Task: Write summary'));
    expect(taskMessages.first.content, contains('### Acceptance Criteria'));
    expect(taskMessages.last.role, 'assistant');
    expect(taskMessages.last.content, 'Done.');

    final artifacts = await tasks.listArtifacts('task-1');
    expect(artifacts, hasLength(1));
    expect(artifacts.single.name, 'output.md');
    expect(File(artifacts.single.path).readAsStringSync(), '# Output');
  });

  test('reuses the same session and injects push-back feedback on rerun', () async {
    worker.responseText = 'Initial output';
    await tasks.create(
      id: 'task-2',
      title: 'Automation task',
      description: 'Run something twice.',
      type: TaskType.automation,
      autoStart: true,
      now: DateTime.parse('2026-03-10T10:00:00Z'),
    );

    await executor.pollOnce();
    final reviewed = await tasks.get('task-2');
    final firstSessionId = reviewed!.sessionId!;

    final nextConfig = Map<String, dynamic>.from(reviewed.configJson)
      ..['pushBackCount'] = 0
      ..['pushBackComment'] = 'Address the missing detail.';
    await tasks.updateFields('task-2', configJson: nextConfig);
    await tasks.transition('task-2', TaskStatus.queued);

    worker.responseText = 'Updated output';
    await executor.pollOnce();

    final rerun = await tasks.get('task-2');
    expect(rerun!.status, TaskStatus.review);
    expect(rerun.sessionId, firstSessionId);
    expect(rerun.configJson['pushBackCount'], 1);
    expect(rerun.configJson.containsKey('pushBackComment'), isFalse);

    final taskMessages = await messages.getMessages(firstSessionId);
    final pushBackMessage = taskMessages.lastWhere((message) => message.role == 'user');
    expect(pushBackMessage.content, contains('## Push-back Feedback'));
    expect(pushBackMessage.content, contains('Address the missing detail.'));
  });

  test('passes model override through to task execution', () async {
    worker.responseText = 'Done.';
    await tasks.create(
      id: 'task-model',
      title: 'Model override task',
      description: 'Use a different model.',
      type: TaskType.research,
      autoStart: true,
      configJson: const {'model': 'opus'},
    );

    await executor.pollOnce();

    expect(worker.lastModel, 'opus');
    expect((await tasks.get('task-model'))!.status, TaskStatus.review);
  });

  test('workflow oneshot mode executes prompt chain and stores structured payload', () async {
    final cliRunner = WorkflowCliRunner(
      providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')},
      processStarter: (exe, args, {workingDirectory, environment}) async {
        final payload = args.contains('--json-schema')
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
              });
        return Process.start('/bin/sh', ['-lc', "printf '%s' '${payload.replaceAll("'", "'\\''")}'"]);
      },
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
    final cliRunner = WorkflowCliRunner(
      providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')},
      processStarter: (exe, args, {workingDirectory, environment}) async {
        capturedArgs.add(List<String>.from(args));
        final payload = jsonEncode({
          'session_id': 'cli-session-inline',
          'result': 'Working...\n<workflow-context>\n${jsonEncode(inlinePayload)}\n</workflow-context>',
        });
        return Process.start('/bin/sh', ['-lc', "printf '%s' '${payload.replaceAll("'", "'\\''")}'"]);
      },
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
    final cliRunner = WorkflowCliRunner(
      providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')},
      processStarter: (exe, args, {workingDirectory, environment}) async {
        capturedArgs.add(List<String>.from(args));
        final payload = args.contains('--json-schema')
            ? jsonEncode({
                'session_id': 'cli-session-extract',
                'structured_output': {
                  'verdict': {'pass': false},
                },
              })
            : jsonEncode({'session_id': 'cli-session-extract', 'result': 'Analysis without any context block.'});
        return Process.start('/bin/sh', ['-lc', "printf '%s' '${payload.replaceAll("'", "'\\''")}'"]);
      },
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
    final cliRunner = WorkflowCliRunner(
      providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')},
      processStarter: (exe, args, {workingDirectory, environment}) async {
        capturedArgs.add(List<String>.from(args));
        final payload = args.contains('--json-schema')
            ? jsonEncode({
                'session_id': 'cli-session-partial',
                'structured_output': {'summary': 'Fallback summary', 'confidence': 7},
              })
            : jsonEncode({
                'session_id': 'cli-session-partial',
                'result': '<workflow-context>{"summary":"Inline summary"}</workflow-context>',
              });
        return Process.start('/bin/sh', ['-lc', "printf '%s' '${payload.replaceAll("'", "'\\''")}'"]);
      },
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
    final cliRunner = WorkflowCliRunner(
      providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')},
      processStarter: (exe, args, {workingDirectory, environment}) async {
        capturedArgs.add(List<String>.from(args));
        final payload = args.contains('--json-schema')
            ? jsonEncode({
                'session_id': 'cli-session-append',
                'structured_output': {
                  'verdict': {'pass': true},
                },
              })
            : jsonEncode({'session_id': 'cli-session-append', 'result': 'No context block here.'});
        return Process.start('/bin/sh', ['-lc', "printf '%s' '${payload.replaceAll("'", "'\\''")}'"]);
      },
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

  test('invokes auto-accept callback with the task id after completion when provided', () async {
    final calls = <String>[];
    final autoAcceptExecutor = buildExecutor(
      onAutoAccept: (taskId) async {
        calls.add(taskId);
      },
    );
    addTearDown(autoAcceptExecutor.stop);

    worker.responseText = 'Done.';
    await tasks.create(
      id: 'task-auto-accept',
      title: 'Auto accept task',
      description: 'Should invoke the completion callback.',
      type: TaskType.research,
      autoStart: true,
    );

    await autoAcceptExecutor.pollOnce();

    expect(calls, ['task-auto-accept']);
    expect((await tasks.get('task-auto-accept'))!.status, TaskStatus.review);
  });

  test('swallows auto-accept callback errors and leaves the task in review', () async {
    final autoAcceptExecutor = buildExecutor(
      onAutoAccept: (taskId) async {
        throw StateError('auto-accept failed for $taskId');
      },
    );
    addTearDown(autoAcceptExecutor.stop);

    worker.responseText = 'Done.';
    await tasks.create(
      id: 'task-auto-accept-error',
      title: 'Auto accept error task',
      description: 'Should survive callback failures.',
      type: TaskType.research,
      autoStart: true,
    );

    await autoAcceptExecutor.pollOnce();

    expect((await tasks.get('task-auto-accept-error'))!.status, TaskStatus.review);
  });

  test('fails workflow-owned tasks when auto-accept callback errors', () async {
    final autoAcceptExecutor = buildExecutor(
      onAutoAccept: (taskId) async {
        throw StateError('auto-accept failed for $taskId');
      },
      workflowCliRunner: _successWorkflowCliRunner(),
    );
    addTearDown(autoAcceptExecutor.stop);

    worker.responseText = 'Done.';
    await tasks.create(
      id: 'task-auto-accept-workflow-error',
      title: 'Workflow auto accept error task',
      description: 'Should fail instead of hanging the workflow.',
      type: TaskType.research,
      autoStart: true,
      agentExecutionId: 'ae-task-auto-accept-workflow-error',
      workflowRunId: 'run-123',
    );
    await seedWorkflowExecution(
      'task-auto-accept-workflow-error',
      agentExecutionId: 'ae-task-auto-accept-workflow-error',
      workflowRunId: 'run-123',
      stepType: 'research',
    );

    await autoAcceptExecutor.pollOnce();

    expect((await tasks.get('task-auto-accept-workflow-error'))!.status, TaskStatus.review);
  });

  test('skips auto-accept for workflow git tasks so workflow promotion owns publish', () async {
    final calls = <String>[];
    final autoAcceptExecutor = buildExecutor(
      onAutoAccept: (taskId) async {
        calls.add(taskId);
      },
      workflowCliRunner: _successWorkflowCliRunner(),
    );
    addTearDown(autoAcceptExecutor.stop);

    worker.responseText = 'Done.';
    await tasks.create(
      id: 'task-auto-accept-workflow-git',
      title: 'Workflow git task',
      description: 'Workflow-owned git tasks should stay in review for promotion.',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-task-auto-accept-workflow-git',
      workflowRunId: 'run-123',
    );
    await seedWorkflowExecution(
      'task-auto-accept-workflow-git',
      agentExecutionId: 'ae-task-auto-accept-workflow-git',
      workflowRunId: 'run-123',
      git: const {'worktree': 'per-map-item', 'promotion': 'merge'},
    );

    await autoAcceptExecutor.pollOnce();

    expect(calls, isEmpty);
    expect((await tasks.get('task-auto-accept-workflow-git'))!.status, TaskStatus.review);
  });

  test('does not invoke auto-accept callback when reviewMode completes directly to accepted', () async {
    final calls = <String>[];
    final autoAcceptExecutor = buildExecutor(
      onAutoAccept: (taskId) async {
        calls.add(taskId);
      },
    );
    addTearDown(autoAcceptExecutor.stop);

    worker.responseText = 'Done.';
    await tasks.create(
      id: 'task-coding-only-accepted',
      title: 'Coding-only accepted task',
      description: 'Non-coding tasks with coding-only reviewMode should skip auto-accept.',
      type: TaskType.research,
      autoStart: true,
      configJson: const {'reviewMode': 'coding-only'},
    );

    await autoAcceptExecutor.pollOnce();

    expect(calls, isEmpty);
    expect((await tasks.get('task-coding-only-accepted'))!.status, TaskStatus.accepted);
  });

  test('fails completed tasks that exceed token budget and preserves artifacts', () async {
    final calls = <String>[];
    final budgetExecutor = buildExecutor(
      onAutoAccept: (taskId) async {
        calls.add(taskId);
      },
    );
    addTearDown(budgetExecutor.stop);

    worker.responseText = 'Too expensive';
    worker.inputTokens = 90;
    worker.outputTokens = 40;
    worker.onTurn = (sessionId) {
      File(p.join(workspaceDir, 'budget.md')).writeAsStringSync('# Partial output');
    };
    await tasks.create(
      id: 'task-budget',
      title: 'Budget task',
      description: 'Should fail when usage exceeds budget.',
      type: TaskType.research,
      autoStart: true,
      configJson: const {'tokenBudget': 100},
    );

    await budgetExecutor.pollOnce();

    final failed = await tasks.get('task-budget');
    expect(failed!.status, TaskStatus.failed);
    expect(failed.configJson['errorSummary'], 'Token budget exceeded: used 130 tokens against a limit of 100');
    final artifacts = await tasks.listArtifacts('task-budget');
    expect(artifacts, hasLength(1));
    expect(artifacts.single.name, 'budget.md');
    expect(calls, isEmpty);
  });

  test('marks queued tasks as failed when the agent turn crashes', () async {
    final calls = <String>[];
    final failingExecutor = buildExecutor(
      onAutoAccept: (taskId) async {
        calls.add(taskId);
      },
    );
    addTearDown(failingExecutor.stop);

    worker.shouldFail = true;
    await tasks.create(
      id: 'task-3',
      title: 'Failing task',
      description: 'This should fail.',
      type: TaskType.automation,
      autoStart: true,
    );

    await failingExecutor.pollOnce();

    final failed = await tasks.get('task-3');
    expect(failed!.status, TaskStatus.failed);
    expect(failed.sessionId, isNotNull);
    expect(failed.configJson['errorSummary'], 'Turn execution failed');
    expect(calls, isEmpty);

    final taskSession = (await sessions.listSessions(type: SessionType.task)).single;
    final taskMessages = await messages.getMessages(taskSession.id);
    expect(taskMessages.last.content, contains('[Turn failed]'));
  });

  test('does not invoke auto-accept when a task is cancelled during execution', () async {
    final calls = <String>[];
    final cancellingExecutor = buildExecutor(
      onAutoAccept: (taskId) async {
        calls.add(taskId);
      },
    );
    addTearDown(cancellingExecutor.stop);

    worker.responseText = 'Done.';
    worker.beforeComplete = (_) async {
      await tasks.transition('task-cancelled', TaskStatus.cancelled);
    };
    await tasks.create(
      id: 'task-cancelled',
      title: 'Cancelled task',
      description: 'Should never reach auto-accept.',
      type: TaskType.automation,
      autoStart: true,
    );

    await cancellingExecutor.pollOnce();

    expect((await tasks.get('task-cancelled'))!.status, TaskStatus.cancelled);
    expect(calls, isEmpty);
  });

  test('does not throw when a workflow one-shot task is cancelled before token mirroring', () async {
    final cancellingExecutor = buildExecutor();
    addTearDown(cancellingExecutor.stop);
    final records = <LogRecord>[];
    final sub = Logger('TaskExecutor').onRecord.listen(records.add);
    addTearDown(sub.cancel);

    worker.responseText = 'Done.';
    worker.beforeComplete = (_) async {
      await tasks.transition('task-workflow-cancelled', TaskStatus.cancelled);
    };
    await tasks.create(
      id: 'task-workflow-cancelled',
      title: 'Cancelled workflow task',
      description: 'Should skip token mirroring once cancelled.',
      type: TaskType.automation,
      autoStart: true,
      workflowRunId: 'run-cancelled',
      agentExecutionId: 'ae-task-workflow-cancelled',
      configJson: const {'_workflowStructuredMode': false},
    );
    await seedWorkflowExecution(
      'task-workflow-cancelled',
      workflowRunId: 'run-cancelled',
      agentExecutionId: 'ae-task-workflow-cancelled',
      git: const {'worktree': 'shared'},
    );

    await cancellingExecutor.pollOnce();

    final task = await tasks.get('task-workflow-cancelled');
    expect(task?.status.terminal, isTrue);
    expect(records.any((record) => record.message.contains('Cannot update terminal task')), isFalse);
  });

  test('processes queued tasks in FIFO order', () async {
    worker.responseText = 'ok';
    await tasks.create(
      id: 'task-old',
      title: 'Older',
      description: 'first',
      type: TaskType.automation,
      autoStart: true,
      now: DateTime.parse('2026-03-10T10:00:00Z'),
    );
    await tasks.create(
      id: 'task-new',
      title: 'Newer',
      description: 'second',
      type: TaskType.automation,
      autoStart: true,
      now: DateTime.parse('2026-03-10T10:01:00Z'),
    );

    await executor.pollOnce();

    expect((await tasks.get('task-old'))!.status, TaskStatus.review);
    expect((await tasks.get('task-new'))!.status, TaskStatus.queued);
  });

  test('keeps project-backed tasks queued while the project is still cloning', () async {
    worker.responseText = 'Done.';
    final projectService = FakeProjectService(
      projects: [
        Project(
          id: 'my-app',
          name: 'My App',
          remoteUrl: 'git@github.com:acme/my-app.git',
          localPath: '/projects/my-app',
          defaultBranch: 'main',
          status: ProjectStatus.cloning,
          createdAt: DateTime.parse('2026-03-10T09:00:00Z'),
        ),
      ],
      includeLocalProjectInGetAll: false,
      defaultProjectId: 'my-app',
    );
    final projectExecutor = TaskExecutor(
      tasks: tasks,
      sessions: sessions,
      messages: messages,
      turns: turns,
      artifactCollector: collector,
      workflowStepExecutionRepository: workflowStepExecutions,

      projectService: projectService,
      pollInterval: const Duration(milliseconds: 10),
    );
    addTearDown(projectExecutor.stop);

    await tasks.create(
      id: 'task-project',
      title: 'Project task',
      description: 'Wait for clone.',
      type: TaskType.research,
      autoStart: true,
      projectId: 'my-app',
    );
    await tasks.create(
      id: 'task-ready',
      title: 'Ready task',
      description: 'Still runnable.',
      type: TaskType.research,
      autoStart: true,
    );

    final processed = await projectExecutor.pollOnce();

    expect(processed, isTrue);
    expect((await tasks.get('task-project'))!.status, TaskStatus.queued);
    expect((await tasks.get('task-ready'))!.status, TaskStatus.review);
  });

  test('fails queued project-backed tasks when the project clone has errored', () async {
    final projectService = FakeProjectService(
      projects: [
        Project(
          id: 'my-app',
          name: 'My App',
          remoteUrl: 'git@github.com:acme/my-app.git',
          localPath: '/projects/my-app',
          defaultBranch: 'main',
          status: ProjectStatus.error,
          errorMessage: 'Authentication denied',
          createdAt: DateTime.parse('2026-03-10T09:00:00Z'),
        ),
      ],
      includeLocalProjectInGetAll: false,
      defaultProjectId: 'my-app',
    );
    final projectExecutor = TaskExecutor(
      tasks: tasks,
      sessions: sessions,
      messages: messages,
      turns: turns,
      artifactCollector: collector,
      workflowStepExecutionRepository: workflowStepExecutions,

      projectService: projectService,
      pollInterval: const Duration(milliseconds: 10),
    );
    addTearDown(projectExecutor.stop);

    await tasks.create(
      id: 'task-project-failed',
      title: 'Project task',
      description: 'Should fail.',
      type: TaskType.research,
      autoStart: true,
      projectId: 'my-app',
    );

    final processed = await projectExecutor.pollOnce();

    expect(processed, isTrue);
    final failed = await tasks.get('task-project-failed');
    expect(failed!.status, TaskStatus.failed);
    expect(failed.configJson['errorSummary'], contains('failed to clone'));
    expect(failed.configJson['errorSummary'], contains('Authentication denied'));
  });

  test('workflow coding tasks pass configured _baseRef to project freshness and worktree creation', () async {
    worker.responseText = 'Done.';
    final projectService = FakeProjectService(
      projects: [
        Project(
          id: 'my-app',
          name: 'My App',
          remoteUrl: 'git@github.com:acme/my-app.git',
          localPath: '/projects/my-app',
          defaultBranch: 'main',
          status: ProjectStatus.ready,
          createdAt: DateTime.parse('2026-03-10T09:00:00Z'),
        ),
      ],
      includeLocalProjectInGetAll: false,
      defaultProjectId: 'my-app',
    );
    final worktreeManager = _CapturingWorktreeManager();
    final projectExecutor = TaskExecutor(
      tasks: tasks,
      sessions: sessions,
      messages: messages,
      turns: turns,
      artifactCollector: collector,
      workflowStepExecutionRepository: workflowStepExecutions,
      worktreeManager: worktreeManager,
      projectService: projectService,
      pollInterval: const Duration(milliseconds: 10),
    );
    addTearDown(projectExecutor.stop);

    await tasks.create(
      id: 'task-workflow-branch',
      title: 'Workflow coding task',
      description: 'Should use workflow branch base ref.',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-task-workflow-branch',
      projectId: 'my-app',
      workflowRunId: 'run-123',
      configJson: const {'_baseRef': 'release/0.16'},
    );
    await seedWorkflowExecution(
      'task-workflow-branch',
      agentExecutionId: 'ae-task-workflow-branch',
      workflowRunId: 'run-123',
      stepType: 'coding',
    );

    final processed = await projectExecutor.pollOnce();

    expect(processed, isTrue);
    final ensureFreshCall = projectService.ensureFreshCalls.single;
    expect(ensureFreshCall.ref, 'release/0.16');
    expect(ensureFreshCall.strict, isTrue);
    expect(worktreeManager.lastBaseRef, 'release/0.16');
  });

  test('workflow local coding task defaults _baseRef to current symbolic HEAD branch', () async {
    worker.responseText = 'Done.';

    final localRepo = Directory.systemTemp.createTempSync('task_executor_local_repo_');
    addTearDown(() {
      if (localRepo.existsSync()) localRepo.deleteSync(recursive: true);
    });
    await Process.run('git', ['init'], workingDirectory: localRepo.path);
    await Process.run('git', ['checkout', '-b', 'develop'], workingDirectory: localRepo.path);
    File(p.join(localRepo.path, 'README.md')).writeAsStringSync('local');
    await Process.run('git', ['add', '.'], workingDirectory: localRepo.path);
    await Process.run(
      'git',
      ['commit', '-m', 'init', '--no-gpg-sign'],
      workingDirectory: localRepo.path,
      environment: {
        'GIT_AUTHOR_NAME': 'Test',
        'GIT_AUTHOR_EMAIL': 'test@test.com',
        'GIT_COMMITTER_NAME': 'Test',
        'GIT_COMMITTER_EMAIL': 'test@test.com',
      },
    );

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
    final worktreeManager = _CapturingWorktreeManager();
    final projectExecutor = TaskExecutor(
      tasks: tasks,
      sessions: sessions,
      messages: messages,
      turns: turns,
      artifactCollector: collector,
      workflowStepExecutionRepository: workflowStepExecutions,
      worktreeManager: worktreeManager,
      projectService: projectService,
      pollInterval: const Duration(milliseconds: 10),
    );
    addTearDown(projectExecutor.stop);

    await tasks.create(
      id: 'task-workflow-local-branch',
      title: 'Workflow local coding task',
      description: 'Should derive branch from local symbolic HEAD.',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-task-workflow-local-branch',
      workflowRunId: 'run-local',
    );
    await seedWorkflowExecution(
      'task-workflow-local-branch',
      agentExecutionId: 'ae-task-workflow-local-branch',
      workflowRunId: 'run-local',
      stepType: 'coding',
    );

    final processed = await projectExecutor.pollOnce();

    expect(processed, isTrue);
    final ensureFreshCall = projectService.ensureFreshCalls.single;
    expect(ensureFreshCall.ref, 'develop');
    expect(ensureFreshCall.strict, isTrue);
    expect(worktreeManager.lastBaseRef, 'develop');
  });

  test('shared workflow coding tasks attach to workflow-owned branch/worktree', () async {
    worker.responseText = 'Done.';
    final projectService = FakeProjectService(
      projects: [
        Project(
          id: 'my-app',
          name: 'My App',
          remoteUrl: 'git@github.com:acme/my-app.git',
          localPath: '/projects/my-app',
          defaultBranch: 'main',
          status: ProjectStatus.ready,
          createdAt: DateTime.parse('2026-03-10T09:00:00Z'),
        ),
      ],
      includeLocalProjectInGetAll: false,
      defaultProjectId: 'my-app',
    );
    final worktreeManager = _CapturingWorktreeManager();
    final projectExecutor = TaskExecutor(
      tasks: tasks,
      sessions: sessions,
      messages: messages,
      turns: turns,
      artifactCollector: collector,
      workflowStepExecutionRepository: workflowStepExecutions,
      worktreeManager: worktreeManager,
      projectService: projectService,
      pollInterval: const Duration(milliseconds: 10),
    );
    addTearDown(projectExecutor.stop);

    const integrationBranch = 'dartclaw/workflow/run123/integration';
    await tasks.create(
      id: 'task-shared-1',
      title: 'Shared workflow step',
      description: 'Should attach to workflow-owned branch.',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-task-shared-1',
      projectId: 'my-app',
      workflowRunId: 'run-123',
      configJson: const {'_baseRef': integrationBranch},
    );
    await seedWorkflowExecution(
      'task-shared-1',
      agentExecutionId: 'ae-task-shared-1',
      workflowRunId: 'run-123',
      git: const {'worktree': 'shared'},
    );

    await projectExecutor.pollOnce();

    final first = await tasks.get('task-shared-1');
    expect(worktreeManager.lastCreateBranch, isFalse);
    expect(worktreeManager.createCallCount, 1);
    expect(first?.worktreeJson?['branch'], integrationBranch);

    await tasks.create(
      id: 'task-shared-2',
      title: 'Shared workflow step 2',
      description: 'Must reuse same workflow worktree.',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-task-shared-2',
      projectId: 'my-app',
      workflowRunId: 'run-123',
      configJson: const {'_baseRef': integrationBranch},
    );
    await seedWorkflowExecution(
      'task-shared-2',
      agentExecutionId: 'ae-task-shared-2',
      workflowRunId: 'run-123',
      git: const {'worktree': 'shared'},
    );
    await projectExecutor.pollOnce();
    final second = await tasks.get('task-shared-2');
    expect(worktreeManager.createCallCount, 1, reason: 'shared workflow must reuse the same workflow worktree');
    expect(second?.worktreeJson?['path'], first?.worktreeJson?['path']);
    expect(second?.worktreeJson?['branch'], integrationBranch);
  });

  test('shared workflow worktree binding persists on the workflow run', () async {
    worker.responseText = 'Done.';
    final worktreeManager = _CapturingWorktreeManager();
    final projectExecutor = TaskExecutor(
      tasks: tasks,
      sessions: sessions,
      messages: messages,
      turns: turns,
      artifactCollector: collector,
      workflowRunRepository: workflowRuns,
      workflowStepExecutionRepository: workflowStepExecutions,
      worktreeManager: worktreeManager,
      pollInterval: const Duration(milliseconds: 10),
    );
    addTearDown(projectExecutor.stop);

    const workflowRunId = 'run-binding';
    await tasks.create(
      id: 'task-shared-binding',
      title: 'Shared workflow step',
      description: 'Persists its shared worktree binding.',
      type: TaskType.coding,
      autoStart: true,
      workflowRunId: workflowRunId,
      agentExecutionId: 'ae-task-shared-binding',
      configJson: const {'_baseRef': 'dartclaw/workflow/runbinding/integration'},
    );
    await seedWorkflowExecution(
      'task-shared-binding',
      workflowRunId: workflowRunId,
      agentExecutionId: 'ae-task-shared-binding',
      git: const {'worktree': 'shared'},
    );

    await projectExecutor.pollOnce();

    final binding = await workflowRuns.getWorktreeBinding(workflowRunId);
    expect(binding, isNotNull);
    expect(binding?.key, workflowRunId);
    expect(binding?.path, '/tmp/worktrees/wf-$workflowRunId');
    expect(binding?.branch, 'dartclaw/workflow/runbinding/integration');
    expect(binding?.workflowRunId, workflowRunId);
  });

  test('hydrated shared workflow worktree binding reuses the persisted worktree without create()', () async {
    worker.responseText = 'Done.';
    final worktreeManager = _CapturingWorktreeManager();
    final projectExecutor = TaskExecutor(
      tasks: tasks,
      sessions: sessions,
      messages: messages,
      turns: turns,
      artifactCollector: collector,
      workflowRunRepository: workflowRuns,
      workflowStepExecutionRepository: workflowStepExecutions,
      worktreeManager: worktreeManager,
      pollInterval: const Duration(milliseconds: 10),
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
    projectExecutor.hydrateWorkflowSharedWorktreeBinding(binding, workflowRunId: workflowRunId);

    await tasks.create(
      id: 'task-shared-hydrated',
      title: 'Hydrated shared workflow step',
      description: 'Must reuse hydrated binding.',
      type: TaskType.coding,
      autoStart: true,
      workflowRunId: workflowRunId,
      agentExecutionId: 'ae-task-shared-hydrated',
      configJson: const {'_baseRef': 'dartclaw/workflow/runhydrated/integration'},
    );
    await seedWorkflowExecution(
      'task-shared-hydrated',
      workflowRunId: workflowRunId,
      agentExecutionId: 'ae-task-shared-hydrated',
      git: const {'worktree': 'shared'},
    );

    await projectExecutor.pollOnce();

    final task = await tasks.get('task-shared-hydrated');
    expect(worktreeManager.createCallCount, 0);
    expect(task?.worktreeJson?['path'], binding.path);
    expect(task?.worktreeJson?['branch'], binding.branch);
  });

  test('inline workflow coding tasks reuse the project checkout without creating a worktree', () async {
    worker.responseText = 'Done.';

    final localRepo = Directory.systemTemp.createTempSync('task_executor_inline_repo_');
    addTearDown(() {
      if (localRepo.existsSync()) localRepo.deleteSync(recursive: true);
    });
    await Process.run('git', ['init'], workingDirectory: localRepo.path);
    await Process.run('git', ['checkout', '-b', 'main'], workingDirectory: localRepo.path);
    File(p.join(localRepo.path, 'README.md')).writeAsStringSync('inline');
    await Process.run('git', ['add', '.'], workingDirectory: localRepo.path);
    await Process.run(
      'git',
      ['commit', '-m', 'init', '--no-gpg-sign'],
      workingDirectory: localRepo.path,
      environment: {
        'GIT_AUTHOR_NAME': 'Test',
        'GIT_AUTHOR_EMAIL': 'test@test.com',
        'GIT_COMMITTER_NAME': 'Test',
        'GIT_COMMITTER_EMAIL': 'test@test.com',
      },
    );
    const integrationBranch = 'dartclaw/workflow/runinline';
    await Process.run('git', ['checkout', '-b', integrationBranch], workingDirectory: localRepo.path);
    await Process.run('git', ['checkout', 'main'], workingDirectory: localRepo.path);

    final projectService = FakeProjectService(
      projects: [
        Project(
          id: 'my-app',
          name: 'My App',
          remoteUrl: '',
          localPath: localRepo.path,
          defaultBranch: 'main',
          status: ProjectStatus.ready,
          createdAt: DateTime.parse('2026-03-10T09:00:00Z'),
        ),
      ],
      includeLocalProjectInGetAll: false,
      defaultProjectId: 'my-app',
    );
    final worktreeManager = _CapturingWorktreeManager();
    final projectExecutor = TaskExecutor(
      tasks: tasks,
      sessions: sessions,
      messages: messages,
      turns: turns,
      artifactCollector: collector,
      workflowStepExecutionRepository: workflowStepExecutions,
      worktreeManager: worktreeManager,
      projectService: projectService,
      pollInterval: const Duration(milliseconds: 10),
    );
    addTearDown(projectExecutor.stop);

    await tasks.create(
      id: 'task-inline-workflow',
      title: 'Inline workflow step',
      description: 'Should run on the workflow branch without a separate worktree.',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-task-inline-workflow',
      projectId: 'my-app',
      workflowRunId: 'run-inline',
      configJson: const {'_baseRef': integrationBranch},
    );
    await seedWorkflowExecution(
      'task-inline-workflow',
      agentExecutionId: 'ae-task-inline-workflow',
      workflowRunId: 'run-inline',
      git: const {'worktree': 'inline'},
    );

    await projectExecutor.pollOnce();

    final task = await tasks.get('task-inline-workflow');
    final head = await Process.run('git', [
      'symbolic-ref',
      '--quiet',
      '--short',
      'HEAD',
    ], workingDirectory: localRepo.path);
    expect(worktreeManager.createCallCount, 0);
    expect(task?.worktreeJson, isNull);
    expect((head.stdout as String).trim(), integrationBranch);
  });

  test('per-map-item post-map coding step attaches to integration branch, map iteration does not', () async {
    worker.responseText = 'Done.';
    final projectService = FakeProjectService(
      projects: [
        Project(
          id: 'my-app',
          name: 'My App',
          remoteUrl: 'git@github.com:acme/my-app.git',
          localPath: '/projects/my-app',
          defaultBranch: 'main',
          status: ProjectStatus.ready,
          createdAt: DateTime.parse('2026-03-10T09:00:00Z'),
        ),
      ],
      includeLocalProjectInGetAll: false,
      defaultProjectId: 'my-app',
    );
    final worktreeManager = _CapturingWorktreeManager();
    final projectExecutor = TaskExecutor(
      tasks: tasks,
      sessions: sessions,
      messages: messages,
      turns: turns,
      artifactCollector: collector,
      workflowStepExecutionRepository: workflowStepExecutions,
      worktreeManager: worktreeManager,
      projectService: projectService,
      pollInterval: const Duration(milliseconds: 10),
    );
    addTearDown(projectExecutor.stop);

    const integrationBranch = 'dartclaw/workflow/run456/integration';
    await tasks.create(
      id: 'task-map-iter',
      title: 'Map iteration coding step',
      description: 'Iteration keeps story-isolated branch.',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-task-map-iter',
      projectId: 'my-app',
      workflowRunId: 'run-456',
      configJson: const {'_baseRef': integrationBranch},
    );
    await seedWorkflowExecution(
      'task-map-iter',
      agentExecutionId: 'ae-task-map-iter',
      workflowRunId: 'run-456',
      git: const {'worktree': 'per-map-item'},
      mapIterationIndex: 0,
    );
    await projectExecutor.pollOnce();
    expect(worktreeManager.lastCreateBranch, isTrue);

    await tasks.create(
      id: 'task-post-map',
      title: 'Post-map remediation',
      description: 'Should attach integration branch.',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-task-post-map',
      projectId: 'my-app',
      workflowRunId: 'run-456',
      configJson: const {'_baseRef': integrationBranch},
    );
    await seedWorkflowExecution(
      'task-post-map',
      agentExecutionId: 'ae-task-post-map',
      workflowRunId: 'run-456',
      git: const {'worktree': 'per-map-item'},
    );
    await projectExecutor.pollOnce();
    final postMap = await tasks.get('task-post-map');
    expect(worktreeManager.lastCreateBranch, isFalse);
    expect(postMap?.worktreeJson?['branch'], integrationBranch);
  });

  test('per-map-item map iteration reuses the same story worktree across coding steps', () async {
    worker.responseText = 'Done.';
    final projectService = FakeProjectService(
      projects: [
        Project(
          id: 'my-app',
          name: 'My App',
          remoteUrl: 'git@github.com:acme/my-app.git',
          localPath: '/projects/my-app',
          defaultBranch: 'main',
          status: ProjectStatus.ready,
          createdAt: DateTime.parse('2026-03-10T09:00:00Z'),
        ),
      ],
      includeLocalProjectInGetAll: false,
      defaultProjectId: 'my-app',
    );
    final worktreeManager = _CapturingWorktreeManager();
    final projectExecutor = TaskExecutor(
      tasks: tasks,
      sessions: sessions,
      messages: messages,
      turns: turns,
      artifactCollector: collector,
      workflowStepExecutionRepository: workflowStepExecutions,
      worktreeManager: worktreeManager,
      projectService: projectService,
      workflowCliRunner: _successWorkflowCliRunner(),
      pollInterval: const Duration(milliseconds: 10),
    );
    addTearDown(projectExecutor.stop);

    const integrationBranch = 'dartclaw/workflow/run999/integration';
    await tasks.create(
      id: 'task-story-implement',
      title: 'Story implement',
      description: 'First coding step for story 0.',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-task-story-implement',
      projectId: 'my-app',
      workflowRunId: 'run-999',
      configJson: const {'_baseRef': integrationBranch},
    );
    await seedWorkflowExecution(
      'task-story-implement',
      agentExecutionId: 'ae-task-story-implement',
      workflowRunId: 'run-999',
      git: const {'worktree': 'per-map-item'},
      mapIterationIndex: 0,
    );

    await projectExecutor.pollOnce();

    final implement = await tasks.get('task-story-implement');
    expect(worktreeManager.createCallCount, 1);
    expect(worktreeManager.lastCreateBranch, isTrue);

    await tasks.create(
      id: 'task-story-verify',
      title: 'Story verify',
      description: 'Second coding step for story 0.',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-task-story-verify',
      projectId: 'my-app',
      workflowRunId: 'run-999',
      configJson: const {'_baseRef': integrationBranch},
    );
    await seedWorkflowExecution(
      'task-story-verify',
      agentExecutionId: 'ae-task-story-verify',
      workflowRunId: 'run-999',
      git: const {'worktree': 'per-map-item'},
      mapIterationIndex: 0,
    );

    await projectExecutor.pollOnce();

    final verify = await tasks.get('task-story-verify');
    expect(worktreeManager.createCallCount, 1, reason: 'story follow-up steps should reuse the same worktree');
    expect(verify?.worktreeJson?['path'], implement?.worktreeJson?['path']);
    expect(verify?.worktreeJson?['branch'], implement?.worktreeJson?['branch']);
  });

  test('per-map-item map iteration reuses the same story worktree for analysis steps that request one', () async {
    worker.responseText = 'Done.';
    final projectService = FakeProjectService(
      projects: [
        Project(
          id: 'my-app',
          name: 'My App',
          remoteUrl: 'git@github.com:acme/my-app.git',
          localPath: '/projects/my-app',
          defaultBranch: 'main',
          status: ProjectStatus.ready,
          createdAt: DateTime.parse('2026-03-10T09:00:00Z'),
        ),
      ],
      includeLocalProjectInGetAll: false,
      defaultProjectId: 'my-app',
    );
    final worktreeManager = _CapturingWorktreeManager();
    final projectExecutor = TaskExecutor(
      tasks: tasks,
      sessions: sessions,
      messages: messages,
      turns: turns,
      artifactCollector: collector,
      workflowStepExecutionRepository: workflowStepExecutions,
      worktreeManager: worktreeManager,
      projectService: projectService,
      workflowCliRunner: _successWorkflowCliRunner(),
      pollInterval: const Duration(milliseconds: 10),
    );
    addTearDown(projectExecutor.stop);

    const integrationBranch = 'dartclaw/workflow/run1000/integration';
    await tasks.create(
      id: 'task-story-implement-analysis-prelude',
      title: 'Story implement',
      description: 'First coding step for story 0.',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-task-story-implement-analysis-prelude',
      projectId: 'my-app',
      workflowRunId: 'run-1000',
      configJson: const {'_baseRef': integrationBranch},
    );
    await seedWorkflowExecution(
      'task-story-implement-analysis-prelude',
      agentExecutionId: 'ae-task-story-implement-analysis-prelude',
      workflowRunId: 'run-1000',
      git: const {'worktree': 'per-map-item'},
      mapIterationIndex: 0,
    );

    await projectExecutor.pollOnce();
    final implement = await tasks.get('task-story-implement-analysis-prelude');
    expect(worktreeManager.createCallCount, 1);

    await tasks.create(
      id: 'task-story-review-analysis',
      title: 'Story review',
      description: 'Analysis step that still needs the story worktree.',
      type: TaskType.analysis,
      autoStart: true,
      agentExecutionId: 'ae-task-story-review-analysis',
      projectId: 'my-app',
      workflowRunId: 'run-1000',
      configJson: const {'_baseRef': integrationBranch, '_workflowNeedsWorktree': true, 'readOnly': true},
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

    final review = await tasks.get('task-story-review-analysis');
    expect(worktreeManager.createCallCount, 1, reason: 'analysis follow-up should reuse the same worktree');
    expect(review?.worktreeJson?['path'], implement?.worktreeJson?['path']);
    expect(review?.worktreeJson?['branch'], implement?.worktreeJson?['branch']);
  });

  test('workflow read-only tasks skip strict freshness fetch for local workflow-owned refs', () async {
    worker.responseText = 'Done.';
    final projectService = FakeProjectService(
      projects: [
        Project(
          id: 'my-app',
          name: 'My App',
          remoteUrl: 'git@github.com:acme/my-app.git',
          localPath: '/projects/my-app',
          defaultBranch: 'main',
          status: ProjectStatus.ready,
          createdAt: DateTime.parse('2026-03-10T09:00:00Z'),
        ),
      ],
      includeLocalProjectInGetAll: false,
      defaultProjectId: 'my-app',
    );
    final projectExecutor = TaskExecutor(
      tasks: tasks,
      sessions: sessions,
      messages: messages,
      turns: turns,
      artifactCollector: collector,
      workflowStepExecutionRepository: workflowStepExecutions,
      projectService: projectService,
      workflowCliRunner: _successWorkflowCliRunner(),
      pollInterval: const Duration(milliseconds: 10),
    );
    addTearDown(projectExecutor.stop);

    const integrationBranch = 'dartclaw/workflow/run789/integration';
    await tasks.create(
      id: 'task-readonly-workflow-ref',
      title: 'Workflow spec step',
      description: 'Should trust the workflow-owned local ref.',
      type: TaskType.analysis,
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

    expect(processed, isTrue);
    expect(projectService.ensureFreshCalls, isEmpty);
    expect((await tasks.get('task-readonly-workflow-ref'))!.status, TaskStatus.review);
  });

  test('executes tasks via pool-mode when maxConcurrentTasks > 0', () async {
    final poolWorker1 = _FakeTaskWorker();
    final poolWorker2 = _FakeTaskWorker();
    poolWorker1.responseText = 'pool result';
    poolWorker2.responseText = 'pool result 2';
    addTearDown(() async {
      await poolWorker1.dispose();
      await poolWorker2.dispose();
    });

    final behavior = BehaviorFileService(workspaceDir: workspaceDir);
    final primaryRunner = TurnRunner(harness: worker, messages: messages, behavior: behavior, sessions: sessions);
    final taskRunner = TurnRunner(harness: poolWorker1, messages: messages, behavior: behavior, sessions: sessions);
    final pool = HarnessPool(runners: [primaryRunner, taskRunner]);
    final poolTurns = TurnManager.fromPool(pool: pool);
    final poolExecutor = TaskExecutor(
      tasks: tasks,
      sessions: sessions,
      messages: messages,
      turns: poolTurns,
      artifactCollector: collector,

      pollInterval: const Duration(milliseconds: 10),
    );
    addTearDown(poolExecutor.stop);

    await tasks.create(
      id: 'task-pool',
      title: 'Pool task',
      description: 'Should execute via acquired task runner.',
      type: TaskType.automation,
      autoStart: true,
    );

    final processed = await poolExecutor.pollOnce();

    expect(processed, isTrue);
    TaskStatus? status;
    for (var attempt = 0; attempt < 20; attempt++) {
      status = (await tasks.get('task-pool'))!.status;
      if (status == TaskStatus.review) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(status, TaskStatus.review);
    // Task runner was released back to pool.
    expect(pool.availableCount, 1);
    expect(pool.activeCount, 0);
  });

  test('dispatches multiple queued tasks concurrently when multiple runners are idle', () async {
    final poolWorker1Gate = Completer<void>();
    final poolWorker2Gate = Completer<void>();
    final poolWorker1 = _FakeTaskWorker()..beforeComplete = (_) => poolWorker1Gate.future;
    final poolWorker2 = _FakeTaskWorker()..beforeComplete = (_) => poolWorker2Gate.future;
    addTearDown(() async {
      if (!poolWorker1Gate.isCompleted) poolWorker1Gate.complete();
      if (!poolWorker2Gate.isCompleted) poolWorker2Gate.complete();
      await poolWorker1.dispose();
      await poolWorker2.dispose();
    });

    final behavior = BehaviorFileService(workspaceDir: workspaceDir);
    final primaryRunner = TurnRunner(harness: worker, messages: messages, behavior: behavior, sessions: sessions);
    final taskRunner1 = TurnRunner(harness: poolWorker1, messages: messages, behavior: behavior, sessions: sessions);
    final taskRunner2 = TurnRunner(harness: poolWorker2, messages: messages, behavior: behavior, sessions: sessions);
    final pool = HarnessPool(runners: [primaryRunner, taskRunner1, taskRunner2]);
    final poolTurns = TurnManager.fromPool(pool: pool);
    final poolExecutor = TaskExecutor(
      tasks: tasks,
      sessions: sessions,
      messages: messages,
      turns: poolTurns,
      artifactCollector: collector,

      pollInterval: const Duration(milliseconds: 10),
    );
    addTearDown(poolExecutor.stop);

    await tasks.create(
      id: 'task-pool-a',
      title: 'Pool A',
      description: 'Should run in parallel.',
      type: TaskType.research,
      autoStart: true,
    );
    await tasks.create(
      id: 'task-pool-b',
      title: 'Pool B',
      description: 'Should also run in parallel.',
      type: TaskType.research,
      autoStart: true,
    );

    final processed = await poolExecutor.pollOnce();

    expect(processed, isTrue);
    expect((await tasks.get('task-pool-a'))!.status, TaskStatus.running);
    expect((await tasks.get('task-pool-b'))!.status, TaskStatus.running);
    expect(pool.availableCount, 0);
    expect(pool.activeCount, 2);

    poolWorker1.responseText = 'done a';
    poolWorker2.responseText = 'done b';
    poolWorker1Gate.complete();
    poolWorker2Gate.complete();
  });

  test('concurrent shared workflow dispatch uses one worktree create call', () async {
    final poolWorker1 = _FakeTaskWorker()..responseText = 'pool result 1';
    final poolWorker2 = _FakeTaskWorker()..responseText = 'pool result 2';
    final createGate = Completer<void>();
    final worktreeManager = _BlockingWorktreeManager(createGate);
    addTearDown(() async {
      if (!createGate.isCompleted) {
        createGate.complete();
      }
      await poolWorker1.dispose();
      await poolWorker2.dispose();
    });

    final behavior = BehaviorFileService(workspaceDir: workspaceDir);
    final primaryRunner = TurnRunner(harness: worker, messages: messages, behavior: behavior, sessions: sessions);
    final taskRunner1 = TurnRunner(harness: poolWorker1, messages: messages, behavior: behavior, sessions: sessions);
    final taskRunner2 = TurnRunner(harness: poolWorker2, messages: messages, behavior: behavior, sessions: sessions);
    final pool = HarnessPool(runners: [primaryRunner, taskRunner1, taskRunner2]);
    final poolTurns = TurnManager.fromPool(pool: pool);
    final poolExecutor = TaskExecutor(
      tasks: tasks,
      sessions: sessions,
      messages: messages,
      turns: poolTurns,
      artifactCollector: collector,
      workflowRunRepository: workflowRuns,
      workflowStepExecutionRepository: workflowStepExecutions,
      worktreeManager: worktreeManager,
      pollInterval: const Duration(milliseconds: 10),
    );
    addTearDown(poolExecutor.stop);

    const workflowRunId = 'run-concurrent';
    await tasks.create(
      id: 'task-shared-concurrent-a',
      title: 'Concurrent A',
      description: 'First shared workflow task.',
      type: TaskType.coding,
      autoStart: true,
      workflowRunId: workflowRunId,
      agentExecutionId: 'ae-task-shared-concurrent-a',
      configJson: const {'_baseRef': 'dartclaw/workflow/runconcurrent/integration'},
    );
    await seedWorkflowExecution(
      'task-shared-concurrent-a',
      workflowRunId: workflowRunId,
      agentExecutionId: 'ae-task-shared-concurrent-a',
      git: const {'worktree': 'shared'},
    );

    await tasks.create(
      id: 'task-shared-concurrent-b',
      title: 'Concurrent B',
      description: 'Second shared workflow task.',
      type: TaskType.coding,
      autoStart: true,
      workflowRunId: workflowRunId,
      agentExecutionId: 'ae-task-shared-concurrent-b',
      configJson: const {'_baseRef': 'dartclaw/workflow/runconcurrent/integration'},
    );
    await seedWorkflowExecution(
      'task-shared-concurrent-b',
      workflowRunId: workflowRunId,
      agentExecutionId: 'ae-task-shared-concurrent-b',
      git: const {'worktree': 'shared'},
    );

    final processed = await poolExecutor.pollOnce();
    expect(processed, isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(worktreeManager.createCallCount, 1);

    createGate.complete();
    for (var attempt = 0; attempt < 40; attempt++) {
      final first = await tasks.get('task-shared-concurrent-a');
      final second = await tasks.get('task-shared-concurrent-b');
      final firstDone = first != null && first.status != TaskStatus.running;
      final secondDone = second != null && second.status != TaskStatus.running;
      if (firstDone && secondDone) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    final first = await tasks.get('task-shared-concurrent-a');
    final second = await tasks.get('task-shared-concurrent-b');
    expect(first?.worktreeJson?['path'], second?.worktreeJson?['path']);
    expect('${first?.configJson['errorSummary'] ?? ''}', isNot(contains('already exists')));
    expect('${second?.configJson['errorSummary'] ?? ''}', isNot(contains('already exists')));
  });

  test('waits for shared-harness contention instead of failing the task', () async {
    final contentionTurns = _BusyOnceTurnManager(messages, worker);
    final contentionExecutor = TaskExecutor(
      tasks: tasks,
      sessions: sessions,
      messages: messages,
      turns: contentionTurns,
      artifactCollector: collector,

      pollInterval: const Duration(milliseconds: 1),
    );
    addTearDown(contentionExecutor.stop);

    await tasks.create(
      id: 'task-busy',
      title: 'Busy task',
      description: 'Should wait for the shared harness.',
      type: TaskType.coding,
      autoStart: true,
    );

    final processed = await contentionExecutor.pollOnce();

    expect(processed, isTrue);
    expect((await tasks.get('task-busy'))!.status, TaskStatus.review);
  });

  test('inserts trace record when traceService is provided', () async {
    final db = openTaskDbInMemory();
    final traceService = TurnTraceService(db);
    addTearDown(() async {
      await traceService.dispose();
    });

    worker.responseText = 'Done.';
    worker.inputTokens = 100;
    worker.outputTokens = 50;
    final traceExecutor = TaskExecutor(
      tasks: tasks,
      sessions: sessions,
      messages: messages,
      turns: turns,
      artifactCollector: collector,

      traceService: traceService,
      pollInterval: const Duration(milliseconds: 10),
    );
    addTearDown(traceExecutor.stop);

    await tasks.create(
      id: 'task-trace',
      title: 'Traced task',
      description: 'Should produce a trace record.',
      type: TaskType.research,
      autoStart: true,
    );

    await traceExecutor.pollOnce();
    // Allow the unawaited trace insert to complete.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final result = await traceService.query(taskId: 'task-trace');
    expect(result.traces, hasLength(1));
    expect(result.traces[0].taskId, 'task-trace');
    expect(result.traces[0].inputTokens, 100);
    expect(result.traces[0].outputTokens, 50);
    expect(result.traces[0].isError, isFalse);
    expect(result.summary.traceCount, 1);
  });

  test('does not crash when traceService is null (graceful degradation)', () async {
    // executor in setUp has no traceService — verify normal operation.
    worker.responseText = 'Done.';
    await tasks.create(
      id: 'task-no-trace',
      title: 'No trace task',
      description: 'Should complete without trace service.',
      type: TaskType.research,
      autoStart: true,
    );

    final processed = await executor.pollOnce();

    expect(processed, isTrue);
    expect((await tasks.get('task-no-trace'))!.status, TaskStatus.review);
  });

  group('prompt scope selection', () {
    late _CapturingTurnManager capturing;
    late TaskExecutor scopeExecutor;
    const workflowWorkspaceDir = '/tmp/workflow-workspace';

    setUp(() {
      capturing = _CapturingTurnManager(messages, worker);
      scopeExecutor = TaskExecutor(
        tasks: tasks,
        sessions: sessions,
        messages: messages,
        turns: capturing,
        artifactCollector: collector,
        workflowStepExecutionRepository: workflowStepExecutions,
        pollInterval: const Duration(milliseconds: 10),
      );
    });

    tearDown(() async {
      await scopeExecutor.stop();
    });

    test('regular task gets task scope', () async {
      worker.responseText = 'Done.';
      await tasks.create(
        id: 'task-scope-regular',
        title: 'Scope test',
        description: 'Regular task.',
        type: TaskType.automation,
        autoStart: true,
      );
      await scopeExecutor.pollOnce();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(capturing.lastPromptScope, PromptScope.task);
    });

    test('workflow workspace override keeps task scope and behavior path', () async {
      worker.responseText = 'Done.';
      await agentExecutions.create(
        const AgentExecution(id: 'ae-task-scope-eval', provider: 'claude', workspaceDir: workflowWorkspaceDir),
      );
      await tasks.create(
        id: 'task-scope-eval',
        title: 'Workflow workspace task',
        description: 'Workflow-scoped behavior should override the default workspace.',
        type: TaskType.automation,
        agentExecutionId: 'ae-task-scope-eval',
        autoStart: true,
      );
      await scopeExecutor.pollOnce();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(capturing.lastPromptScope, PromptScope.task);
      expect(capturing.lastBehaviorOverride?.workspaceDir, workflowWorkspaceDir);
    });

    test('workflow workspace override is preserved for automation tasks', () async {
      // Workflow-scoped behavior should be reused without changing the prompt scope.
      worker.responseText = 'Done.';
      await agentExecutions.create(
        const AgentExecution(
          id: 'ae-task-scope-eval-restricted',
          provider: 'claude',
          workspaceDir: workflowWorkspaceDir,
        ),
      );
      await tasks.create(
        id: 'task-scope-eval-restricted',
        title: 'Workflow workspace automation task',
        description: 'Workflow workspace override should survive task routing.',
        type: TaskType.automation,
        agentExecutionId: 'ae-task-scope-eval-restricted',
        autoStart: true,
      );
      await scopeExecutor.pollOnce();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(capturing.lastPromptScope, PromptScope.task);
      expect(capturing.lastBehaviorOverride?.workspaceDir, workflowWorkspaceDir);
    });

    test('project-backed workflow research task runs in the project directory', () async {
      worker.responseText = 'Done.';
      final projectService = FakeProjectService(
        projects: [
          Project(
            id: 'my-app',
            name: 'My App',
            remoteUrl: 'git@github.com:acme/my-app.git',
            localPath: '/projects/my-app',
            defaultBranch: 'main',
            status: ProjectStatus.ready,
            createdAt: DateTime.parse('2026-03-10T09:00:00Z'),
          ),
        ],
        includeLocalProjectInGetAll: false,
        defaultProjectId: 'my-app',
      );
      final projectExecutor = TaskExecutor(
        tasks: tasks,
        sessions: sessions,
        messages: messages,
        turns: capturing,
        artifactCollector: collector,
        workflowStepExecutionRepository: workflowStepExecutions,
        projectService: projectService,
        pollInterval: const Duration(milliseconds: 10),
      );
      addTearDown(projectExecutor.stop);

      await tasks.create(
        id: 'task-scope-project-research',
        title: 'Workflow research task',
        description: 'Should inspect the target project, not the host workspace.',
        type: TaskType.research,
        agentExecutionId: 'ae-task-scope-project-research',
        projectId: 'my-app',
        autoStart: true,
      );
      final existingExecution = await agentExecutions.get('ae-task-scope-project-research');
      if (existingExecution == null) {
        await agentExecutions.create(
          const AgentExecution(
            id: 'ae-task-scope-project-research',
            provider: 'claude',
            workspaceDir: workflowWorkspaceDir,
          ),
        );
      } else {
        await agentExecutions.update(existingExecution.copyWith(workspaceDir: workflowWorkspaceDir));
      }
      await projectExecutor.pollOnce();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(capturing.lastPromptScope, PromptScope.task);
      expect(capturing.lastBehaviorOverride?.workspaceDir, workflowWorkspaceDir);
      expect(capturing.lastBehaviorOverride?.projectDir, '/projects/my-app');
      expect(capturing.lastDirectory, '/projects/my-app');
    });
  });

  test('read-only project task fails when the repo becomes dirty during the turn', () async {
    worker.responseText = 'Done.';

    final projectDir = Directory.systemTemp.createTempSync('task_executor_readonly_repo_');
    addTearDown(() {
      if (projectDir.existsSync()) {
        projectDir.deleteSync(recursive: true);
      }
    });
    await Process.run('git', ['init', '-b', 'main'], workingDirectory: projectDir.path);
    File(p.join(projectDir.path, 'README.md')).writeAsStringSync('fixture\n');
    await Process.run('git', ['add', 'README.md'], workingDirectory: projectDir.path);
    await Process.run(
      'git',
      ['commit', '-m', 'init', '--no-gpg-sign'],
      workingDirectory: projectDir.path,
      environment: {
        'GIT_AUTHOR_NAME': 'Test',
        'GIT_AUTHOR_EMAIL': 'test@test.com',
        'GIT_COMMITTER_NAME': 'Test',
        'GIT_COMMITTER_EMAIL': 'test@test.com',
      },
    );

    worker.onTurnWithDirectory = (_, directory) {
      final repoPath = directory ?? projectDir.path;
      final notesDir = Directory(p.join(repoPath, 'notes'))..createSync(recursive: true);
      File(p.join(notesDir.path, 'leak.md')).writeAsStringSync('# leaked\n\n- mutation\n');
    };

    final projectService = FakeProjectService(
      projects: [
        Project(
          id: 'my-app',
          name: 'My App',
          remoteUrl: 'git@github.com:acme/my-app.git',
          localPath: projectDir.path,
          defaultBranch: 'main',
          status: ProjectStatus.ready,
          createdAt: DateTime.parse('2026-03-10T09:00:00Z'),
        ),
      ],
      includeLocalProjectInGetAll: false,
      defaultProjectId: 'my-app',
    );
    final projectExecutor = TaskExecutor(
      tasks: tasks,
      sessions: sessions,
      messages: messages,
      turns: turns,
      artifactCollector: collector,
      projectService: projectService,
      pollInterval: const Duration(milliseconds: 10),
    );
    addTearDown(projectExecutor.stop);

    await tasks.create(
      id: 'task-readonly-dirty',
      title: 'Read-only task',
      description: 'Must not mutate the repo.',
      type: TaskType.research,
      autoStart: true,
      projectId: 'my-app',
      configJson: const {'readOnly': true},
    );

    final processed = await projectExecutor.pollOnce();

    expect(processed, isTrue);
    final failed = await tasks.get('task-readonly-dirty');
    expect(failed!.status, TaskStatus.failed);
    expect(failed.configJson['errorSummary'], contains('Read-only task modified project files'));
    expect(failed.configJson['errorSummary'], contains('notes/leak.md'));
  });

  test('read-only coding task ignores pre-existing dirt in its inherited worktree', () async {
    final projectDir = Directory.systemTemp.createTempSync('task_executor_readonly_project_');
    final worktreeDir = Directory.systemTemp.createTempSync('task_executor_readonly_worktree_');
    addTearDown(() {
      if (projectDir.existsSync()) {
        projectDir.deleteSync(recursive: true);
      }
      if (worktreeDir.existsSync()) {
        worktreeDir.deleteSync(recursive: true);
      }
    });

    File(p.join(projectDir.path, 'README.md')).writeAsStringSync('fixture\n');
    await Process.run('git', ['init', '-b', 'main'], workingDirectory: projectDir.path);
    await Process.run('git', ['config', 'user.name', 'Test'], workingDirectory: projectDir.path);
    await Process.run('git', ['config', 'user.email', 'test@test.com'], workingDirectory: projectDir.path);
    await Process.run('git', ['add', 'README.md'], workingDirectory: projectDir.path);
    await Process.run('git', ['commit', '-m', 'init', '--no-gpg-sign'], workingDirectory: projectDir.path);

    final cloneResult = await Process.run('git', ['clone', projectDir.path, worktreeDir.path]);
    expect(cloneResult.exitCode, 0, reason: cloneResult.stderr.toString());

    File(p.join(worktreeDir.path, 'plan.md')).writeAsStringSync('# Plan\n\n- [x] Story 1\n');
    final notesDir = Directory(p.join(worktreeDir.path, 'notes'))..createSync(recursive: true);
    File(p.join(notesDir.path, 'artifact.md')).writeAsStringSync('# Artifact\n\n- mutation from implement\n');

    final projectService = FakeProjectService(
      projects: [
        Project(
          id: 'my-app',
          name: 'My App',
          remoteUrl: 'git@github.com:acme/my-app.git',
          localPath: projectDir.path,
          defaultBranch: 'main',
          status: ProjectStatus.ready,
          createdAt: DateTime.parse('2026-03-10T09:00:00Z'),
        ),
      ],
      includeLocalProjectInGetAll: false,
      defaultProjectId: 'my-app',
    );
    final projectExecutor = TaskExecutor(
      tasks: tasks,
      sessions: sessions,
      messages: messages,
      turns: turns,
      artifactCollector: collector,
      projectService: projectService,
      workflowCliRunner: _successWorkflowCliRunner(),
      worktreeManager: _StaticPathWorktreeManager(worktreeDir.path),
      workflowStepExecutionRepository: workflowStepExecutions,
      pollInterval: const Duration(milliseconds: 10),
    );
    addTearDown(projectExecutor.stop);

    await tasks.create(
      id: 'task-readonly-inherited-worktree',
      title: 'Read-only coding task',
      description: 'Should treat inherited worktree dirt as baseline, not a new mutation.',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-task-readonly-inherited-worktree',
      projectId: 'my-app',
      workflowRunId: 'wf-readonly-inherited-worktree',
      configJson: const {'readOnly': true, '_baseRef': 'main'},
    );
    await seedWorkflowExecution(
      'task-readonly-inherited-worktree',
      agentExecutionId: 'ae-task-readonly-inherited-worktree',
      workflowRunId: 'wf-readonly-inherited-worktree',
      git: const {'worktree': 'per-map-item'},
      mapIterationIndex: 0,
    );

    final processed = await projectExecutor.pollOnce();

    expect(processed, isTrue);
    final updated = await tasks.get('task-readonly-inherited-worktree');
    expect(updated, isNotNull);
    expect(updated!.status, TaskStatus.review);
    expect(updated.configJson['errorSummary'], isNull);
  });

  test('workflow required input path preflight fails before workflow runner starts', () async {
    final worktreeDir = Directory.systemTemp.createTempSync('dartclaw_missing_spec_worktree_');
    addTearDown(() {
      if (worktreeDir.existsSync()) worktreeDir.deleteSync(recursive: true);
    });
    var processStarted = false;
    final runner = WorkflowCliRunner(
      providers: const {'claude': WorkflowCliProviderConfig(executable: 'claude')},
      processStarter: (exe, args, {workingDirectory, environment}) async {
        processStarted = true;
        final payload = jsonEncode({'session_id': 'cli-session', 'result': 'Done.'});
        return Process.start('/bin/sh', ['-lc', "printf '%s' '${payload.replaceAll("'", "'\\''")}'"]);
      },
    );
    final projectExecutor = TaskExecutor(
      tasks: tasks,
      sessions: sessions,
      messages: messages,
      turns: turns,
      artifactCollector: collector,
      workflowCliRunner: runner,
      worktreeManager: _StaticPathWorktreeManager(worktreeDir.path),
      workflowRunRepository: workflowRuns,
      workflowStepExecutionRepository: workflowStepExecutions,
      pollInterval: const Duration(milliseconds: 10),
    );
    addTearDown(projectExecutor.stop);

    await tasks.create(
      id: 'task-missing-required-input',
      title: 'Implement Story',
      description: 'Implement fis/s01.md',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-task-missing-required-input',
      workflowRunId: 'wf-missing-required-input',
      configJson: const {'_workflowNeedsWorktree': true, 'requiredInputPath': 'fis/s01.md'},
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

    expect(processed, isTrue);
    expect(processStarted, isFalse);
    final updated = await tasks.get('task-missing-required-input');
    expect(updated?.status, TaskStatus.failed);
    expect(updated?.configJson['errorSummary'], contains('required input path "fis/s01.md" is missing'));
  });
}

WorkflowCliRunner _successWorkflowCliRunner({String sessionId = 'cli-session-success'}) {
  return WorkflowCliRunner(
    providers: const {
      'claude': WorkflowCliProviderConfig(executable: 'claude'),
      'codex': WorkflowCliProviderConfig(executable: 'codex'),
    },
    processStarter: (exe, args, {workingDirectory, environment}) async {
      final payload = jsonEncode({'session_id': sessionId, 'result': 'Done.'});
      return Process.start('/bin/sh', ['-lc', "printf '%s' '${payload.replaceAll("'", "'\\''")}'"]);
    },
  );
}

class _FakeTaskWorker implements AgentHarness {
  @override
  String skillActivationLine(String skill) => "Use the '$skill' skill.";

  final _eventsCtrl = StreamController<BridgeEvent>.broadcast();

  String responseText = '';
  String? lastModel;
  String? lastDirectory;
  int inputTokens = 0;
  int outputTokens = 0;
  bool shouldFail = false;
  void Function(String sessionId)? onTurn;
  void Function(String sessionId, String? directory)? onTurnWithDirectory;
  Future<void> Function(String sessionId)? beforeComplete;

  @override
  bool get supportsCostReporting => true;

  @override
  bool get supportsToolApproval => true;

  @override
  bool get supportsStreaming => true;

  @override
  bool get supportsCachedTokens => false;

  @override
  bool get supportsSessionContinuity => false;

  @override
  bool get supportsPreCompactHook => false;

  @override
  PromptStrategy get promptStrategy => PromptStrategy.replace;

  @override
  WorkerState get state => WorkerState.idle;

  @override
  Stream<BridgeEvent> get events => _eventsCtrl.stream;

  @override
  Future<void> start() async {}

  @override
  Future<Map<String, dynamic>> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    Map<String, dynamic>? mcpServers,
    bool resume = false,
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
  }) async {
    onTurn?.call(sessionId);
    onTurnWithDirectory?.call(sessionId, directory);
    lastModel = model;
    lastDirectory = directory;
    final waitFor = beforeComplete;
    if (waitFor != null) {
      await waitFor(sessionId);
    }
    if (shouldFail) {
      throw StateError('simulated crash');
    }
    if (responseText.isNotEmpty) {
      _eventsCtrl.add(DeltaEvent(responseText));
    }
    return <String, dynamic>{'input_tokens': inputTokens, 'output_tokens': outputTokens};
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    if (!_eventsCtrl.isClosed) {
      await _eventsCtrl.close();
    }
  }
}

class _CapturingWorktreeManager extends WorktreeManager {
  _CapturingWorktreeManager()
    : super(
        dataDir: '/tmp',
        processRunner: (executable, arguments, {workingDirectory}) async => ProcessResult(0, 0, '', ''),
      );

  String? lastBaseRef;
  Project? lastProject;
  bool? lastCreateBranch;
  int createCallCount = 0;

  @override
  Future<WorktreeInfo> create(
    String taskId, {
    String? baseRef,
    Project? project,
    bool createBranch = true,
    Map<String, dynamic>? existingWorktreeJson,
  }) async {
    createCallCount++;
    lastBaseRef = baseRef;
    lastProject = project;
    lastCreateBranch = createBranch;
    return WorktreeInfo(
      path: '/tmp/worktrees/$taskId',
      branch: createBranch ? 'dartclaw/task-$taskId' : (baseRef ?? 'main'),
      createdAt: DateTime.now(),
    );
  }

  @override
  Future<void> cleanup(String taskId, {Project? project}) async {}
}

class _BlockingWorktreeManager extends WorktreeManager {
  _BlockingWorktreeManager(this._gate)
    : super(
        dataDir: '/tmp',
        processRunner: (executable, arguments, {workingDirectory}) async => ProcessResult(0, 0, '', ''),
      );

  final Completer<void> _gate;
  int createCallCount = 0;

  @override
  Future<WorktreeInfo> create(
    String taskId, {
    String? baseRef,
    Project? project,
    bool createBranch = true,
    Map<String, dynamic>? existingWorktreeJson,
  }) async {
    createCallCount++;
    await _gate.future;
    return WorktreeInfo(
      path: '/tmp/worktrees/$taskId',
      branch: createBranch ? 'dartclaw/task-$taskId' : (baseRef ?? 'main'),
      createdAt: DateTime.now(),
    );
  }

  @override
  Future<void> cleanup(String taskId, {Project? project}) async {}
}

class _StaticPathWorktreeManager extends WorktreeManager {
  _StaticPathWorktreeManager(this.path)
    : super(
        dataDir: '/tmp',
        processRunner: (executable, arguments, {workingDirectory}) async => ProcessResult(0, 0, '', ''),
      );

  final String path;

  @override
  Future<WorktreeInfo> create(
    String taskId, {
    String? baseRef,
    Project? project,
    bool createBranch = true,
    Map<String, dynamic>? existingWorktreeJson,
  }) async {
    return WorktreeInfo(
      path: path,
      branch: createBranch ? 'dartclaw/task-$taskId' : (baseRef ?? 'main'),
      createdAt: DateTime.now(),
    );
  }

  @override
  Future<void> cleanup(String taskId, {Project? project}) async {}
}

class _CapturingTurnManager extends TurnManager {
  _CapturingTurnManager(MessageService messages, AgentHarness worker)
    : super(
        messages: messages,
        worker: worker,
        behavior: BehaviorFileService(workspaceDir: '/tmp/dartclaw-scope-test'),
      );

  PromptScope? lastPromptScope;

  BehaviorFileService? lastBehaviorOverride;

  String? lastDirectory;

  @override
  Iterable<String> get activeSessionIds => const <String>[];

  @override
  Future<String> reserveTurn(
    String sessionId, {
    String agentName = 'main',
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
    bool isHumanInput = false,
    BehaviorFileService? behaviorOverride,
    PromptScope? promptScope,
  }) async {
    lastDirectory = directory;
    lastPromptScope = promptScope;
    lastBehaviorOverride = behaviorOverride;
    return 'scope-turn';
  }

  @override
  void executeTurn(
    String sessionId,
    String turnId,
    List<Map<String, dynamic>> messages, {
    String? source,
    String agentName = 'main',
    bool resume = false,
  }) {}

  @override
  Future<TurnOutcome> waitForOutcome(String sessionId, String turnId) async {
    return TurnOutcome(
      turnId: turnId,
      sessionId: sessionId,
      status: TurnStatus.completed,
      responseText: 'Done.',
      completedAt: DateTime.now(),
    );
  }
}

class _BusyOnceTurnManager extends TurnManager {
  _BusyOnceTurnManager(MessageService messages, AgentHarness worker)
    : super(
        messages: messages,
        worker: worker,
        behavior: BehaviorFileService(workspaceDir: '/tmp/dartclaw-task-executor-test'),
      );

  bool _busyOnce = true;

  @override
  Iterable<String> get activeSessionIds => const <String>[];

  @override
  Future<String> reserveTurn(
    String sessionId, {
    String agentName = 'main',
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
    bool isHumanInput = false,
    BehaviorFileService? behaviorOverride,
    PromptScope? promptScope,
  }) async {
    if (_busyOnce) {
      _busyOnce = false;
      throw BusyTurnException('shared harness busy', isSameSession: false);
    }

    return 'busy-once-turn';
  }

  @override
  void executeTurn(
    String sessionId,
    String turnId,
    List<Map<String, dynamic>> messages, {
    String? source,
    String agentName = 'main',
    bool resume = false,
  }) {}

  @override
  Future<TurnOutcome> waitForOutcome(String sessionId, String turnId) async {
    return TurnOutcome(turnId: turnId, sessionId: sessionId, status: TurnStatus.completed, completedAt: DateTime.now());
  }
}
