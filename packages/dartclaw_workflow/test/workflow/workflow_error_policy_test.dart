@Tags(['component'])
library;

import 'dart:io';
import 'dart:async';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        OnErrorPolicy,
        OnFailurePolicy,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowContext,
        WorkflowLoop,
        WorkflowStep,
        WorkflowTaskType;
import 'package:dartclaw_core/dartclaw_core.dart' show Task;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show TaskService;
import 'package:test/test.dart';

import 'workflow_executor_test_support.dart';

final class _FailingTransactor implements ExecutionRepositoryTransactor {
  @override
  Future<T> transaction<T>(FutureOr<T> Function() action) => throw StateError('injected task creation failure');
}

final class _FailingGetTaskService extends TaskService {
  new(WorkflowExecutorHarness h)
    : super(
        h.taskRepository,
        agentExecutionRepository: h.agentExecutionRepository,
        executionTransactor: h.executionRepositoryTransactor,
        eventBus: h.eventBus,
      );

  @override
  Future<Task?> get(String id) => throw StateError('injected task wait failure');
}

void main() {
  final h = WorkflowExecutorHarness();
  setUp(h.setUp);
  tearDown(h.tearDown);

  WorkflowStep bash(String id, String script, {OnErrorPolicy? onError, bool parallel = false, String? entryGate}) =>
      WorkflowStep(
        id: id,
        name: id,
        taskType: WorkflowTaskType.bash,
        prompts: [script],
        onError: onError,
        parallel: parallel,
        entryGate: entryGate,
      );

  group('execution error and modeled outcome classification', () {
    for (final source in ['create', 'wait']) {
      test('agent $source error obeys onError pause before a modeled outcome', () async {
        final definition = h.makeDefinition(
          steps: [
            const WorkflowStep(id: 'agent', name: 'Agent', prompts: ['work'], onError: OnErrorPolicy.pause),
            bash('later', 'printf later'),
          ],
        );
        final faultyService = source == 'wait' ? _FailingGetTaskService(h) : null;
        final executor = h.makeExecutor(
          executionTransactor: source == 'create' ? _FailingTransactor() : null,
          workflowTaskService: faultyService,
        );
        final run = h.makeRun(definition);
        await h.repository.insert(run);
        await executor.execute(run, definition, WorkflowContext());
        final stored = await h.repository.getById(run.id);
        expect(stored?.status, WorkflowRunStatus.paused);
        expect(
          stored?.errorMessage,
          contains(source == 'create' ? 'injected task creation failure' : 'injected task wait failure'),
        );
        expect((stored?.contextJson['data'] as Map?)?['agent.status'], 'failed');
        expect((stored?.contextJson['data'] as Map?)?['later.status'], isNull);
        await faultyService?.dispose();
      });
    }

    test('modeled failure with onError continue still obeys onFailure fail', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'agent',
            name: 'Agent',
            prompts: ['work'],
            onError: OnErrorPolicy.continueWorkflow,
            onFailure: OnFailurePolicy.fail,
          ),
          bash('later', 'printf later'),
        ],
      );
      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((event) => event.newStatus == TaskStatus.queued).listen(
        (event) async {
          await Future<void>.delayed(Duration.zero);
          await h.completeTaskWithOutcome(event.taskId, outcome: 'failed', reason: 'modeled failure');
        },
      );
      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();
      final stored = await h.repository.getById(run.id);
      expect(stored?.status, WorkflowRunStatus.failed);
      expect(stored?.errorMessage, contains('modeled failure'));
      expect((stored?.contextJson['data'] as Map?)?['later.status'], isNull);
    });

    test('modeled failure retries under onFailure despite onError continue', () async {
      final definition = h.makeDefinition(
        steps: const [
          WorkflowStep(
            id: 'agent',
            name: 'Agent',
            prompts: ['work'],
            onError: OnErrorPolicy.continueWorkflow,
            onFailure: OnFailurePolicy.retry,
            maxRetries: 1,
          ),
        ],
      );
      final run = h.makeRun(definition);
      await h.repository.insert(run);
      var attempts = 0;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((event) => event.newStatus == TaskStatus.queued).listen(
        (event) async {
          await Future<void>.delayed(Duration.zero);
          attempts++;
          await h.completeTaskWithOutcome(
            event.taskId,
            outcome: attempts == 1 ? 'failed' : 'succeeded',
            reason: attempts == 1 ? 'repair me' : '',
          );
        },
      );
      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();
      expect(attempts, 2);
      expect((await h.repository.getById(run.id))?.status, WorkflowRunStatus.completed);
    });
  });

  group('sequential and loop error policy recovery', () {
    for (final policy in [null, OnErrorPolicy.fail, OnErrorPolicy.pause, OnErrorPolicy.continueWorkflow]) {
      test('bash failure applies $policy and retains a failed step', () async {
        final definition = h.makeDefinition(
          steps: [
            bash('bad', 'exit 7', onError: policy),
            bash('independent', 'printf ok'),
            bash('dependent', 'printf no', entryGate: 'bad.status == success'),
          ],
        );
        final run = h.makeRun(definition);
        await h.repository.insert(run);
        await h.executor.execute(run, definition, WorkflowContext());
        final stored = await h.repository.getById(run.id);
        expect(
          stored?.status,
          policy == OnErrorPolicy.pause
              ? WorkflowRunStatus.paused
              : policy == OnErrorPolicy.continueWorkflow
              ? WorkflowRunStatus.completed
              : WorkflowRunStatus.failed,
        );
        final data = stored?.contextJson['data'] as Map?;
        expect(data?['bad.status'], 'failed');
        expect(
          stored?.errorMessage,
          policy == OnErrorPolicy.continueWorkflow ? isNull : contains('exited with code 7'),
        );
        expect(data?['independent.status'], policy == OnErrorPolicy.continueWorkflow ? 'success' : isNull);
        expect(data?['dependent.status'], isNot('success'));
      });
    }

    test('paused bash retries only the failed step from persisted state', () async {
      final marker = '${h.tempDir.path}/ready';
      final definition = h.makeDefinition(
        steps: [
          bash('first', 'printf first'),
          bash('retry', 'test -f "$marker"', onError: OnErrorPolicy.pause),
          bash('last', 'printf last'),
        ],
      );
      final run = h.makeRun(definition);
      await h.repository.insert(run);
      await h.executor.execute(run, definition, WorkflowContext());
      final paused = (await h.repository.getById(run.id))!;
      expect(paused.status, WorkflowRunStatus.paused);
      expect(paused.currentStepIndex, 1);
      File(marker).writeAsStringSync('ready');
      final context = WorkflowContext.fromJson(paused.contextJson);
      await h.executor.execute(paused, definition, context, startFromStepIndex: paused.currentStepIndex);
      final completed = (await h.repository.getById(run.id))!;
      expect(completed.status, WorkflowRunStatus.completed);
      final data = completed.contextJson['data'] as Map;
      expect(data['first.status'], 'success');
      expect(data['retry.status'], 'success');
      expect(data['last.status'], 'success');
    });

    test('loop pause resumes its failed body step without replaying the prior body step', () async {
      final completedPath = '${h.tempDir.path}/completed';
      final marker = '${h.tempDir.path}/ready';
      final definition = h.makeDefinition(
        steps: [
          bash('first', "printf x >> '$completedPath'"),
          bash('retry', 'test -f "$marker"', onError: OnErrorPolicy.pause),
        ],
        loops: [
          const WorkflowLoop(
            id: 'loop',
            steps: ['first', 'retry'],
            maxIterations: 1,
            exitGate: 'retry.status == success',
          ),
        ],
      );
      final run = h.makeRun(definition);
      await h.repository.insert(run);
      await h.executor.execute(run, definition, WorkflowContext());
      final paused = (await h.repository.getById(run.id))!;
      expect(paused.status, WorkflowRunStatus.paused);
      expect(File(completedPath).readAsStringSync(), 'x');
      File(marker).writeAsStringSync('ready');
      final running = paused.copyWith(status: WorkflowRunStatus.running);
      await h.repository.update(running);
      await h.executor.execute(
        running,
        definition,
        WorkflowContext.fromJson(paused.contextJson),
        startFromStepIndex: paused.currentStepIndex,
        startCursor: paused.executionCursor,
      );
      expect((await h.repository.getById(run.id))?.status, WorkflowRunStatus.completed);
      expect(File(completedPath).readAsStringSync(), 'x');
    });
  });

  group('parallel error policy recovery', () {
    test('continued error keeps failed member and skips success-gated work', () async {
      final definition = h.makeDefinition(
        steps: [
          bash('bad', 'exit 7', onError: OnErrorPolicy.continueWorkflow, parallel: true),
          bash('ok', 'printf ok', parallel: true),
          bash('dependent', 'printf no', entryGate: 'bad.status == success'),
        ],
      );
      final run = h.makeRun(definition);
      await h.repository.insert(run);
      await h.executor.execute(run, definition, WorkflowContext());
      final stored = (await h.repository.getById(run.id))!;
      expect(stored.status, WorkflowRunStatus.completed);
      final data = stored.contextJson['data'] as Map;
      expect(data['bad.status'], 'failed');
      expect(data['bad.error'], contains('exited with code 7'));
      expect(data['ok.status'], 'success');
      expect(data['dependent.status'], isNot('success'));
    });

    test('pause settles sibling and resumes only failed member', () async {
      final marker = '${h.tempDir.path}/ready';
      final definition = h.makeDefinition(
        steps: [
          bash('ok', 'printf ok', parallel: true),
          bash('retry', 'test -f "$marker"', onError: OnErrorPolicy.pause, parallel: true),
          bash('last', 'printf last'),
        ],
      );
      final run = h.makeRun(definition);
      await h.repository.insert(run);
      await h.executor.execute(run, definition, WorkflowContext());
      final paused = (await h.repository.getById(run.id))!;
      expect(paused.status, WorkflowRunStatus.paused);
      expect(paused.contextJson['_parallel.failed.stepIds'], ['retry']);
      expect((paused.contextJson['data'] as Map)['ok.status'], 'success');
      File(marker).writeAsStringSync('ready');
      final context = WorkflowContext.fromJson(paused.contextJson);
      final running = paused.copyWith(status: WorkflowRunStatus.running);
      await h.repository.update(running);
      await h.executor.execute(running, definition, context, startFromStepIndex: running.currentStepIndex);
      final completed = (await h.repository.getById(run.id))!;
      expect(completed.status, WorkflowRunStatus.completed);
      final data = completed.contextJson['data'] as Map;
      expect(data['ok.status'], 'success');
      expect(data['retry.status'], 'success');
      expect(data['last.status'], 'success');
    });
  });

  group('typed holds and stops outrank error policies', () {
    test('unavailable capped accounting stops onError and onFailure continuation', () async {
      final definition = h.makeDefinition(
        maxTokens: 100,
        steps: [
          const WorkflowStep(
            id: 'agent',
            name: 'Agent',
            prompts: ['work'],
            onError: OnErrorPolicy.continueWorkflow,
            onFailure: OnFailurePolicy.continueWorkflow,
          ),
          bash('later', 'printf later'),
        ],
      );
      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((event) => event.newStatus == TaskStatus.queued).listen(
        (event) async {
          await Future<void>.delayed(Duration.zero);
          await h.completeTaskWithOutcome(event.taskId, outcome: 'succeeded', tokenCount: null);
        },
      );
      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();
      final stored = await h.repository.getById(run.id);
      expect(stored?.status, WorkflowRunStatus.failed);
      expect(stored?.errorMessage, contains('accounting unavailable'));
      expect((stored?.contextJson['data'] as Map?)?['later.status'], isNull);
    });

    test('modeled needsInput with onError continue remains an approval hold', () async {
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'agent', name: 'Agent', prompts: ['work'], onError: OnErrorPolicy.continueWorkflow),
          bash('later', 'printf later'),
        ],
      );
      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((event) => event.newStatus == TaskStatus.queued).listen(
        (event) async {
          await Future<void>.delayed(Duration.zero);
          await h.completeTaskWithOutcome(event.taskId, outcome: 'needsInput', reason: 'operator input');
        },
      );
      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();
      final stored = await h.repository.getById(run.id);
      expect(stored?.status, WorkflowRunStatus.awaitingApproval);
      expect((stored?.contextJson['data'] as Map?)?['later.status'], isNull);
    });
  });
}
