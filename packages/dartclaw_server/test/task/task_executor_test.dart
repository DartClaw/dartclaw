import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_server/src/turn_manager.dart' show TurnManager;
import 'package:dartclaw_server/src/turn_runner.dart' show TurnRunner;
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'task_executor_test_support.dart';
import '../execution_coordinator_test_support.dart';

void main() {
  late FakeTaskWorker worker;
  late WorkflowTaskExecutorTestContext ctx;
  // Aliases into ctx for use by the bare-field call sites in the test body.
  late String workspaceDir;
  late SessionService sessions;
  late MessageService messages;
  late TaskService tasks;
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

  TaskExecutor buildWorkflowCapacityExecutor({
    WorkflowCliRunner? workflowCliRunner,
    Future<void> Function(String taskId)? onAutoAccept,
    TaskEventRecorder? eventRecorder,
  }) {
    final primary = ctx.turns.executions.primary!;
    final turns = TurnManager.fromCoordinator(
      coordinator: ExecutionCoordinator(
        providerCapacities: const {'claude': 1},
        primary: primary,
        admitExecution: (request) => primary.admitTurn(request.sessionId, isHumanInput: request.isHumanInput),
        releaseAdmission: primary.releaseAdmission,
        createWorker: (_) => throw StateError('Workflow one-shot tests must not create reusable workers'),
      ),
    );
    return ctx.harness.buildWorkflowExecutor(
      turnManager: turns,
      workflowCliRunner: workflowCliRunner,
      workflowRunRepository: workflowRuns,
      workflowStepExecutionRepository: workflowStepExecutions,
      kvService: ctx.kvService,
      onAutoAccept: onAutoAccept,
      eventRecorder: eventRecorder,
    );
  }

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
    await executor.drain();

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
    await executor.drain();
    final reviewed = await tasks.get('task-2');
    final firstSessionId = reviewed!.sessionId!;

    final nextConfig = Map<String, dynamic>.from(reviewed.configJson)
      ..['pushBackCount'] = 0
      ..['pushBackComment'] = 'Address the missing detail.';
    await tasks.updateFields('task-2', configJson: nextConfig);
    await tasks.transition('task-2', TaskStatus.queued);

    worker.responseText = 'Updated output';
    await executor.pollOnce();
    await executor.drain();

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
    await executor.drain();

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
    await autoAcceptExecutor.drain();
    await autoAcceptExecutor.pollOnce();
    await autoAcceptExecutor.drain();

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
    await autoAcceptExecutor.drain();

    expect((await tasks.get('task-auto-accept-error'))!.status, TaskStatus.review);
  });

  test('fails workflow-owned tasks when auto-accept callback errors', () async {
    final autoAcceptExecutor = buildWorkflowCapacityExecutor(
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
    await autoAcceptExecutor.drain();

    expect((await tasks.get('task-auto-accept-workflow-error'))!.status, TaskStatus.review);
  });

  test('skips auto-accept for workflow git tasks so workflow promotion owns publish', () async {
    final calls = <String>[];
    final autoAcceptExecutor = buildWorkflowCapacityExecutor(
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
    await autoAcceptExecutor.drain();

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
    await budgetExecutor.drain();

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
    await failingExecutor.drain();

    final failed = await tasks.get('task-3');
    expect(failed!.status, TaskStatus.failed);
    expect(failed.sessionId, isNotNull);
    expect(failed.configJson['errorSummary'], 'Turn execution failed');
    expect(calls, isEmpty);

    final taskSession = (await sessions.listSessions(type: SessionType.task)).single;
    final taskMessages = await messages.getMessages(taskSession.id);
    expect(taskMessages.last.content, contains('[Turn failed]'));
  });

  test('generic cancelled task is not overwritten to failed when its turn fails', () async {
    final cancellingExecutor = buildExecutor();
    addTearDown(cancellingExecutor.stop);

    // A non-one-shot task cancelled mid-turn whose runner then reports a
    // non-completed outcome must stay cancelled: generic failure handling may
    // not rewrite an intentional cancellation to failed.
    worker.shouldFail = true;
    worker.beforeComplete = (_) async {
      await tasks.transition('task-cancelled-then-fails', TaskStatus.cancelled);
    };
    await tasks.create(
      id: 'task-cancelled-then-fails',
      title: 'Cancelled then failing task',
      description: 'Cancellation must win over a subsequent turn failure.',
      type: TaskType.automation,
      autoStart: true,
    );

    await cancellingExecutor.pollOnce();
    await cancellingExecutor.drain();

    final task = await tasks.get('task-cancelled-then-fails');
    expect(task!.status, TaskStatus.cancelled);
    expect(task.configJson.containsKey('errorSummary'), isFalse);
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
    await cancellingExecutor.drain();

    expect((await tasks.get('task-cancelled'))!.status, TaskStatus.cancelled);
    expect(calls, isEmpty);
  });

  test('does not throw when a workflow one-shot task is cancelled before token mirroring', () async {
    final cancellingExecutor = buildWorkflowCapacityExecutor();
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
    await cancellingExecutor.drain();

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
    await executor.drain();

    expect((await tasks.get('task-old'))!.status, TaskStatus.review);
    expect((await tasks.get('task-new'))!.status, TaskStatus.queued);
  });

  test('breaks equal queue timestamps by task ID', () async {
    worker.responseText = 'ok';
    final queuedAt = DateTime.parse('2026-03-10T10:00:00Z');
    await tasks.create(
      id: 'task-b',
      title: 'Second by ID',
      description: 'second',
      type: TaskType.automation,
      autoStart: true,
      now: queuedAt,
    );
    await tasks.create(
      id: 'task-a',
      title: 'First by ID',
      description: 'first',
      type: TaskType.automation,
      autoStart: true,
      now: queuedAt,
    );

    await executor.pollOnce();
    await executor.drain();

    expect((await tasks.get('task-a'))!.status, TaskStatus.review);
    expect((await tasks.get('task-b'))!.status, TaskStatus.queued);
  });

  test('executes tasks via pool-mode when maxConcurrentWorkers > 0', () async {
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
    final poolTurns = turnManagerForRunners([primaryRunner, taskRunner]);
    final poolExecutor = ctx.harness.buildWorkflowExecutor(turnManager: poolTurns);
    addTearDown(poolExecutor.stop);

    await tasks.create(
      id: 'task-pool',
      title: 'Pool task',
      description: 'Should execute via acquired worker.',
      type: TaskType.automation,
      autoStart: true,
    );

    final processed = await poolExecutor.pollOnce();
    await poolExecutor.drain();

    expect(processed, isTrue);
    final completed = await waitForTaskStatus(tasks, 'task-pool', until: const {TaskStatus.review});
    expect(completed?.status, TaskStatus.review);
    // The worker was released back to the pool.
    expect(poolTurns.executions.snapshot.availableWorkers, 1);
    expect(poolTurns.executions.snapshot.activeWorkers, 0);
  });

  test('uses the durable task session for first-attempt execution lifecycle events', () async {
    final poolWorker = FakeTaskWorker()..responseText = 'done';
    addTearDown(poolWorker.dispose);
    final behavior = BehaviorFileService(workspaceDir: workspaceDir);
    final primaryRunner = TurnRunner(harness: worker, messages: messages, behavior: behavior, sessions: sessions);
    final taskRunner = TurnRunner(harness: poolWorker, messages: messages, behavior: behavior, sessions: sessions);
    final poolTurns = turnManagerForRunners([primaryRunner, taskRunner]);
    final events = <ExecutionEvent>[];
    final subscription = poolTurns.executions.events.listen(events.add);
    addTearDown(subscription.cancel);
    final poolExecutor = ctx.harness.buildWorkflowExecutor(turnManager: poolTurns);
    addTearDown(poolExecutor.stop);

    await tasks.create(
      id: 'task-durable-admission',
      title: 'Durable admission identity',
      description: 'Use one identity from admission through execution release.',
      type: TaskType.automation,
      provider: 'claude',
      autoStart: true,
    );

    await poolExecutor.pollOnce();
    await poolExecutor.drain();

    final sessionId = (await tasks.get('task-durable-admission'))!.sessionId!;
    final lifecycleEvents = events.where(
      (event) => const {ExecutionEventKind.acquired, ExecutionEventKind.released}.contains(event.kind),
    );
    expect(sessionId, isNot('task-durable-admission'));
    expect(lifecycleEvents.map((event) => event.kind), contains(ExecutionEventKind.acquired));
    expect(lifecycleEvents.map((event) => event.request.sessionId).toSet(), {sessionId});
  });

  test('serializes two tasks that continue the same durable session', () async {
    final firstGate = Completer<void>();
    final secondGate = Completer<void>();
    final firstStarted = Completer<void>();
    final secondStarted = Completer<void>();
    var started = 0;
    var active = 0;
    var maxActive = 0;

    Future<void> blockTurn(String _) async {
      final index = started++;
      active++;
      if (active > maxActive) maxActive = active;
      if (index == 0) {
        firstStarted.complete();
        await firstGate.future;
      } else {
        secondStarted.complete();
        await secondGate.future;
      }
      active--;
    }

    final firstWorker = FakeTaskWorker()..beforeComplete = blockTurn;
    final secondWorker = FakeTaskWorker()..beforeComplete = blockTurn;
    addTearDown(() async {
      if (!firstGate.isCompleted) firstGate.complete();
      if (!secondGate.isCompleted) secondGate.complete();
      await firstWorker.dispose();
      await secondWorker.dispose();
    });
    final behavior = BehaviorFileService(workspaceDir: workspaceDir);
    final primaryRunner = TurnRunner(harness: worker, messages: messages, behavior: behavior, sessions: sessions);
    final firstRunner = TurnRunner(harness: firstWorker, messages: messages, behavior: behavior, sessions: sessions);
    final secondRunner = TurnRunner(harness: secondWorker, messages: messages, behavior: behavior, sessions: sessions);
    final poolTurns = turnManagerForRunners([primaryRunner, firstRunner, secondRunner]);
    final acquiredSessionIds = <String>[];
    final subscription = poolTurns.executions.events.listen((event) {
      if (event.kind == ExecutionEventKind.acquired) acquiredSessionIds.add(event.request.sessionId);
    });
    addTearDown(subscription.cancel);
    final poolExecutor = ctx.harness.buildWorkflowExecutor(turnManager: poolTurns);
    addTearDown(poolExecutor.stop);
    final sharedSession = await sessions.getOrCreateByKey(
      SessionKey.taskSession(taskId: 'shared-root'),
      type: SessionType.task,
    );
    final queuedAt = DateTime.parse('2026-03-10T10:00:00Z');
    for (final id in const ['task-continue-a', 'task-continue-b']) {
      await tasks.create(
        id: id,
        title: id,
        description: 'Continue one durable session.',
        type: TaskType.automation,
        provider: 'claude',
        autoStart: true,
        configJson: {'_continueSessionId': sharedSession.id},
        now: queuedAt,
      );
    }

    final poll = poolExecutor.pollOnce();
    await firstStarted.future;
    await pumpEventQueue();
    expect(secondStarted.isCompleted, isFalse);
    expect((await tasks.get('task-continue-b'))!.status, TaskStatus.queued);

    firstGate.complete();
    await secondStarted.future;
    expect(maxActive, 1);
    secondGate.complete();
    await poll;
    await poolExecutor.drain();

    expect((await tasks.get('task-continue-a'))!.sessionId, sharedSession.id);
    expect((await tasks.get('task-continue-b'))!.sessionId, sharedSession.id);
    expect(acquiredSessionIds, [sharedSession.id, sharedSession.id]);
  });

  test('provider-less workflow acquires default-provider capacity without creating a worker', () async {
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
    final executions = ExecutionCoordinator(
      providerCapacities: const {'codex': 1},
      primary: primaryRunner,
      createWorker: (request) async {
        spawnRequests.add(request.providerId);
        return TurnRunner(
          harness: codexWorker,
          messages: messages,
          behavior: behavior,
          sessions: sessions,
          providerId: 'codex',
        );
      },
    );
    final poolTurns = TurnManager.fromCoordinator(coordinator: executions);
    final poolExecutor = ctx.harness.buildWorkflowExecutor(
      turnManager: poolTurns,
      workflowCliRunner: cliRunner,
      workflowRunRepository: workflowRuns,
      workflowStepExecutionRepository: workflowStepExecutions,
      limits: const TaskExecutorLimits(defaultProviderId: 'codex'),
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
    await poolExecutor.drain();

    expect(processed, isTrue);
    final completed = await waitForTaskStatus(tasks, 'task-pool-default-provider', until: const {TaskStatus.review});
    expect(spawnRequests, isEmpty);
    expect(executable, 'codex');
    expect(completed?.status, TaskStatus.review);
    expect(executions.snapshot.providers.keys, ['codex']);
  });

  test('lazy spawn provider demand follows FIFO task ordering', () async {
    final behavior = BehaviorFileService(workspaceDir: workspaceDir);
    final primaryRunner = TurnRunner(harness: worker, messages: messages, behavior: behavior, sessions: sessions);
    final spawnRequests = <String?>[];
    final spawnRequested = Completer<void>();
    final executions = ExecutionCoordinator(
      providerCapacities: const {'codex': 1, 'claude': 1},
      primary: primaryRunner,
      admitExecution: (request) => primaryRunner.admitTurn(request.sessionId, isHumanInput: request.isHumanInput),
      releaseAdmission: primaryRunner.releaseAdmission,
      createWorker: (request) async {
        spawnRequests.add(request.providerId);
        if (!spawnRequested.isCompleted) spawnRequested.complete();
        final worker = FakeTaskWorker()..responseText = '${request.providerId} result';
        return TurnRunner(
          harness: worker,
          messages: messages,
          behavior: behavior,
          sessions: sessions,
          providerId: request.providerId,
        );
      },
    );
    addTearDown(executions.dispose);
    final poolTurns = TurnManager.fromCoordinator(coordinator: executions);
    final poolExecutor = ctx.harness.buildWorkflowExecutor(turnManager: poolTurns);
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
    await poolExecutor.drain();
    await spawnRequested.future;

    expect(processed, isTrue);
    expect(spawnRequests, ['codex', 'claude']);
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
    final primaryRunner = TurnRunner(
      harness: worker,
      messages: messages,
      behavior: behavior,
      sessions: sessions,
      executionPolicy: const ExecutionPolicy.container('workspace'),
    );
    final taskRunner1 = TurnRunner(
      harness: poolWorker1,
      messages: messages,
      behavior: behavior,
      sessions: sessions,
      executionPolicy: const ExecutionPolicy.container('restricted'),
    );
    final taskRunner2 = TurnRunner(
      harness: poolWorker2,
      messages: messages,
      behavior: behavior,
      sessions: sessions,
      executionPolicy: const ExecutionPolicy.container('restricted'),
    );
    final poolTurns = turnManagerForRunners([primaryRunner, taskRunner1, taskRunner2]);
    final poolExecutor = ctx.harness.buildWorkflowExecutor(turnManager: poolTurns);
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
    expect(poolTurns.executions.snapshot.availableWorkers, 0);
    expect(poolTurns.executions.snapshot.activeWorkers, 2);

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
    final primaryRunner = TurnRunner(
      harness: worker,
      messages: messages,
      behavior: behavior,
      sessions: sessions,
      executionPolicy: const ExecutionPolicy.container('workspace'),
    );
    final taskRunner1 = TurnRunner(harness: poolWorker1, messages: messages, behavior: behavior, sessions: sessions);
    final taskRunner2 = TurnRunner(harness: poolWorker2, messages: messages, behavior: behavior, sessions: sessions);
    final poolTurns = turnManagerForRunners([primaryRunner, taskRunner1, taskRunner2]);
    final poolExecutor = ctx.harness.buildWorkflowExecutor(
      turnManager: poolTurns,
      workflowRunRepository: workflowRuns,
      workflowStepExecutionRepository: workflowStepExecutions,
      worktreeManager: worktreeManager,
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
    final contentionExecutor = ctx.harness.buildWorkflowExecutor(
      turnManager: contentionTurns,
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
    await contentionExecutor.drain();

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
    await traceExecutor.drain();
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
    await executor.drain();

    expect(processed, isTrue);
    expect((await tasks.get('task-no-trace'))!.status, TaskStatus.review);
  });

  group('prompt scope selection', () {
    late CapturingTurnManager capturing;
    late TaskExecutor scopeExecutor;
    const workflowWorkspaceDir = '/tmp/workflow-workspace';

    setUp(() {
      capturing = CapturingTurnManager(messages, worker);
      scopeExecutor = ctx.harness.buildWorkflowExecutor(
        turnManager: capturing,
        workflowStepExecutionRepository: workflowStepExecutions,
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
      await scopeExecutor.drain();
      await pumpEventQueue();
      expect((await tasks.get('task-scope-regular'))!.status, TaskStatus.review);
      expect(capturing.lastPromptScope, PromptScope.task);
      expect(capturing.lastTaskId, 'task-scope-regular');
    });

    test('task tool policy is turn-local and does not leak to the next task', () async {
      await tasks.create(
        id: 'task-policy-scoped',
        title: 'Scoped policy',
        description: 'Carry a closed policy for this turn only.',
        type: TaskType.automation,
        autoStart: true,
        configJson: const {
          'allowedTools': ['file_read'],
          'readOnly': true,
        },
      );
      await scopeExecutor.pollOnce();
      await scopeExecutor.drain();
      expect(capturing.lastAllowedTools, ['file_read']);
      expect(capturing.lastReadOnly, isTrue);

      await tasks.create(
        id: 'task-policy-default',
        title: 'Default policy',
        description: 'Must not inherit the preceding task policy.',
        type: TaskType.automation,
        autoStart: true,
      );
      await scopeExecutor.pollOnce();
      await scopeExecutor.drain();

      expect(capturing.lastAllowedTools, isNull);
      expect(capturing.lastReadOnly, isFalse);
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
      await scopeExecutor.drain();
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
      await scopeExecutor.drain();
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
      await projectExecutor.drain();
      await pumpEventQueue();

      expect(capturing.lastPromptScope, PromptScope.task);
      expect(capturing.lastBehaviorOverride?.workspaceDir, workflowWorkspaceDir);
      expect(capturing.lastBehaviorOverride?.projectDir, '/projects/my-app');
      expect(capturing.lastDirectory, '/projects/my-app');
    });
  });
}
