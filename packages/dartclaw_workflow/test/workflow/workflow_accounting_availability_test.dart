import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_workflow/src/workflow/workflow_budget_monitor.dart' show readSessionTokens, readStepTokenCount;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowContext, WorkflowStep, OnFailurePolicy;
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show WorkflowRunStatus;
import 'package:test/test.dart';

import 'workflow_executor_test_support.dart';
import 'foreach_iteration_runner_test_support.dart';

void main() {
  group('session readings and continuation baseline', () {
    late Directory directory;
    late KvService kv;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('workflow_accounting_');
      kv = KvService(filePath: '${directory.path}/kv.json');
    });

    tearDown(() async {
      await kv.dispose();
      await directory.delete(recursive: true);
    });

    test('a complete current ledger preserves a measured zero', () async {
      await kv.set(
        'session_cost:zero',
        jsonEncode({'total_tokens': 0, 'token_usage_complete': true, 'last_accounted_turn_id': 'turn-1'}),
      );

      expect(await readSessionTokens(kv, 'zero'), 0);
    });

    test('missing, malformed, incomplete, and stale ledgers are unavailable', () async {
      await kv.set('session_cost:malformed', '{');
      await kv.set('session_cost:negative', jsonEncode({'total_tokens': -1, 'token_usage_complete': true}));
      await kv.set('session_cost:fractional', jsonEncode({'total_tokens': 1.5, 'token_usage_complete': true}));
      await kv.set('session_cost:incomplete', jsonEncode({'total_tokens': 9, 'token_usage_complete': false}));
      await kv.set(
        'session_cost:stale',
        jsonEncode({
          'total_tokens': 9,
          'token_usage_complete': true,
          'pending_accounting_turn_id': 'turn-2',
          'last_accounted_turn_id': 'turn-1',
        }),
      );

      for (final id in ['missing', 'malformed', 'negative', 'fractional', 'incomplete', 'stale']) {
        expect(await readSessionTokens(kv, id), isNull, reason: '$id ledger is not a trustworthy measurement');
      }
    });
  });

  test('capped accounting stop and retry verifies settled task without redispatch', () async {
    final h = WorkflowExecutorHarness();
    await h.setUp();
    final oldKv = h.kvService;
    final faultingKv = FaultOnceSessionKvService(filePath: oldKv.filePath);
    h.kvService = faultingKv;
    h.executor = h.makeExecutor();
    await oldKv.dispose();
    addTearDown(h.tearDown);

    final definition = h.makeDefinition(
      maxTokens: 100,
      steps: const [
        WorkflowStep(id: 'first', name: 'First', prompts: ['first']),
        WorkflowStep(id: 'next', name: 'Next', prompts: ['next']),
      ],
    );
    final run = await h.insertRun(definition);
    var dispatchCount = 0;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((event) => event.newStatus == TaskStatus.queued).listen((
      event,
    ) async {
      await Future<void>.delayed(Duration.zero);
      dispatchCount++;
      await h.completeTaskWithOutcome(event.taskId, outcome: 'succeeded', tokenCount: 9);
      if (dispatchCount == 1) faultingKv.failNextSessionRead = true;
    });
    addTearDown(sub.cancel);

    await h.executor.execute(run, definition, WorkflowContext());
    final stopped = (await h.repository.getById(run.id))!;
    expect(stopped.status, WorkflowRunStatus.failed);
    expect(stopped.totalTokens, 0, reason: 'a read fault leaves the settled contribution pending');
    expect(stopped.contextJson['_accounting.pendingTaskId'], isNotNull);
    expect(dispatchCount, 1);

    final retry = stopped.copyWith(status: WorkflowRunStatus.running);
    await h.repository.update(retry);
    await h.executor.execute(retry, definition, WorkflowContext.fromJson(retry.contextJson));
    final completed = (await h.repository.getById(run.id))!;
    expect(dispatchCount, 2, reason: 'retry dispatches only the previously unstarted next step');
    expect(completed.totalTokens, 18);
    expect(completed.tokenUsageComplete, isTrue);
  });

  test('capped retry preserves measured earlier attempt before a later read fault', () async {
    final h = WorkflowExecutorHarness();
    await h.setUp();
    final oldKv = h.kvService;
    final faultingKv = FaultOnceSessionKvService(filePath: oldKv.filePath);
    h.kvService = faultingKv;
    h.executor = h.makeExecutor();
    await oldKv.dispose();
    addTearDown(h.tearDown);

    final definition = h.makeDefinition(
      maxTokens: 100,
      steps: const [
        WorkflowStep(id: 'work', name: 'Work', prompts: ['work'], onFailure: OnFailurePolicy.retry, maxRetries: 1),
        WorkflowStep(id: 'next', name: 'Next', prompts: ['next']),
      ],
    );
    final run = await h.insertRun(definition);
    var dispatchCount = 0;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((event) => event.newStatus == TaskStatus.queued).listen((
      event,
    ) async {
      await Future<void>.delayed(Duration.zero);
      dispatchCount++;
      await h.completeTaskWithOutcome(
        event.taskId,
        outcome: dispatchCount == 1 ? 'failed' : 'succeeded',
        tokenCount: dispatchCount == 1 ? 7 : (dispatchCount == 2 ? 9 : 5),
      );
      if (dispatchCount == 2) faultingKv.failNextSessionRead = true;
    });
    addTearDown(sub.cancel);

    await h.executor.execute(run, definition, WorkflowContext());
    final stopped = (await h.repository.getById(run.id))!;
    expect(dispatchCount, 2);
    expect(stopped.status, WorkflowRunStatus.failed);
    expect(stopped.totalTokens, 7);

    final retry = stopped.copyWith(status: WorkflowRunStatus.running);
    await h.repository.update(retry);
    await h.executor.execute(retry, definition, WorkflowContext.fromJson(retry.contextJson));
    final completed = (await h.repository.getById(run.id))!;
    expect(dispatchCount, 3, reason: 'both settled attempts are accounted without redispatch');
    expect(completed.totalTokens, 21);
    expect(completed.tokenUsageComplete, isTrue);
  });

  test('completed turn receipt freshness rejects stale ledger and sticky earlier gap', () async {
    final h = WorkflowExecutorHarness();
    await h.setUp();
    addTearDown(h.tearDown);
    final definition = h.makeDefinition(
      steps: const [
        WorkflowStep(id: 'work', name: 'Work', prompts: ['work']),
      ],
    );
    final run = await h.insertRun(definition);
    String? taskId;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((event) => event.newStatus == TaskStatus.queued).listen((
      event,
    ) async {
      await Future<void>.delayed(Duration.zero);
      taskId = event.taskId;
      await h.completeTaskWithOutcome(event.taskId, outcome: 'succeeded', tokenCount: 13);
    });
    addTearDown(sub.cancel);
    await h.executor.execute(run, definition, WorkflowContext());
    final task = (await h.taskService.get(taskId!))!;
    final repo = h.workflowStepExecutionRepository;
    expect((await readStepTokenCount(task, h.kvService, repo)).complete, isTrue);

    await h.kvService.set(
      'session_cost:${task.sessionId}',
      jsonEncode({'total_tokens': 13, 'token_usage_complete': true, 'last_accounted_turn_id': 'older'}),
    );
    final stale = await readStepTokenCount(task, h.kvService, repo);
    expect(stale.knownTokens, 13);
    expect(stale.complete, isFalse);

    await h.seedTaskUsage(task.id, task.sessionId!, 13);
    final execution = (await repo.getByTaskId(task.id))!;
    await repo.update(
      execution.copyWith(
        stepTokenBreakdownJson: jsonEncode({...execution.stepTokenBreakdown!, 'tokenUsageComplete': false}),
      ),
    );
    expect((await readStepTokenCount(task, h.kvService, repo)).complete, isFalse);
  });

  test('uncapped lower bound and retry attempts preserve missing spend after later measured turns', () async {
    final h = WorkflowExecutorHarness();
    await h.setUp();
    addTearDown(h.tearDown);
    final definition = h.makeDefinition(
      steps: const [
        WorkflowStep(id: 'work', name: 'Work', prompts: ['work'], onFailure: OnFailurePolicy.retry, maxRetries: 1),
        WorkflowStep(id: 'later', name: 'Later', prompts: ['later']),
      ],
    );
    final run = await h.insertRun(definition);
    var attempt = 0;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((event) => event.newStatus == TaskStatus.queued).listen((
      event,
    ) async {
      await Future<void>.delayed(Duration.zero);
      attempt++;
      if (attempt == 1) {
        await h.completeTaskWithOutcome(event.taskId, outcome: 'failed', tokenCount: null);
      } else {
        await h.completeTaskWithOutcome(event.taskId, outcome: 'succeeded', tokenCount: attempt == 2 ? 8 : 4);
      }
    });
    addTearDown(sub.cancel);
    await h.executor.execute(run, definition, WorkflowContext());
    final stored = (await h.repository.getById(run.id))!;
    final reloaded = stored.copyWith();
    final data = reloaded.contextJson['data'] as Map<String, dynamic>;
    expect(attempt, 3);
    expect(reloaded.totalTokens, 12);
    expect(reloaded.tokenUsageComplete, isFalse);
    expect(data['work.tokenCount'], isNull);
    expect(data['later.tokenCount'], 4);
  });
}
