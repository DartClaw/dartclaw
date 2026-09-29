import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show SessionType, WorkflowRunStatus;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show TaskService;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        ContextExtractor,
        DatabaseWorkflowRunRepository,
        GateEvaluator,
        OnErrorPolicy,
        OnFailurePolicy,
        StepExecutionContext,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowExecutor,
        WorkflowRun,
        WorkflowStep,
        WorkflowTaskType,
        executionEnvelopeMarkerKey,
        executionEnvelopeOutputsKey,
        executionEnvelopeStepOutcomeKey,
        executionEnvelopeVersion;
import 'package:test/test.dart';

import 'workflow_executor_test_support.dart';

void main() {
  for (final failurePolicy in [OnFailurePolicy.continueWorkflow, OnFailurePolicy.retry]) {
    test('incomplete current-turn receipt stops capped dispatch and retry despite $failurePolicy', () async {
      final h = WorkflowExecutorHarness();
      await h.setUp();
      addTearDown(h.tearDown);
      final definition = h.makeDefinition(
        maxTokens: 100,
        steps: [
          WorkflowStep(
            id: 'work',
            name: 'Work',
            prompts: const ['work'],
            onError: OnErrorPolicy.continueWorkflow,
            onFailure: failurePolicy,
            maxRetries: failurePolicy == OnFailurePolicy.retry ? 1 : 0,
          ),
          const WorkflowStep(id: 'independent', name: 'Independent', prompts: ['later']),
        ],
      );
      final run = h.makeRun(definition);
      await h.repository.insert(run);
      var dispatches = 0;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((event) => event.newStatus == TaskStatus.queued).listen(
        (event) async {
          await pumpEventQueue();
          dispatches++;
          final session = await h.sessionService.createSession(type: SessionType.task);
          await h.taskService.updateFields(event.taskId, sessionId: session.id);
          await h.kvService.set(
            'session_cost:${session.id}',
            jsonEncode({'total_tokens': 100, 'token_usage_complete': true, 'last_accounted_turn_id': 'T1'}),
          );
          final execution = (await h.workflowStepExecutionRepository.getByTaskId(event.taskId))!;
          await h.workflowStepExecutionRepository.update(
            execution.copyWith(
              stepTokenBreakdownJson: jsonEncode({
                'inputTokensNew': 0,
                'cacheReadTokens': 0,
                'outputTokens': 30,
                'turnId': 'T2',
                'tokenUsageComplete': false,
              }),
            ),
          );
          await h.seedStepOutcome(event.taskId, outcome: 'succeeded');
          await h.completeTask(event.taskId);
        },
      );
      addTearDown(sub.cancel);

      await h.executor.execute(run, definition, WorkflowContext());
      final stopped = (await h.repository.getById(run.id))!;
      expect(stopped.status, WorkflowRunStatus.failed);
      expect(stopped.errorMessage, contains('accounting unavailable'));
      expect((stopped.contextJson['data'] as Map)['work.tokenCount'], isNull);
      expect((stopped.contextJson['data'] as Map)['independent.status'], isNull);
      expect(dispatches, 1);

      final retry = stopped.copyWith(status: WorkflowRunStatus.running);
      await h.repository.update(retry);
      await h.executor.execute(retry, definition, WorkflowContext.fromJson(retry.contextJson));
      final stillStopped = (await h.repository.getById(run.id))!;
      expect(stillStopped.status, WorkflowRunStatus.failed);
      expect(stillStopped.errorMessage, contains('accounting unavailable'));
      expect(dispatches, 1, reason: 'a stale T1 ledger cannot authorize another provider turn');
    });
  }

  test('read-fault retry counts settled work once while an error pause retries only its failed unit', () async {
    final h = WorkflowExecutorHarness();
    await h.setUp();
    final oldKv = h.kvService;
    final faultingKv = FaultOnceSessionKvService(filePath: oldKv.filePath);
    h.kvService = faultingKv;
    h.executor = h.makeExecutor();
    await oldKv.dispose();
    addTearDown(h.tearDown);
    final marker = '${h.tempDir.path}/ready';
    final settledPath = '${h.tempDir.path}/settled';
    final definition = h.makeDefinition(
      maxTokens: 100,
      steps: [
        const WorkflowStep(id: 'measured', name: 'Measured', prompts: ['work']),
        WorkflowStep(
          id: 'settled',
          name: 'Settled',
          taskType: WorkflowTaskType.bash,
          prompts: ["printf x >> '$settledPath'"],
        ),
        WorkflowStep(
          id: 'retry',
          name: 'Retry',
          taskType: WorkflowTaskType.bash,
          prompts: ['test -f "$marker"'],
          onError: OnErrorPolicy.pause,
        ),
      ],
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);
    var dispatches = 0;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((event) => event.newStatus == TaskStatus.queued).listen((
      event,
    ) async {
      await pumpEventQueue();
      dispatches++;
      await h.completeTaskWithOutcome(event.taskId, outcome: 'succeeded', tokenCount: 9);
      faultingKv.failNextSessionRead = true;
    });
    addTearDown(sub.cancel);

    await h.executor.execute(run, definition, WorkflowContext());
    final stopped = (await h.repository.getById(run.id))!;
    expect(stopped.status, WorkflowRunStatus.failed);
    expect(dispatches, 1);
    expect(stopped.contextJson['_accounting.pendingTaskId'], isNotNull);

    final retryAccounting = stopped.copyWith(status: WorkflowRunStatus.running);
    await h.repository.update(retryAccounting);
    await h.executor.execute(retryAccounting, definition, WorkflowContext.fromJson(retryAccounting.contextJson));
    final paused = (await h.repository.getById(run.id))!;
    expect(paused.status, WorkflowRunStatus.paused);
    expect(paused.totalTokens, 9);
    expect(File(settledPath).readAsStringSync(), 'x');
    expect(dispatches, 1);

    File(marker).writeAsStringSync('ready');
    final resume = paused.copyWith(status: WorkflowRunStatus.running);
    await h.repository.update(resume);
    await h.executor.execute(
      resume,
      definition,
      WorkflowContext.fromJson(resume.contextJson),
      startFromStepIndex: resume.currentStepIndex,
      startCursor: resume.executionCursor,
    );
    final completed = (await h.repository.getById(run.id))!;
    expect(completed.status, WorkflowRunStatus.completed, reason: completed.errorMessage);
    expect(completed.totalTokens, 9);
    expect(File(settledPath).readAsStringSync(), 'x');
    expect(dispatches, 1);
  });

  test('modeled failure still obeys onFailure after onError continue', () async {
    final h = WorkflowExecutorHarness();
    await h.setUp();
    addTearDown(h.tearDown);
    final definition = h.makeDefinition(
      steps: const [
        WorkflowStep(
          id: 'modeled',
          name: 'Modeled',
          prompts: ['work'],
          onError: OnErrorPolicy.continueWorkflow,
          onFailure: OnFailurePolicy.fail,
        ),
        WorkflowStep(id: 'later', name: 'Later', prompts: ['later']),
      ],
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);
    var dispatches = 0;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((event) => event.newStatus == TaskStatus.queued).listen((
      event,
    ) async {
      await pumpEventQueue();
      dispatches++;
      await h.completeTaskWithOutcome(event.taskId, outcome: 'failed', reason: 'model rejected', tokenCount: 3);
    });
    addTearDown(sub.cancel);
    await h.executor.execute(run, definition, WorkflowContext());
    final failed = (await h.repository.getById(run.id))!;
    expect(failed.status, WorkflowRunStatus.failed);
    expect(failed.errorMessage, contains('model rejected'));
    expect((failed.contextJson['data'] as Map)['later.status'], isNull);
    expect(dispatches, 1);
  });

  test('PostgreSQL restart rechecks pending accounting and preserves settled work through pause and resume', () async {
    final dsn = Platform.environment['DARTCLAW_TEST_POSTGRES_URL']!;
    final temp = Directory.systemTemp.createTempSync('harness_corrections_pg_');
    addTearDown(() async {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final settledPath = '${temp.path}/settled';
    final readyPath = '${temp.path}/ready';
    final definition = WorkflowDefinition(
      name: 'recovery',
      description: 'Keep settled work across accounting and error recovery',
      maxTokens: 100,
      steps: [
        WorkflowStep(
          id: 'settled',
          name: 'Settled',
          taskType: WorkflowTaskType.bash,
          prompts: ["printf x >> '$settledPath'"],
        ),
        const WorkflowStep(id: 'measured', name: 'Measured', prompts: ['work']),
        WorkflowStep(
          id: 'retry',
          name: 'Retry',
          taskType: WorkflowTaskType.bash,
          prompts: ['test -f "$readyPath"'],
          onError: OnErrorPolicy.pause,
        ),
      ],
    );

    var h = await _PersistedWorkflowHarness.open(dsn, temp);
    String? settledTaskId;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((event) => event.newStatus == TaskStatus.queued).listen((
      event,
    ) async {
      await pumpEventQueue();
      settledTaskId = event.taskId;
      final session = await h.sessions.createSession(type: SessionType.task);
      await h.tasks.updateFields(event.taskId, sessionId: session.id);
      await h.kv.set(
        'session_cost:${session.id}',
        jsonEncode({'total_tokens': 9, 'token_usage_complete': true, 'last_accounted_turn_id': 'T1'}),
      );
      final execution = (await h.stepExecutions.getByTaskId(event.taskId))!;
      await h.stepExecutions.update(
        execution.copyWith(
          stepTokenBreakdownJson: jsonEncode({
            'inputTokensNew': 9,
            'cacheReadTokens': 0,
            'outputTokens': 0,
            'turnId': 'T1',
            'tokenUsageComplete': true,
          }),
          structuredOutputJson: jsonEncode({
            executionEnvelopeOutputsKey: <String, dynamic>{},
            executionEnvelopeStepOutcomeKey: {'outcome': 'succeeded', 'reason': ''},
            executionEnvelopeMarkerKey: executionEnvelopeVersion,
          }),
        ),
      );
      h.kv.failNextSessionRead = true;
      await h.tasks.transition(event.taskId, TaskStatus.running, trigger: 'test');
      await h.tasks.transition(event.taskId, TaskStatus.review, trigger: 'test');
      await h.tasks.transition(event.taskId, TaskStatus.accepted, trigger: 'test');
    });
    final now = DateTime.now();
    final run = WorkflowRun(
      id: 'persisted-recovery',
      definitionName: definition.name,
      status: WorkflowRunStatus.running,
      startedAt: now,
      updatedAt: now,
      definitionJson: definition.toJson(),
    );
    await h.runs.insert(run);
    await h.executor.execute(run, definition, WorkflowContext());
    await sub.cancel();
    final stopped = (await h.runs.getById(run.id))!;
    expect(stopped.status, WorkflowRunStatus.failed);
    expect(stopped.contextJson['_accounting.pendingTaskId'], settledTaskId);
    expect(File(settledPath).readAsStringSync(), 'x');
    await h.close();

    h = await _PersistedWorkflowHarness.open(dsn, temp);
    final stored = (await h.runs.getById(run.id))!;
    expect(stored.status, WorkflowRunStatus.failed);
    final retry = stored.copyWith(status: WorkflowRunStatus.running);
    await h.runs.update(retry);
    await h.executor.execute(retry, definition, WorkflowContext.fromJson(retry.contextJson));
    final paused = (await h.runs.getById(run.id))!;
    expect(paused.status, WorkflowRunStatus.paused);
    expect(paused.totalTokens, 9);
    expect(paused.tokenUsageComplete, isTrue);
    expect(File(settledPath).readAsStringSync(), 'x');
    expect((await h.tasks.list()).map((task) => task.id), contains(settledTaskId));
    await h.close();

    File(readyPath).writeAsStringSync('ready');
    h = await _PersistedWorkflowHarness.open(dsn, temp);
    addTearDown(h.close);
    final storedPause = (await h.runs.getById(run.id))!;
    expect(storedPause.status, WorkflowRunStatus.paused);
    final resume = storedPause.copyWith(status: WorkflowRunStatus.running);
    await h.runs.update(resume);
    await h.executor.execute(
      resume,
      definition,
      WorkflowContext.fromJson(resume.contextJson),
      startFromStepIndex: resume.currentStepIndex,
      startCursor: resume.executionCursor,
    );
    final completed = (await h.runs.getById(run.id))!;
    expect(completed.status, WorkflowRunStatus.completed, reason: completed.errorMessage);
    expect(completed.totalTokens, 9);
    expect(File(settledPath).readAsStringSync(), 'x');
    expect((await h.tasks.list()).where((task) => task.id == settledTaskId), hasLength(1));
  }, skip: Platform.environment['DARTCLAW_TEST_POSTGRES_URL'] == null ? 'requires disposable PostgreSQL URL' : false);
}

final class _FaultingPersistedKv extends KvService {
  new({required super.filePath});

  bool failNextSessionRead = false;

  @override
  Future<String?> get(String key) {
    if (key.startsWith('session_cost:') && failNextSessionRead) {
      failNextSessionRead = false;
      throw StateError('injected KV read failure');
    }
    return super.get(key);
  }
}

final class _PersistedWorkflowHarness {
  new({
    required this.backend,
    required this.eventBus,
    required this.tasks,
    required this.messages,
    required this.sessions,
    required this.kv,
    required this.runs,
    required this.stepExecutions,
    required this.executor,
  });

  final PostgresBackend backend;
  final EventBus eventBus;
  final TaskService tasks;
  final MessageService messages;
  final SessionService sessions;
  final _FaultingPersistedKv kv;
  final DatabaseWorkflowRunRepository runs;
  final DatabaseWorkflowStepExecutionRepository stepExecutions;
  final WorkflowExecutor executor;

  static Future<_PersistedWorkflowHarness> open(String dsn, Directory temp) async {
    final backend = await PostgresBackend.open(dsn: dsn, poolSize: 3);
    await PostgresSchemaGate.prepare(backend, databaseIdentity: backend.databaseIdentity);
    final eventBus = EventBus();
    final taskRepository = DatabaseTaskRepository(backend);
    final agentExecutions = DatabaseAgentExecutionRepository(backend, eventBus: eventBus);
    final stepExecutions = DatabaseWorkflowStepExecutionRepository(backend);
    final transactor = DatabaseExecutionRepositoryTransactor(backend);
    final tasks = TaskService(
      taskRepository,
      agentExecutionRepository: agentExecutions,
      executionTransactor: transactor,
      eventBus: eventBus,
    );
    final messages = MessageService(baseDir: '${temp.path}/sessions');
    final sessions = SessionService(baseDir: '${temp.path}/sessions');
    final kv = _FaultingPersistedKv(filePath: '${temp.path}/kv.json');
    final runs = DatabaseWorkflowRunRepository(backend);
    final executor = WorkflowExecutor(
      executionContext: StepExecutionContext(
        taskService: tasks,
        eventBus: eventBus,
        kvService: kv,
        repository: runs,
        gateEvaluator: GateEvaluator(),
        contextExtractor: ContextExtractor(
          taskService: tasks,
          messageService: messages,
          dataDir: temp.path,
          workflowStepExecutionRepository: stepExecutions,
        ),
        taskRepository: taskRepository,
        agentExecutionRepository: agentExecutions,
        workflowStepExecutionRepository: stepExecutions,
        executionTransactor: transactor,
      ),
      dataDir: temp.path,
    );
    return _PersistedWorkflowHarness(
      backend: backend,
      eventBus: eventBus,
      tasks: tasks,
      messages: messages,
      sessions: sessions,
      kv: kv,
      runs: runs,
      stepExecutions: stepExecutions,
      executor: executor,
    );
  }

  Future<void> close() async {
    await tasks.dispose();
    await messages.dispose();
    await kv.dispose();
    await eventBus.dispose();
    await backend.close();
  }
}
