import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide HarnessPool, TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart' hide HarnessPool, TurnManager, TurnRunner;
import 'package:dartclaw_server/src/harness_pool.dart' show HarnessPool;
import 'package:dartclaw_server/src/turn_manager.dart' show TurnManager;
import 'package:dartclaw_server/src/turn_runner.dart' show TurnRunner;
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'task_executor_test_support.dart';

void main() {
  late FakeTaskWorker worker;
  late WorkflowTaskExecutorTestContext ctx;
  // Aliases into ctx for use by the bare-field call sites in the test body.
  late String workspaceDir;
  late SessionService sessions;
  late MessageService messages;
  late TaskService tasks;
  late ArtifactCollector collector;
  late SqliteAgentExecutionRepository agentExecutions;
  late SqliteWorkflowRunRepository workflowRuns;
  late SqliteWorkflowStepExecutionRepository workflowStepExecutions;
  late TaskExecutor executor;

  setUp(() async {
    worker = FakeTaskWorker();
    ctx = WorkflowTaskExecutorTestContext(worker);
    await ctx.setUp();
    workspaceDir = ctx.workspaceDir;
    sessions = ctx.sessions;
    messages = ctx.messages;
    tasks = ctx.tasks;
    collector = ctx.collector;
    agentExecutions = ctx.agentExecutions;
    workflowRuns = ctx.workflowRuns;
    workflowStepExecutions = ctx.workflowStepExecutions;
    executor = ctx.executor;
  });

  tearDown(() async {
    await ctx.tearDown(workerDispose: worker.dispose);
  });

  TaskExecutor buildExecutor({
    Future<void> Function(String taskId)? onAutoAccept,
    ProjectService? projectService,
    WorkflowCliRunner? workflowCliRunner,
    TaskEventRecorder? eventRecorder,
    TaskExecutorLimits limits = const TaskExecutorLimits(),
    Duration pollInterval = const Duration(milliseconds: 10),
  }) => ctx.buildExecutor(
    onAutoAccept: onAutoAccept,
    projectService: projectService,
    workflowCliRunner: workflowCliRunner,
    eventRecorder: eventRecorder,
    limits: limits,
    pollInterval: pollInterval,
  );

  Future<void> seedWorkflowExecution(
    String taskId, {
    String? agentExecutionId,
    required String workflowRunId,
    String stepId = 'plan',
    String stepType = 'coding',
    Map<String, dynamic>? git,
  }) => ctx.seedWorkflowExecution(
    taskId,
    agentExecutionId: agentExecutionId,
    workflowRunId: workflowRunId,
    stepId: stepId,
    stepType: stepType,
    git: git,
  );

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
    // A task whose reviewMode routes it directly to accepted must NOT fire the
    // auto-accept callback (the callback exists only to advance review-bound tasks).
    await tasks.create(
      id: 'task-coding-only-accepted',
      title: 'Coding-only accepted task',
      description: 'Non-coding tasks with coding-only reviewMode should skip auto-accept.',
      type: TaskType.research,
      autoStart: true,
      configJson: const {'reviewMode': 'coding-only'},
    );

    await autoAcceptExecutor.pollOnce();
    await autoAcceptExecutor.pollOnce();

    expect(calls, ['task-auto-accept']);
    expect((await tasks.get('task-auto-accept'))!.status, TaskStatus.review);
    expect((await tasks.get('task-coding-only-accepted'))!.status, TaskStatus.accepted);
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
      workflowCliRunner: successCliRunner(),
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
      workflowCliRunner: successCliRunner(),
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

  test('executes tasks via pool-mode when maxConcurrentTasks > 0', () async {
    final poolWorker1 = FakeTaskWorker();
    final poolWorker2 = FakeTaskWorker();
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
      services: TaskExecutorServices(
        tasks: tasks,
        sessions: sessions,
        messages: messages,
        artifactCollector: collector,
      ),
      runners: TaskExecutorRunners(turns: poolTurns),
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
    final completed = await waitForTaskStatus(tasks, 'task-pool', until: const {TaskStatus.review});
    expect(completed?.status, TaskStatus.review);
    // Task runner was released back to pool.
    expect(pool.availableCount, 1);
    expect(pool.activeCount, 0);
  });

  test('provider-less workflow pool task spawns and acquires configured default provider', () async {
    String? executable;
    final spawnRequests = <String?>[];
    final cliRunner = echoCliRunner(
      (_) => jsonEncode({'session_id': 'pool-default-provider-session', 'result': 'Done.'}),
      onArgs: (exe, _) => executable = exe,
    );
    final codexWorker = FakeTaskWorker();
    addTearDown(codexWorker.dispose);

    final behavior = BehaviorFileService(workspaceDir: workspaceDir);
    final primaryRunner = TurnRunner(harness: worker, messages: messages, behavior: behavior, sessions: sessions);
    final pool = HarnessPool(runners: [primaryRunner], maxConcurrentTasks: 1);
    final poolTurns = TurnManager.fromPool(pool: pool);
    final poolExecutor = TaskExecutor(
      services: TaskExecutorServices(
        tasks: tasks,
        sessions: sessions,
        messages: messages,
        artifactCollector: collector,
        workflowRunRepository: workflowRuns,
        workflowStepExecutionRepository: workflowStepExecutions,
      ),
      runners: TaskExecutorRunners(turns: poolTurns, workflowCliRunner: cliRunner),
      limits: const TaskExecutorLimits(defaultProviderId: 'codex'),
      onSpawnNeeded: (requestedProviderId) async {
        spawnRequests.add(requestedProviderId);
        var spawned = false;
        if (requestedProviderId == 'codex') {
          pool.addRunner(
            TurnRunner(
              harness: codexWorker,
              messages: messages,
              behavior: behavior,
              sessions: sessions,
              providerId: 'codex',
            ),
          );
          spawned = true;
        }
        return spawned;
      },
      pollInterval: const Duration(milliseconds: 10),
    );
    addTearDown(poolExecutor.stop);

    await tasks.create(
      id: 'task-pool-default-provider',
      title: 'Pool workflow step',
      description: 'Run provider-less workflow task through pool mode.',
      type: TaskType.coding,
      autoStart: true,
      agentExecutionId: 'ae-task-pool-default-provider',
      workflowRunId: 'wf-pool-default-provider',
    );
    await seedWorkflowExecution(
      'task-pool-default-provider',
      agentExecutionId: 'ae-task-pool-default-provider',
      workflowRunId: 'wf-pool-default-provider',
    );

    final processed = await poolExecutor.pollOnce();

    expect(processed, isTrue);
    final completed = await waitForTaskStatus(tasks, 'task-pool-default-provider', until: const {TaskStatus.review});
    expect(spawnRequests, ['codex']);
    expect(executable, 'codex');
    expect(completed?.status, TaskStatus.review);
    expect(pool.hasTaskRunnerForProvider('codex'), isTrue);
    expect(pool.hasTaskRunnerForProvider('claude'), isFalse);
  });

  test('lazy spawn provider demand follows FIFO task ordering', () async {
    final behavior = BehaviorFileService(workspaceDir: workspaceDir);
    final primaryRunner = TurnRunner(harness: worker, messages: messages, behavior: behavior, sessions: sessions);
    final codexWorker = FakeTaskWorker()..responseText = 'codex result';
    addTearDown(codexWorker.dispose);
    final pool = HarnessPool(runners: [primaryRunner], maxConcurrentTasks: 1);
    final poolTurns = TurnManager.fromPool(pool: pool);
    final spawnRequests = <String?>[];
    final spawnRequested = Completer<void>();
    final poolExecutor = TaskExecutor(
      services: TaskExecutorServices(
        tasks: tasks,
        sessions: sessions,
        messages: messages,
        artifactCollector: collector,
      ),
      runners: TaskExecutorRunners(turns: poolTurns),
      onSpawnNeeded: (requestedProviderId) async {
        spawnRequests.add(requestedProviderId);
        var spawned = false;
        if (requestedProviderId == 'codex') {
          pool.addRunner(
            TurnRunner(
              harness: codexWorker,
              messages: messages,
              behavior: behavior,
              sessions: sessions,
              providerId: 'codex',
            ),
          );
          spawned = true;
        }
        if (!spawnRequested.isCompleted) {
          spawnRequested.complete();
        }
        return spawned;
      },
      pollInterval: const Duration(milliseconds: 10),
    );
    addTearDown(poolExecutor.stop);

    await tasks.create(
      id: 'task-old-codex',
      title: 'Older codex task',
      description: 'Oldest queued provider-specific task.',
      type: TaskType.coding,
      provider: 'codex',
      autoStart: true,
      now: DateTime.parse('2026-03-10T09:00:00Z'),
    );
    await tasks.create(
      id: 'task-new-claude',
      title: 'Newer claude task',
      description: 'Newer queued provider-specific task.',
      type: TaskType.coding,
      provider: 'claude',
      autoStart: true,
      now: DateTime.parse('2026-03-10T09:01:00Z'),
    );

    final processed = await poolExecutor.pollOnce();
    await spawnRequested.future;

    expect(processed, isTrue);
    expect(spawnRequests, ['codex']);
  });

  test('dispatches multiple queued tasks concurrently when multiple runners are idle', () async {
    final poolWorker1Gate = Completer<void>();
    final poolWorker2Gate = Completer<void>();
    final poolWorker1 = FakeTaskWorker()..beforeComplete = (_) => poolWorker1Gate.future;
    final poolWorker2 = FakeTaskWorker()..beforeComplete = (_) => poolWorker2Gate.future;
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
      services: TaskExecutorServices(
        tasks: tasks,
        sessions: sessions,
        messages: messages,
        artifactCollector: collector,
      ),
      runners: TaskExecutorRunners(turns: poolTurns),
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
    final poolWorker1 = FakeTaskWorker()..responseText = 'pool result 1';
    final poolWorker2 = FakeTaskWorker()..responseText = 'pool result 2';
    final createGate = Completer<void>();
    final worktreeManager = BlockingWorktreeManager(createGate);
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
      services: TaskExecutorServices(
        tasks: tasks,
        sessions: sessions,
        messages: messages,
        artifactCollector: collector,
        workflowRunRepository: workflowRuns,
        workflowStepExecutionRepository: workflowStepExecutions,
        worktreeManager: worktreeManager,
      ),
      runners: TaskExecutorRunners(turns: poolTurns),
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

    // Let both concurrent dispatches reach the gated worktree create.
    await pumpEventQueue();
    expect(worktreeManager.createCallCount, 1);

    createGate.complete();
    await waitForTaskStatus(tasks, 'task-shared-concurrent-a');
    await waitForTaskStatus(tasks, 'task-shared-concurrent-b');

    final first = await tasks.get('task-shared-concurrent-a');
    final second = await tasks.get('task-shared-concurrent-b');
    expect(first?.worktreeJson?['path'], second?.worktreeJson?['path']);
    expect('${first?.configJson['errorSummary'] ?? ''}', isNot(contains('already exists')));
    expect('${second?.configJson['errorSummary'] ?? ''}', isNot(contains('already exists')));
  });

  test('waits for shared-harness contention instead of failing the task', () async {
    final contentionTurns = BusyOnceTurnManager(messages, worker);
    final contentionExecutor = TaskExecutor(
      services: TaskExecutorServices(
        tasks: tasks,
        sessions: sessions,
        messages: messages,
        artifactCollector: collector,
      ),
      runners: TaskExecutorRunners(turns: contentionTurns),
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
    final traceExecutor = ctx.harness.buildWorkflowExecutor(traceService: traceService);
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
    await pumpEventQueue();

    final result = await traceService.query(taskId: 'task-trace');
    expect(result.traces, hasLength(1));
    expect(result.traces[0].taskId, 'task-trace');
    expect(result.traces[0].inputTokens, 100);
    expect(result.traces[0].outputTokens, 50);
    expect(result.traces[0].isError, isFalse);
    expect(result.summary.traceCount, 1);
  });

  test('does not crash when traceService is null (graceful degradation)', () async {
    // executor in setUp has no traceService – verify normal operation.
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
    late CapturingTurnManager capturing;
    late TaskExecutor scopeExecutor;
    const workflowWorkspaceDir = '/tmp/workflow-workspace';

    setUp(() {
      capturing = CapturingTurnManager(messages, worker);
      scopeExecutor = TaskExecutor(
        services: TaskExecutorServices(
          tasks: tasks,
          sessions: sessions,
          messages: messages,
          artifactCollector: collector,
          workflowStepExecutionRepository: workflowStepExecutions,
        ),
        runners: TaskExecutorRunners(turns: capturing),
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
      await pumpEventQueue();
      expect(capturing.lastPromptScope, PromptScope.task);
      expect(capturing.lastTaskId, 'task-scope-regular');
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
      await pumpEventQueue();
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
      await pumpEventQueue();
      expect(capturing.lastPromptScope, PromptScope.task);
      expect(capturing.lastBehaviorOverride?.workspaceDir, workflowWorkspaceDir);
    });

    test('project-backed workflow research task runs in the project directory', () async {
      worker.responseText = 'Done.';
      final projectService = fakeProjectServiceFor(readyProject());
      final projectExecutor = ctx.harness.buildWorkflowExecutor(
        turnManager: capturing,
        projectService: projectService,
        workflowStepExecutionRepository: workflowStepExecutions,
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
      await pumpEventQueue();

      expect(capturing.lastPromptScope, PromptScope.task);
      expect(capturing.lastBehaviorOverride?.workspaceDir, workflowWorkspaceDir);
      expect(capturing.lastBehaviorOverride?.projectDir, '/projects/my-app');
      expect(capturing.lastDirectory, '/projects/my-app');
    });
  });
}
