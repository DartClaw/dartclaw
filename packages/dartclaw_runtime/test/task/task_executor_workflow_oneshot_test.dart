import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_runtime/src/task/task_budget_policy.dart' show lastFailureKindKey;
import 'package:dartclaw_runtime/src/turn_manager.dart' show TurnManager;
import 'package:dartclaw_runtime/src/turn_runner.dart' show TurnRunner, TurnRunnerCancellation;
import 'package:dartclaw_runtime/src/turn_wait_status.dart' show TurnCancelReason;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show WorkflowTaskConfig, executionEnvelopeMarkerKey, executionEnvelopeVersion;
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

import 'task_executor_test_support.dart';

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

final _finalizerEnvelopeOutput = <String, dynamic>{
  'outputs': {'summary': 'final'},
  'step_outcome': {'outcome': 'succeeded', 'reason': 'ok'},
};

final class _TurnTimerFakeTime {
  static final _initialTime = DateTime(2026);
  final _async = FakeAsync(initialTime: _initialTime);

  DateTime now() => _async.getClock(_initialTime).now();

  Timer create(Duration duration, void Function() callback) => _async.run((_) => Timer(duration, callback));

  Future<void> elapse(Duration duration) async {
    await pumpEventQueue();
    _async.elapse(duration);
    await pumpEventQueue();
  }
}

void main() {
  late FakeAgentHarness harness;
  late _PausingUserMessageService pausingMessages;
  late WorkflowTaskExecutorTestContext context;
  late ExecutionCoordinator executions;
  late TaskExecutor executor;
  late EventBus eventBus;
  late TurnRunner timedRunner;
  late List<ExecutionRequest> workerRequests;
  late Completer<void>? workerAcquisitionEntered;
  late Completer<void>? releaseWorkerAcquisition;

  setUp(() async {
    harness = FakeAgentHarness(supportsStructuredOutput: true, supportsProviderSessionResume: true);
    context = WorkflowTaskExecutorTestContext(harness);
    await context.setUp(
      messageServiceFactory: (baseDir) => pausingMessages = _PausingUserMessageService(baseDir: baseDir),
    );
    eventBus = EventBus();
    workerRequests = [];
    workerAcquisitionEntered = null;
    releaseWorkerAcquisition = null;
    final primary = context.turns.executions.primary!;
    executions = ExecutionCoordinator(
      providerCapacities: const {'claude': 1, 'codex': 1},
      primary: primary,
      admitExecution: (request) => primary.admitTurn(request.sessionId, isHumanInput: request.isHumanInput),
      releaseAdmission: primary.releaseAdmission,
      createWorker: (request) async {
        final acquisitionEntered = workerAcquisitionEntered;
        if (acquisitionEntered != null) {
          acquisitionEntered.complete();
          await releaseWorkerAcquisition!.future;
        }
        workerRequests.add(request);
        return TurnRunner(
          turnLimits: const TurnLimitsConfig.defaults(),
          harness: harness,
          messages: context.messages,
          behavior: BehaviorFileService(workspaceDir: context.workspaceDir),
          sessions: context.sessions,
          kv: context.kvService,
          providerId: request.providerId,
          executionPolicy: request.policy,
        );
      },
    );
    final factory = HarnessFactory()
      ..register(
        'claude',
        (_) => FakeAgentHarness(supportsStructuredOutput: true, supportsProviderSessionResume: true),
      );
    executor = context.buildExecutor(
      turnManager: TurnManager.fromCoordinator(turnLimits: const TurnLimitsConfig.defaults(), coordinator: executions),
      harnessFactory: factory,
      eventBus: eventBus,
    );
  });

  tearDown(() async {
    await executor.stop();
    await executions.dispose();
    await context.tearDown();
  });

  Future<void> createStep(
    String id, {
    String? provider = 'claude',
    int? maxTokens,
    Map<String, dynamic> configJson = const {},
    Map<String, dynamic>? structuredSchema,
    List<String>? followUps,
    String? providerSessionId,
    int maxRetries = 0,
  }) async {
    await context.tasks.create(
      id: id,
      title: 'Workflow step $id',
      description: 'Run $id.',
      autoStart: true,
      agentExecutionId: 'ae-$id',
      workflowRunId: 'wf-$id',
      provider: provider,
      maxTokens: maxTokens,
      maxRetries: maxRetries,
      configJson: {'needsWorktree': false, ...configJson},
    );
    await context.seedWorkflowExecution(
      id,
      agentExecutionId: 'ae-$id',
      workflowRunId: 'wf-$id',
      structuredSchema: structuredSchema,
      followUpPrompts: followUps,
      providerSessionId: providerSessionId,
    );
  }

  Future<_TurnTimerFakeTime> useTimedWorkflowGraph(TurnLimitsConfig limits) async {
    await executor.stop();
    await executions.dispose();
    harness = FakeAgentHarness(supportsStructuredOutput: true, supportsProviderSessionResume: true);
    final time = _TurnTimerFakeTime();
    final primary = context.turns.executions.primary!;
    executions = ExecutionCoordinator(
      providerCapacities: const {'claude': 1},
      primary: primary,
      admitExecution: (request) => primary.admitTurn(request.sessionId, isHumanInput: request.isHumanInput),
      releaseAdmission: primary.releaseAdmission,
      createWorker: (request) async {
        return timedRunner = TurnRunner(
          turnLimits: limits,
          harness: harness,
          messages: context.messages,
          behavior: BehaviorFileService(workspaceDir: context.workspaceDir),
          sessions: context.sessions,
          kv: context.kvService,
          providerId: request.providerId,
          executionPolicy: request.policy,
          turnMonitorTimerFactory: time.create,
          turnMonitorNow: time.now,
        );
      },
    );
    executor = context.buildExecutor(
      turnManager: TurnManager.fromCoordinator(turnLimits: limits, coordinator: executions),
      eventBus: eventBus,
    );
    return time;
  }

  Future<void> drive(List<TurnResult> results, {List<String> replies = const []}) async {
    await executor.pollOnce();
    for (var index = 0; index < results.length; index++) {
      await harness.turnInvoked.timeout(const Duration(seconds: 3));
      if (index < replies.length && replies[index].isNotEmpty) harness.emit(DeltaEvent(replies[index]));
      harness.completeSuccess(results[index]);
    }
    await executor.drain();
  }

  Future<void> drainAfterCleaningUpUnexpectedTurn() async {
    final drain = executor.drain();
    final unexpectedTurn = await Future.any([drain.then((_) => false), harness.turnInvoked.then((_) => true)]);
    if (unexpectedTurn) {
      harness.completeSuccess(const TurnResult());
      await drain;
    }
  }

  test('prompt chain and finalizer persist each role once and aggregate usage once', () async {
    final progress = <WorkflowCliTurnProgressEvent>[];
    final subscription = eventBus.on<WorkflowCliTurnProgressEvent>().listen(progress.add);
    addTearDown(subscription.cancel);
    await createStep(
      'prompt-chain',
      structuredSchema: _summaryEnvelopeSchema,
      followUps: ['Follow up one', 'Follow up two'],
    );

    await drive(
      [
        const TurnResult(providerSessionId: 'provider-session', inputTokens: 100, outputTokens: 10),
        const TurnResult(providerSessionId: 'provider-session', inputTokens: 200, outputTokens: 20),
        const TurnResult(providerSessionId: 'provider-session', inputTokens: 300, outputTokens: 30),
        TurnResult(
          providerSessionId: 'provider-session',
          structuredOutput: _finalizerEnvelopeOutput,
          inputTokens: 400,
          outputTokens: 40,
        ),
      ],
      replies: const ['main reply', 'follow-up one reply', 'follow-up two reply'],
    );

    final task = (await context.tasks.get('prompt-chain'))!;
    expect(task.status, TaskStatus.review);
    final transcript = await context.messages.getMessages(task.sessionId!);
    expect(transcript.where((message) => message.role == 'user'), hasLength(4));
    expect(transcript.where((message) => message.role == 'assistant'), hasLength(4));
    expect(transcript.where((message) => message.role == 'system'), isEmpty);
    expect(transcript.map((message) => message.role), [
      'user',
      'assistant',
      'user',
      'assistant',
      'user',
      'assistant',
      'user',
      'assistant',
    ]);
    expect(transcript.last.content, jsonEncode(_finalizerEnvelopeOutput));
    final execution = await context.workflowStepExecutions.getByTaskId('prompt-chain');
    expect(execution?.providerSessionId, 'provider-session');
    expect(execution?.stepTokenBreakdown, {'inputTokensNew': 1000, 'cacheReadTokens': 0, 'outputTokens': 100});
    expect(execution?.structuredOutput?[executionEnvelopeMarkerKey], executionEnvelopeVersion);
    expect(progress.map((event) => event.turnIndex), [1, 2, 3, 4]);
    expect(progress.map((event) => event.cumulativeTokens), [110, 330, 660, 1100]);

    final sessionCost = jsonDecode((await context.kvService.get('session_cost:${task.sessionId}'))!) as Map;
    expect(sessionCost['turn_count'], 4);
    expect(sessionCost['input_tokens'], 1000);
    expect(sessionCost['output_tokens'], 100);
  });

  test('schema-free multi-turn step leaves exactly one row per prompt and reply', () async {
    await createStep('schema-free-chain', followUps: ['Second', 'Third']);
    await drive(
      const [TurnResult(), TurnResult(), TurnResult()],
      replies: const ['First reply', 'Second reply', 'Third reply'],
    );

    final task = (await context.tasks.get('schema-free-chain'))!;
    expect(task.status, TaskStatus.review);
    final transcript = await context.messages.getMessages(task.sessionId!);
    expect(transcript.where((message) => message.role == 'user'), hasLength(3));
    expect(transcript.where((message) => message.role == 'assistant'), hasLength(3));
    expect(transcript, hasLength(6));
  });

  test('provider cancellation and failure preserve task outcome mapping', () async {
    await createStep('cancelled-step');
    await drive(const [TurnResult(stopReason: 'cancelled')]);
    expect((await context.tasks.get('cancelled-step'))?.status, TaskStatus.cancelled);

    await createStep('failed-step');
    await drive(const [TurnResult(stopReason: 'error', error: 'provider failed')]);
    expect((await context.tasks.get('failed-step'))?.status, TaskStatus.failed);
  });

  test('workflow override above the global budget governs initial and follow-up turns', () async {
    final time = await useTimedWorkflowGraph(
      const TurnLimitsConfig(stallTimeout: Duration.zero, turnTimeout: Duration(seconds: 2)),
    );
    await createStep(
      'larger-turn-budget',
      configJson: const {WorkflowTaskConfig.workflowTurnTimeoutSeconds: 10},
      followUps: const ['Continue after the global budget'],
    );

    await executor.pollOnce();
    await harness.turnInvoked;
    await time.elapse(const Duration(seconds: 3));
    expect(harness.hasPendingTurn, isTrue);
    harness.completeSuccess();

    await harness.turnInvoked;
    await time.elapse(const Duration(seconds: 3));
    expect(harness.hasPendingTurn, isTrue);
    harness.completeSuccess();
    await executor.drain();

    expect((await context.tasks.get('larger-turn-budget'))?.status, TaskStatus.review);
    expect(harness.turnCallCount, 2);
  });

  test('workflow override below the global budget fails through the task graph', () async {
    final time = await useTimedWorkflowGraph(
      const TurnLimitsConfig(stallTimeout: Duration.zero, turnTimeout: Duration(seconds: 10)),
    );
    await createStep('smaller-turn-budget', configJson: const {WorkflowTaskConfig.workflowTurnTimeoutSeconds: 2});

    await executor.pollOnce();
    await harness.turnInvoked;
    await time.elapse(const Duration(seconds: 2));
    await executor.drain();

    final task = (await context.tasks.get('smaller-turn-budget'))!;
    expect(task.status, TaskStatus.failed);
    expect(task.configJson['errorSummary'], contains('wall-clock'));
  });

  test('workflow zero override disables the global budget on initial and follow-up turns', () async {
    final time = await useTimedWorkflowGraph(
      const TurnLimitsConfig(stallTimeout: Duration.zero, turnTimeout: Duration(seconds: 2)),
    );
    await createStep(
      'disabled-turn-budget',
      configJson: const {WorkflowTaskConfig.workflowTurnTimeoutSeconds: 0},
      followUps: const ['Continue without a wall clock'],
    );

    await executor.pollOnce();
    await harness.turnInvoked;
    await time.elapse(const Duration(seconds: 20));
    expect(harness.hasPendingTurn, isTrue);
    harness.completeSuccess();

    await harness.turnInvoked;
    await time.elapse(const Duration(seconds: 20));
    expect(harness.hasPendingTurn, isTrue);
    harness.completeSuccess();
    await executor.drain();

    expect((await context.tasks.get('disabled-turn-budget'))?.status, TaskStatus.review);
    expect(harness.turnCallCount, 2);
  });

  test('breach kinds drive retry dedup while plain cancellation stays cancelled', () async {
    await useTimedWorkflowGraph(
      const TurnLimitsConfig(
        stallTimeout: Duration(milliseconds: 100),
        stallAction: TurnProgressAction.cancel,
        turnTimeout: Duration(milliseconds: 300),
      ),
    );
    await createStep('limit-retry', maxRetries: 3);

    Future<void> cancelFor(TurnLimitBreach breach) async {
      final sessionId = timedRunner.activeSessionIds.single;
      await timedRunner.cancelTurnById(
        sessionId,
        timedRunner.activeTurnId(sessionId)!,
        TurnCancelReason.automationCancel,
        enforceCanCancel: false,
        limitBreach: breach,
        limitBudget: const Duration(milliseconds: 100),
      );
    }

    await executor.pollOnce();
    await harness.turnInvoked;
    await cancelFor(TurnLimitBreach.stall);
    await executor.drain();
    var task = (await context.tasks.get('limit-retry'))!;
    expect(task.status, TaskStatus.queued, reason: '${task.configJson}');
    expect(task.retryCount, 1);
    expect(task.configJson[lastFailureKindKey], 'limit:stall');

    await executor.pollOnce();
    await harness.turnInvoked;
    await cancelFor(TurnLimitBreach.turnTimeout);
    await executor.drain();
    task = (await context.tasks.get('limit-retry'))!;
    expect(task.status, TaskStatus.queued);
    expect(task.retryCount, 2);
    expect(task.configJson[lastFailureKindKey], 'limit:turn-timeout');

    await executor.pollOnce();
    await harness.turnInvoked;
    await cancelFor(TurnLimitBreach.turnTimeout);
    await executor.drain();
    task = (await context.tasks.get('limit-retry'))!;
    expect(task.status, TaskStatus.failed);
    expect(task.retryCount, 2);

    await createStep('plain-cancel');
    await executor.pollOnce();
    await harness.turnInvoked;
    harness.completeSuccess(const TurnResult(stopReason: 'cancelled'));
    await executor.drain();
    expect((await context.tasks.get('plain-cancel'))!.status, TaskStatus.cancelled);
  });

  test('a failed workflow outcome wins a concurrent task cancellation', () async {
    await createStep('cancelled-then-failed');

    await executor.pollOnce();
    await harness.turnInvoked.timeout(const Duration(seconds: 3));
    await context.tasks.transition('cancelled-then-failed', TaskStatus.cancelled);
    harness.completeSuccess(const TurnResult(stopReason: 'error', error: 'provider failed'));
    await executor.drain();

    expect((await context.tasks.get('cancelled-then-failed'))?.status, TaskStatus.failed);
  });

  test('shutdown cancellation before the first workflow turn prevents provider execution', () async {
    await createStep('cancel-before-first');
    pausingMessages.pauseOnUserInsert(1);

    await executor.pollOnce();
    await pausingMessages.paused;
    await executor.cancelActive();
    pausingMessages.resume();
    await drainAfterCleaningUpUnexpectedTurn();

    expect(harness.turnCallCount, 0);
    expect((await context.tasks.get('cancel-before-first'))?.status, TaskStatus.cancelled);
  });

  test('shutdown cancellation waits for in-flight worker acquisition before snapshotting leased turns', () async {
    await createStep('cancel-during-acquisition');
    workerAcquisitionEntered = Completer<void>();
    releaseWorkerAcquisition = Completer<void>();

    final poll = executor.pollOnce();
    await workerAcquisitionEntered!.future;
    executor.stopPolling();
    var cancellationCompleted = false;
    final cancellation = executor.cancelActive().whenComplete(() => cancellationCompleted = true);
    await pumpEventQueue();
    final completedBeforeRegistration = cancellationCompleted;
    final callsBeforeRegistration = harness.turnCallCount;

    releaseWorkerAcquisition!.complete();
    await poll;
    await cancellation;
    await drainAfterCleaningUpUnexpectedTurn();

    expect(completedBeforeRegistration, isFalse);
    expect(callsBeforeRegistration, 0);
    expect(harness.turnCallCount, 0);
    expect((await context.tasks.get('cancel-during-acquisition'))?.status, TaskStatus.cancelled);
  });

  test('shutdown cancellation between workflow turns prevents the follow-up provider turn', () async {
    await createStep('cancel-between-turns', followUps: ['Must not run']);
    pausingMessages.pauseOnUserInsert(2);

    await executor.pollOnce();
    await harness.turnInvoked;
    harness.completeSuccess(const TurnResult());
    await pausingMessages.paused;
    await executor.cancelActive();
    pausingMessages.resume();
    await drainAfterCleaningUpUnexpectedTurn();

    expect(harness.turnCallCount, 1);
    expect((await context.tasks.get('cancel-between-turns'))?.status, TaskStatus.cancelled);
  });

  test('a follow-up prompt is refused when the preceding turn exhausts the budget', () async {
    await createStep('follow-up-budget', maxTokens: 50, followUps: ['Must not run']);

    await drive(const [TurnResult(inputTokens: 45, outputTokens: 10)], replies: const ['First reply']);

    final task = (await context.tasks.get('follow-up-budget'))!;
    expect(task.status, TaskStatus.failed);
    expect(harness.turnCallCount, 1);
    final transcript = await context.messages.getMessages(task.sessionId!);
    expect(transcript.map((message) => message.role), ['user', 'assistant']);
    expect(transcript.first.content, contains('Run follow-up-budget.'));
    expect(transcript.first.content, contains('### Working Directory'));
    expect(transcript.last.content, 'First reply');
    expect(transcript.map((message) => message.content).join('\n'), isNot(contains('Must not run')));
  });

  test('provider, model and effort inputs reach the harness seam', () async {
    await createStep(
      'turn-inputs',
      configJson: const {
        'model': 'claude-test-model',
        'effort': 'high',
        'allowedTools': ['shell', 'file_read'],
        'readOnly': true,
        WorkflowTaskConfig.workflowTurnTimeoutSeconds: 7,
      },
    );
    await drive(const [TurnResult()], replies: const ['done']);

    expect((await context.tasks.get('turn-inputs'))?.status, TaskStatus.review);
    expect(harness.lastModel, 'claude-test-model');
    expect(harness.lastEffort, 'high');
    expect(harness.lastDirectory, context.workspaceDir);
    expect(harness.lastAgentId, 'workflow-step');
    expect(workerRequests.single.providerId, 'claude');
    expect(workerRequests.single.allowedTools, ['shell', 'file_read']);
  });

  test('configured default provider is used for provider-less workflow work', () async {
    final defaultFactory = HarnessFactory()
      ..register('codex', (_) => FakeAgentHarness())
      ..register('claude', (_) => FakeAgentHarness());
    await executor.stop();
    executor = context.buildExecutor(
      turnManager: TurnManager.fromCoordinator(turnLimits: const TurnLimitsConfig.defaults(), coordinator: executions),
      harnessFactory: defaultFactory,
      limits: const TaskExecutorLimits(defaultProviderId: 'codex'),
    );
    await createStep('default-provider', provider: null);
    await drive(const [TurnResult()], replies: const ['done']);
    expect(workerRequests.single.providerId, 'codex');
  });

  test('structured finalizer is no-tools, read-only, schema-bound and capped', () async {
    await createStep('finalizer-contract', structuredSchema: _summaryEnvelopeSchema);
    await drive(
      [
        const TurnResult(providerSessionId: 'provider-session'),
        TurnResult(providerSessionId: 'provider-session', structuredOutput: _finalizerEnvelopeOutput),
      ],
      replies: const ['Working'],
    );

    expect((await context.tasks.get('finalizer-contract'))?.status, TaskStatus.review);
    expect(harness.lastProviderSessionId, 'provider-session');
    expect(harness.lastOutputSchema, _summaryEnvelopeSchema);
    expect(harness.lastMaxTurns, 2);
    final request = workerRequests.single;
    expect(request.allowedTools, isNull);
  });

  test('missing provider session records validation failure without fabricating an envelope', () async {
    final eventDb = openTaskDbInMemory();
    addTearDown(eventDb.close);
    final eventService = TaskEventService(eventDb);
    await executor.stop();
    final factory = HarnessFactory()
      ..register(
        'claude',
        (_) => FakeAgentHarness(supportsStructuredOutput: true, supportsProviderSessionResume: true),
      );
    executor = context.buildExecutor(
      turnManager: TurnManager.fromCoordinator(turnLimits: const TurnLimitsConfig.defaults(), coordinator: executions),
      harnessFactory: factory,
      eventRecorder: TaskEventRecorder(eventService: eventService),
    );
    await createStep('missing-session', structuredSchema: _summaryEnvelopeSchema);
    await drive(const [TurnResult()], replies: const ['Working']);

    expect((await context.tasks.get('missing-session'))?.status, TaskStatus.failed);
    expect((await context.workflowStepExecutions.getByTaskId('missing-session'))?.structuredOutput, isNull);
    final failure = eventService
        .listForTask('missing-session')
        .singleWhere((event) => event.kind.name == 'structuredOutputValidationFailed');
    expect(failure.details['failureReason'], 'missing_provider_session');
  });

  test('one same-session re-ask recovers a missing envelope', () async {
    await createStep('finalizer-reask', structuredSchema: _summaryEnvelopeSchema);
    await drive(
      [
        const TurnResult(providerSessionId: 'provider-session'),
        const TurnResult(providerSessionId: 'provider-session'),
        TurnResult(providerSessionId: 'provider-session', structuredOutput: _finalizerEnvelopeOutput),
      ],
      replies: const ['Working', 'No envelope'],
    );

    expect(harness.turnCallCount, 3);
    final stored = (await context.workflowStepExecutions.getByTaskId('finalizer-reask'))?.structuredOutput;
    expect(stored?[executionEnvelopeMarkerKey], executionEnvelopeVersion);
    expect((stored?['outputs'] as Map?)?['summary'], 'final');
  });

  test('two empty finalizer turns fail with missing_envelope', () async {
    final eventDb = openTaskDbInMemory();
    addTearDown(eventDb.close);
    final eventService = TaskEventService(eventDb);
    await executor.stop();
    final factory = HarnessFactory()
      ..register(
        'claude',
        (_) => FakeAgentHarness(supportsStructuredOutput: true, supportsProviderSessionResume: true),
      );
    executor = context.buildExecutor(
      turnManager: TurnManager.fromCoordinator(turnLimits: const TurnLimitsConfig.defaults(), coordinator: executions),
      harnessFactory: factory,
      eventRecorder: TaskEventRecorder(eventService: eventService),
    );
    await createStep('missing-envelope', structuredSchema: _summaryEnvelopeSchema);
    await drive(
      const [
        TurnResult(providerSessionId: 'provider-session'),
        TurnResult(providerSessionId: 'provider-session'),
        TurnResult(providerSessionId: 'provider-session'),
      ],
      replies: const ['Working'],
    );

    expect((await context.tasks.get('missing-envelope'))?.status, TaskStatus.failed);
    final failure = eventService
        .listForTask('missing-envelope')
        .singleWhere((event) => event.kind.name == 'structuredOutputValidationFailed');
    expect(failure.details['failureReason'], 'missing_envelope');
  });

  test('malformed finalizer envelope fails closed and is not stamped', () async {
    final eventDb = openTaskDbInMemory();
    addTearDown(eventDb.close);
    final eventService = TaskEventService(eventDb);
    await executor.stop();
    final factory = HarnessFactory()
      ..register(
        'claude',
        (_) => FakeAgentHarness(supportsStructuredOutput: true, supportsProviderSessionResume: true),
      );
    executor = context.buildExecutor(
      turnManager: TurnManager.fromCoordinator(turnLimits: const TurnLimitsConfig.defaults(), coordinator: executions),
      harnessFactory: factory,
      eventRecorder: TaskEventRecorder(eventService: eventService),
    );
    await createStep('malformed-envelope', structuredSchema: _summaryEnvelopeSchema);
    await drive(
      [
        const TurnResult(providerSessionId: 'provider-session'),
        const TurnResult(
          providerSessionId: 'provider-session',
          structuredOutput: {
            'outputs': <String, dynamic>{},
            'step_outcome': {'outcome': 'succeeded', 'reason': 'ok'},
          },
        ),
      ],
      replies: const ['Working'],
    );

    expect((await context.tasks.get('malformed-envelope'))?.status, TaskStatus.failed);
    expect((await context.workflowStepExecutions.getByTaskId('malformed-envelope'))?.structuredOutput, isNull);
    final failure = eventService
        .listForTask('malformed-envelope')
        .singleWhere((event) => event.kind.name == 'structuredOutputValidationFailed');
    expect(failure.details['failureReason'], 'malformed_envelope');
  });

  // The Codex shape: the harness parses no envelope, so `structuredOutput` is
  // null and the runner reads the declared JSON object out of the reply body.
  // The extraction lived in the one-shot provider stack 0.25 deleted; without
  // it every Codex structured step reported missing_envelope.
  test('an envelope carried in the reply body is read and validated', () async {
    await createStep('body-envelope', structuredSchema: _summaryEnvelopeSchema);
    const envelope = '{"outputs":{"summary":"did the work"},"step_outcome":{"outcome":"succeeded","reason":"ok"}}';
    await drive(
      [
        const TurnResult(providerSessionId: 'provider-session'),
        const TurnResult(providerSessionId: 'provider-session'),
      ],
      replies: const ['Working', envelope],
    );

    expect((await context.tasks.get('body-envelope'))?.status, TaskStatus.review);
    final stored = (await context.workflowStepExecutions.getByTaskId('body-envelope'))?.structuredOutput;
    expect(stored, isNotNull);
    expect((stored!['outputs'] as Map)['summary'], 'did the work');
  });

  test('a reply body that is not the declared object records missing_envelope', () async {
    final eventDb = openTaskDbInMemory();
    addTearDown(eventDb.close);
    final eventService = TaskEventService(eventDb);
    await executor.stop();
    executor = context.buildExecutor(
      turnManager: TurnManager.fromCoordinator(turnLimits: const TurnLimitsConfig.defaults(), coordinator: executions),
      eventRecorder: TaskEventRecorder(eventService: eventService),
    );
    await createStep('prose-body', structuredSchema: _summaryEnvelopeSchema);
    await drive(
      [
        const TurnResult(providerSessionId: 'provider-session'),
        const TurnResult(providerSessionId: 'provider-session'),
        const TurnResult(providerSessionId: 'provider-session'),
      ],
      replies: const ['Working', 'I finished the step.', 'Still prose.'],
    );

    expect((await context.tasks.get('prose-body'))?.status, TaskStatus.failed);
    final failure = eventService
        .listForTask('prose-body')
        .singleWhere((event) => event.kind.name == 'structuredOutputValidationFailed');
    expect(failure.details['failureReason'], 'missing_envelope');
  });

  test('a reply body carrying a schema-violating object records malformed_envelope', () async {
    final eventDb = openTaskDbInMemory();
    addTearDown(eventDb.close);
    final eventService = TaskEventService(eventDb);
    await executor.stop();
    executor = context.buildExecutor(
      turnManager: TurnManager.fromCoordinator(turnLimits: const TurnLimitsConfig.defaults(), coordinator: executions),
      eventRecorder: TaskEventRecorder(eventService: eventService),
    );
    await createStep('body-malformed', structuredSchema: _summaryEnvelopeSchema);
    await drive(
      [
        const TurnResult(providerSessionId: 'provider-session'),
        const TurnResult(providerSessionId: 'provider-session'),
      ],
      replies: const ['Working', '{"outputs":{},"step_outcome":{"outcome":"succeeded","reason":"ok"}}'],
    );

    expect((await context.tasks.get('body-malformed'))?.status, TaskStatus.failed);
    final failure = eventService
        .listForTask('body-malformed')
        .singleWhere((event) => event.kind.name == 'structuredOutputValidationFailed');
    expect(failure.details['failureReason'], 'malformed_envelope');
  });

  test('worker construction receives step artifacts once and capacity is released', () async {
    final artifactsDir = '${context.tempDir.path}/step-artifacts';
    await createStep(
      'worker-boundary',
      configJson: {
        WorkflowTaskConfig.stepArtifactsEnv: {'DARTCLAW_STEP_ARTIFACTS_DIR': artifactsDir},
      },
    );
    await drive(const [TurnResult()], replies: const ['done']);

    expect(workerRequests, hasLength(1));
    expect(workerRequests.single.artifactsDir, artifactsDir);
    expect(workerRequests.single.spawnEnvironment?['DARTCLAW_STEP_ARTIFACTS_DIR'], artifactsDir);
    expect(executions.snapshot.providers['claude']?.effective, 1);
  });
}

final class _PausingUserMessageService extends MessageService {
  new({required super.baseDir});

  var _userInsertCount = 0;
  int? _pauseAt;
  Completer<void>? _paused;
  Completer<void>? _resume;

  Future<void> get paused => _paused!.future;

  void pauseOnUserInsert(int index) {
    _pauseAt = index;
    _paused = Completer<void>();
    _resume = Completer<void>();
  }

  void resume() => _resume!.complete();

  @override
  Future<Message> insertMessage({
    required String sessionId,
    required String role,
    required String content,
    String? metadata,
  }) async {
    if (role == 'user') {
      _userInsertCount++;
      if (_userInsertCount == _pauseAt) {
        _paused!.complete();
        await _resume!.future;
      }
    }
    return super.insertMessage(sessionId: sessionId, role: role, content: content, metadata: metadata);
  }
}
