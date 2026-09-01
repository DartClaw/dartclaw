import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_runtime/src/turn_manager.dart' show TurnManager;
import 'package:dartclaw_runtime/src/turn_runner.dart' show TurnRunner;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness, FakeContentClassifier;
import 'package:test/test.dart';

import 'task_executor_test_support.dart';

void main() {
  late FakeTaskWorker worker;
  late WorkflowTaskExecutorTestContext context;

  setUp(() async {
    worker = FakeTaskWorker()..responseText = 'shared runner reply';
    context = WorkflowTaskExecutorTestContext(worker);
    await context.setUp();
  });

  tearDown(() => context.tearDown(workerDispose: worker.dispose));

  test('S01 workflow step reaches its provider through the leased shared turn runner', () async {
    final primary = context.turns.executions.primary!;
    final executions = ExecutionCoordinator(
      providerCapacities: const {'claude': 1},
      primary: primary,
      admitExecution: (request) => primary.admitTurn(request.sessionId, isHumanInput: request.isHumanInput),
      releaseAdmission: primary.releaseAdmission,
      createWorker: (request) async => TurnRunner(
        turnLimits: const TurnLimitsConfig.defaults(),
        harness: worker,
        messages: context.messages,
        behavior: BehaviorFileService(workspaceDir: context.workspaceDir),
        sessions: context.sessions,
        kv: context.kvService,
        providerId: request.providerId,
        executionPolicy: request.policy,
      ),
    );
    final turns = TurnManager.fromCoordinator(turnLimits: const TurnLimitsConfig.defaults(), coordinator: executions);
    addTearDown(executions.dispose);
    final executor = context.buildExecutor(turnManager: turns);
    addTearDown(executor.stop);

    await context.tasks.create(
      id: 'task-guarded-step',
      title: 'Guarded workflow step',
      description: 'Run on the shared turn runner.',
      configJson: const {'needsWorktree': false},
      autoStart: true,
      agentExecutionId: 'ae-task-guarded-step',
      workflowRunId: 'wf-guarded-step',
      provider: 'claude',
    );
    await context.seedWorkflowExecution(
      'task-guarded-step',
      agentExecutionId: 'ae-task-guarded-step',
      workflowRunId: 'wf-guarded-step',
    );

    await executor.pollOnce();
    await executor.drain();

    expect((await context.tasks.get('task-guarded-step'))?.status, TaskStatus.review);
    expect(worker.turnCallCount, 1);
    final sessionId = (await context.tasks.get('task-guarded-step'))!.sessionId!;
    final transcript = await context.messages.getMessages(sessionId);
    expect(transcript.map((message) => message.role).toList(), ['user', 'assistant']);
    expect(transcript.first.content, contains('## Task: Guarded workflow step\n\nRun on the shared turn runner.'));
    expect(transcript.first.content, contains('### Working Directory'));
    expect(transcript.last.content, 'shared runner reply');
  });

  test('S02 outbound ContentGuard blocks a workflow reply on the shared path', () async {
    worker.responseText = 'blocked provider reply';
    final primary = context.turns.executions.primary!;
    final guardChain = GuardChain(
      guards: [
        ContentGuard(
          scan: ContentScan(classifier: FakeContentClassifier(result: 'prompt_injection')),
        ),
      ],
    );
    final executions = ExecutionCoordinator(
      providerCapacities: const {'claude': 1},
      primary: primary,
      admitExecution: (request) => primary.admitTurn(request.sessionId, isHumanInput: request.isHumanInput),
      releaseAdmission: primary.releaseAdmission,
      createWorker: (request) async => TurnRunner(
        turnLimits: const TurnLimitsConfig.defaults(),
        harness: worker,
        messages: context.messages,
        behavior: BehaviorFileService(workspaceDir: context.workspaceDir),
        sessions: context.sessions,
        kv: context.kvService,
        guardChain: guardChain,
        providerId: request.providerId,
        executionPolicy: request.policy,
      ),
    );
    final turns = TurnManager.fromCoordinator(turnLimits: const TurnLimitsConfig.defaults(), coordinator: executions);
    addTearDown(executions.dispose);
    final executor = context.buildExecutor(turnManager: turns);
    addTearDown(executor.stop);

    await context.tasks.create(
      id: 'task-blocked-step',
      title: 'Blocked workflow step',
      description: 'The provider response is unsafe.',
      configJson: const {'needsWorktree': false},
      autoStart: true,
      agentExecutionId: 'ae-task-blocked-step',
      workflowRunId: 'wf-blocked-step',
      provider: 'claude',
    );
    await context.seedWorkflowExecution(
      'task-blocked-step',
      agentExecutionId: 'ae-task-blocked-step',
      workflowRunId: 'wf-blocked-step',
    );

    await executor.pollOnce();
    await executor.drain();

    final task = (await context.tasks.get('task-blocked-step'))!;
    expect(task.status, TaskStatus.failed);
    expect(worker.turnCallCount, 1);
    final transcript = await context.messages.getMessages(task.sessionId!);
    expect(transcript.map((message) => message.role).toList(), ['user', 'assistant']);
    expect(transcript.last.content, startsWith('[Response blocked by guard:'));
    expect(transcript.map((message) => message.content), isNot(contains('blocked provider reply')));
  });

  test('a workflow prompt blocked by the shared fixture guard never reaches the harness', () async {
    final executor = context.buildExecutor();
    addTearDown(executor.stop);

    await context.tasks.create(
      id: 'task-blocked-prompt',
      title: 'Blocked workflow prompt',
      description: 'BLOCK_WORKFLOW_PROMPT',
      configJson: const {'needsWorktree': false},
      autoStart: true,
      agentExecutionId: 'ae-task-blocked-prompt',
      workflowRunId: 'wf-blocked-prompt',
      provider: 'claude',
    );
    await context.seedWorkflowExecution(
      'task-blocked-prompt',
      agentExecutionId: 'ae-task-blocked-prompt',
      workflowRunId: 'wf-blocked-prompt',
    );

    await executor.pollOnce();
    await executor.drain();

    final task = (await context.tasks.get('task-blocked-prompt'))!;
    expect(task.status, TaskStatus.failed);
    expect(worker.turnCallCount, 0);
    final transcript = await context.messages.getMessages(task.sessionId!);
    expect(transcript.last.content, startsWith('[Blocked by guard:'));
  });

  test('the shared workflow fixture applies and clears the task tool policy around a harness turn', () async {
    final duringTurn = <String, GuardVerdict>{};
    Future<GuardVerdict> probe(String sessionId, String toolName) => context.harness.workflowToolFilterGuard.evaluate(
      GuardContext(hookPoint: 'beforeToolCall', toolName: toolName, sessionId: sessionId, timestamp: DateTime.now()),
    );
    worker.beforeComplete = (sessionId) async {
      for (final toolName in ['shell', 'file_read', 'file_write']) {
        duringTurn[toolName] = await probe(sessionId, toolName);
      }
    };
    final executor = context.buildExecutor();
    addTearDown(executor.stop);

    await context.tasks.create(
      id: 'task-tool-policy',
      title: 'Tool policy workflow step',
      description: 'Observe the task policy during the harness turn.',
      autoStart: true,
      agentExecutionId: 'ae-task-tool-policy',
      workflowRunId: 'wf-task-tool-policy',
      provider: 'claude',
      configJson: const {
        'needsWorktree': false,
        'allowedTools': ['file_read'],
        'readOnly': true,
      },
    );
    await context.seedWorkflowExecution(
      'task-tool-policy',
      agentExecutionId: 'ae-task-tool-policy',
      workflowRunId: 'wf-task-tool-policy',
    );

    await executor.pollOnce();
    await executor.drain();

    final task = (await context.tasks.get('task-tool-policy'))!;
    expect(task.status, TaskStatus.review);
    expect(duringTurn['shell']?.isBlock, isTrue);
    expect(duringTurn['file_read']?.isPass, isTrue);
    expect(duringTurn['file_write']?.isBlock, isTrue);
    expect((await probe(task.sessionId!, 'shell')).isPass, isTrue);
    expect((await probe(task.sessionId!, 'file_write')).isPass, isTrue);
  });

  // The refusal this used to pin was removed with the structured-output
  // transport fix: a provider that cannot enforce a schema no longer loses the
  // step, because the structure is host-enforced from the finalizer envelope.
  // What must still hold is that nothing claims provider enforcement it lacks —
  // the harness receives no schema.
  test('a schema-declaring step runs on a provider that enforces no schema, without receiving one', () async {
    var workerAllocations = 0;
    final primary = context.turns.executions.primary!;
    final executions = ExecutionCoordinator(
      providerCapacities: const {'claude': 1},
      primary: primary,
      admitExecution: (request) => primary.admitTurn(request.sessionId, isHumanInput: request.isHumanInput),
      releaseAdmission: primary.releaseAdmission,
      createWorker: (request) async {
        workerAllocations++;
        return TurnRunner(
          turnLimits: const TurnLimitsConfig.defaults(),
          harness: worker,
          messages: context.messages,
          behavior: BehaviorFileService(workspaceDir: context.workspaceDir),
          sessions: context.sessions,
          kv: context.kvService,
          providerId: request.providerId,
          executionPolicy: request.policy,
        );
      },
    );
    final turns = TurnManager.fromCoordinator(turnLimits: const TurnLimitsConfig.defaults(), coordinator: executions);
    addTearDown(executions.dispose);
    final harnessFactory = HarnessFactory()..register('claude', (_) => FakeAgentHarness());
    final executor = context.buildExecutor(turnManager: turns, harnessFactory: harnessFactory);
    addTearDown(executor.stop);

    await context.tasks.create(
      id: 'task-unsupported-schema',
      title: 'Unsupported schema',
      description: 'Must fail before allocation.',
      configJson: const {'needsWorktree': false},
      autoStart: true,
      agentExecutionId: 'ae-task-unsupported-schema',
      workflowRunId: 'wf-unsupported-schema',
      provider: 'claude',
    );
    await context.seedWorkflowExecution(
      'task-unsupported-schema',
      agentExecutionId: 'ae-task-unsupported-schema',
      workflowRunId: 'wf-unsupported-schema',
      structuredSchema: const {'type': 'object'},
    );

    await executor.pollOnce();
    await executor.drain();

    // The step reaches a worker and runs. It still fails here, but on the
    // envelope this scripted worker never produces — not on the provider's
    // capability, which is the refusal that used to happen before allocation.
    final ran = (await context.tasks.get('task-unsupported-schema'))!;
    expect(workerAllocations, 1, reason: 'the step must reach a worker rather than be refused before allocation');
    expect(worker.turnCallCount, greaterThan(0));
    expect(worker.lastOutputSchema, isNull, reason: 'the schema must not reach a harness that cannot enforce it');
    expect(
      ran.configJson['errorSummary'],
      isNot(contains('structured output')),
      reason: 'the provider capability must no longer decide this step',
    );

    await context.tasks.create(
      id: 'task-schema-free',
      title: 'Schema-free workflow step',
      description: 'Runs without provider schema enforcement.',
      configJson: const {'needsWorktree': false},
      autoStart: true,
      agentExecutionId: 'ae-task-schema-free',
      workflowRunId: 'wf-schema-free',
      provider: 'claude',
    );
    await context.seedWorkflowExecution(
      'task-schema-free',
      agentExecutionId: 'ae-task-schema-free',
      workflowRunId: 'wf-schema-free',
    );

    await executor.pollOnce();
    await executor.drain();

    // One allocation, not two: the coordinator reuses a healthy idle worker for
    // the same provider and policy.
    expect((await context.tasks.get('task-schema-free'))?.status, TaskStatus.review);
    expect(workerAllocations, 1);
  });
}
