import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_runtime/src/turn_manager.dart' show TurnManager;
import 'package:dartclaw_runtime/src/turn_runner.dart' show TurnRunner;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' as wf;
import 'package:test/test.dart';

import '../task/task_executor_test_support.dart';

final class _OneFailedLedgerWrite extends KvService {
  new({required super.filePath}) {
    _backend = KvService(filePath: filePath);
  }

  late KvService _backend;

  int writes = 0;
  int? failAt;

  @override
  Future<String?> get(String key) => _backend.get(key);

  @override
  Future<void> set(String key, String value) {
    if (key.startsWith('session_cost:') && ++writes == failAt) {
      throw StateError('injected final accounting failure');
    }
    return _backend.set(key, value);
  }

  Future<void> reopen() async {
    await _backend.dispose();
    _backend = KvService(filePath: filePath);
  }

  @override
  Future<void> dispose() async {
    await _backend.dispose();
    await super.dispose();
  }
}

void main() {
  test(
    'a failed T2 ledger write stays incomplete through file-backed reopen and never charges catch-up to T3',
    () async {
      final harness = FakeAgentHarness(supportsProviderSessionResume: true);
      final context = WorkflowTaskExecutorTestContext(harness);
      await context.setUp();
      final kvPath = context.kvService.filePath;
      await context.kvService.dispose();
      final kv = _OneFailedLedgerWrite(filePath: kvPath);
      context.kvService = kv;
      final primary = context.turns.executions.primary!;
      final workerEntered = Completer<void>();
      final releaseWorker = Completer<void>();
      final coordinator = ExecutionCoordinator(
        providerCapacities: const {'claude': 1},
        primary: primary,
        admitExecution: (request) => primary.admitTurn(request.sessionId, isHumanInput: request.isHumanInput),
        releaseAdmission: primary.releaseAdmission,
        createWorker: (request) async {
          if (!workerEntered.isCompleted) {
            workerEntered.complete();
            await releaseWorker.future;
          }
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
      final executor = context.buildExecutor(
        turnManager: TurnManager.fromCoordinator(
          turnLimits: const TurnLimitsConfig.defaults(),
          coordinator: coordinator,
        ),
      );
      context.executor = executor;
      addTearDown(() async {
        await executor.stop();
        await coordinator.dispose();
        await context.tearDown();
      });
      await context.tasks.create(
        id: 'accounting-gap',
        title: 'Workflow step',
        description: 'Continue after a failed ledger write',
        autoStart: true,
        agentExecutionId: 'ae-accounting-gap',
        workflowRunId: 'wf-accounting-gap',
        provider: 'claude',
        configJson: const {'needsWorktree': false},
      );
      await context.seedWorkflowExecution(
        'accounting-gap',
        workflowRunId: 'wf-accounting-gap',
        followUpPrompts: const ['T3', 'T4'],
        providerSessionId: 'native-1',
      );

      final poll = executor.pollOnce();
      await workerEntered.future;
      final task = (await context.tasks.get('accounting-gap'))!;
      final sessionId = task.sessionId!;
      final mainSession = await context.sessions.createSession(type: SessionType.main);
      await kv.set(
        'session_cost:${mainSession.id}',
        jsonEncode({'total_tokens': 7, 'input_tokens': 7, 'token_usage_complete': true}),
      );
      final mainBefore = await kv.get('session_cost:${mainSession.id}');
      await kv.set(
        'session_cost:$sessionId',
        jsonEncode({
          'output_tokens': 100,
          'total_tokens': 100,
          'turn_count': 1,
          'token_usage_complete': true,
          'last_accounted_turn_id': 'T1',
          'claude_native_snapshot': ClaudeUsageSnapshot(
            nativeSessionId: 'native-1',
            models: {
              'root': const ClaudeModelUsage(input: 0, output: 80, cacheRead: 0, cacheWrite: 0),
              'delegate': const ClaudeModelUsage(input: 0, output: 20, cacheRead: 0, cacheWrite: 0),
            },
            totalCostUsd: 0.1,
          ).toJson(),
        }),
      );
      kv.failAt = kv.writes + 2;
      releaseWorker.complete();
      await poll;

      TurnResult snapshot(int root, int delegated, int turnOutput) => TurnResult(
        providerSessionId: 'native-1',
        outputTokens: turnOutput,
        claudeUsageSnapshot: ClaudeUsageSnapshot(
          nativeSessionId: 'native-1',
          models: {
            'root': ClaudeModelUsage(input: 0, output: root, cacheRead: 0, cacheWrite: 0),
            'delegate': ClaudeModelUsage(input: 0, output: delegated, cacheRead: 0, cacheWrite: 0),
          },
          totalCostUsd: (root + delegated) / 1000,
        ),
      );

      await harness.turnInvoked;
      harness.completeSuccess(snapshot(100, 30, 20));
      await harness.turnInvoked;
      final afterT2 = (await context.workflowStepExecutions.getByTaskId('accounting-gap'))!.stepTokenBreakdown!;
      expect(afterT2['outputTokens'], 30);
      expect(afterT2['tokenUsageComplete'], isFalse);
      expect(afterT2['turnId'], isNotNull);
      final staleLedger = jsonDecode((await kv.get('session_cost:$sessionId'))!) as Map;
      expect(staleLedger['output_tokens'], 100);
      expect(staleLedger['last_accounted_turn_id'], 'T1');
      expect(staleLedger['pending_accounting_turn_id'], isNotNull);
      expect(staleLedger['pending_accounting_turn_id'], isNot(afterT2['turnId']));
      expect(await kv.get('session_cost:${mainSession.id}'), mainBefore);

      await kv.reopen();
      expect(jsonDecode((await kv.get('session_cost:$sessionId'))!)['output_tokens'], 100);

      final definition = wf.WorkflowDefinition(
        name: 'capped-correction',
        description: 'Check current accounting before another unit',
        maxTokens: 200,
        steps: const [
          wf.WorkflowStep(
            id: 'work',
            name: 'Work',
            prompts: ['work'],
            onError: wf.OnErrorPolicy.continueWorkflow,
            onFailure: wf.OnFailurePolicy.continueWorkflow,
          ),
          wf.WorkflowStep(id: 'independent', name: 'Independent', prompts: ['later']),
        ],
      );
      final seededRun = (await context.workflowRuns.getById('wf-accounting-gap'))!;
      final run = seededRun.copyWith(
        definitionName: definition.name,
        definitionJson: definition.toJson(),
        currentStepIndex: 1,
        contextJson: const {
          '_accounting.pendingTaskId': 'accounting-gap',
          '_accounting.pendingStepId': 'work',
          '_accounting.pendingTaskSucceeded': true,
        },
      );
      await context.workflowRuns.update(run);
      final workflowExecutor = wf.WorkflowExecutor(
        executionContext: wf.StepExecutionContext(
          taskService: context.tasks,
          eventBus: EventBus(),
          kvService: kv,
          repository: context.workflowRuns,
          gateEvaluator: wf.GateEvaluator(),
          contextExtractor: wf.ContextExtractor(
            taskService: context.tasks,
            messageService: context.messages,
            dataDir: context.tempDir.path,
            workflowStepExecutionRepository: context.workflowStepExecutions,
          ),
          workflowStepExecutionRepository: context.workflowStepExecutions,
        ),
        dataDir: context.tempDir.path,
      );
      await workflowExecutor.execute(run, definition, wf.WorkflowContext.fromJson(run.contextJson));
      final stoppedRun = (await context.workflowRuns.getById(run.id))!;
      expect(stoppedRun.status, WorkflowRunStatus.failed);
      expect(stoppedRun.errorMessage, contains('accounting unavailable'));
      expect((stoppedRun.contextJson['data'] as Map)['work.tokenCount'], isNull);
      expect((stoppedRun.contextJson['data'] as Map)['independent.status'], isNull);
      final retryRun = stoppedRun.copyWith(status: WorkflowRunStatus.running);
      await context.workflowRuns.update(retryRun);
      await workflowExecutor.execute(retryRun, definition, wf.WorkflowContext.fromJson(retryRun.contextJson));
      expect((await context.workflowRuns.getById(run.id))!.status, WorkflowRunStatus.failed);
      expect(harness.turnCallCount, 2, reason: 'policy continuation cannot launch independent work');

      harness.completeSuccess(snapshot(125, 45, 25));
      await harness.turnInvoked;
      final afterT3 = (await context.workflowStepExecutions.getByTaskId('accounting-gap'))!.stepTokenBreakdown!;
      final ledgerT3 = jsonDecode((await kv.get('session_cost:$sessionId'))!) as Map;
      expect(afterT3['outputTokens'], 55);
      expect(afterT3['tokenUsageComplete'], isFalse);
      expect(ledgerT3['output_tokens'], 125);
      expect(ledgerT3['token_usage_complete'], isFalse);
      harness.completeSuccess(snapshot(135, 45, 10));
      await executor.drain();
      final finalReceipt = (await context.workflowStepExecutions.getByTaskId('accounting-gap'))!.stepTokenBreakdown!;
      final finalLedger = jsonDecode((await kv.get('session_cost:$sessionId'))!) as Map;
      expect(finalReceipt['outputTokens'], 65);
      expect(finalReceipt['tokenUsageComplete'], isFalse);
      expect(finalLedger['output_tokens'], 135);
      expect(finalLedger['token_usage_complete'], isFalse);
      expect(harness.turnCallCount, 3);
      await context.tasks.transition('accounting-gap', TaskStatus.accepted, trigger: 'test');

      await context.tasks.create(
        id: 'pending-marker-fault',
        title: 'Next workflow step',
        description: 'Must not reach the provider',
        autoStart: true,
        agentExecutionId: 'ae-pending-marker-fault',
        workflowRunId: 'wf-pending-marker-fault',
        provider: 'claude',
        configJson: const {'needsWorktree': false},
      );
      await context.seedWorkflowExecution('pending-marker-fault', workflowRunId: 'wf-pending-marker-fault');
      kv.failAt = kv.writes + 1;
      await executor.pollOnce();
      await executor.drain();
      expect((await context.tasks.get('pending-marker-fault'))?.status, TaskStatus.failed);
      expect(harness.turnCallCount, 3, reason: 'a failed pending marker must refuse provider dispatch');
    },
  );
}
