// WorkflowExecutor step configuration: step config defaults (model/provider
// inheritance, first-match-wins), step timeout, and budget warning events.
@Tags(['component'])
library;

import 'dart:async';

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        StepConfigDefault,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowBudgetWarningEvent,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowStep;
import 'package:test/test.dart';

import 'workflow_executor_test_support.dart';

void main() {
  final h = WorkflowExecutorHarness();
  setUp(h.setUp);
  tearDown(h.tearDown);

  group('step config defaults', () {
    WorkflowRun makeDefaultsRun(WorkflowDefinition definition) {
      final now = DateTime.now();
      return WorkflowRun(
        id: 'run-s03',
        definitionName: definition.name,
        status: WorkflowRunStatus.running,
        startedAt: now,
        updatedAt: now,
        currentStepIndex: 0,
        definitionJson: definition.toJson(),
      );
    }

    Future<void> completeDefaultsTask(String taskId) async {
      try {
        await h.taskService.transition(taskId, TaskStatus.running, trigger: 'test');
      } on StateError {
        /* already running */
      }
      try {
        await h.taskService.transition(taskId, TaskStatus.review, trigger: 'test');
      } on StateError {
        /* may skip review */
      }
      await h.taskService.transition(taskId, TaskStatus.accepted, trigger: 'test');
    }

    test('step inherits model from matching stepDefaults', () async {
      final definition = WorkflowDefinition(
        name: 'wf',
        description: 'desc',
        steps: const [
          WorkflowStep(id: 'review-code', name: 'Review Code', prompts: ['p']),
        ],
        stepDefaults: const [StepConfigDefault(match: 'review*', model: 'claude-opus-4')],
      );

      final run = makeDefaultsRun(definition);
      await h.repository.insert(run);

      Map<String, dynamic>? capturedConfig;
      String? capturedModel;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final task = await h.taskService.get(e.taskId);
        capturedConfig = task?.configJson;
        capturedModel = task?.model;
        await completeDefaultsTask(e.taskId);
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      expect(capturedConfig, isNotNull);
      expect(capturedModel, equals('claude-opus-4'));
      expect(capturedConfig!.containsKey('model'), isFalse);
    });

    test('per-step explicit provider overrides stepDefaults provider', () async {
      final definition = WorkflowDefinition(
        name: 'wf',
        description: 'desc',
        steps: const [
          WorkflowStep(id: 'review-code', name: 'Review Code', prompts: ['p'], provider: 'explicit-provider'),
        ],
        stepDefaults: const [StepConfigDefault(match: 'review*', provider: 'default-provider')],
      );

      final run = makeDefaultsRun(definition);
      await h.repository.insert(run);

      String? capturedProvider;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final task = await h.taskService.get(e.taskId);
        capturedProvider = task?.provider;
        await completeDefaultsTask(e.taskId);
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      expect(capturedProvider, equals('explicit-provider'));
    });

    test('first-match-wins: review-code matches review* not catch-all *', () async {
      final definition = WorkflowDefinition(
        name: 'wf',
        description: 'desc',
        steps: const [
          WorkflowStep(id: 'review-code', name: 'Review Code', prompts: ['p']),
        ],
        stepDefaults: const [
          StepConfigDefault(match: 'review*', model: 'opus'),
          StepConfigDefault(match: '*', model: 'sonnet'),
        ],
      );

      final run = makeDefaultsRun(definition);
      await h.repository.insert(run);

      String? capturedModel;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final task = await h.taskService.get(e.taskId);
        capturedModel = task?.model;
        await completeDefaultsTask(e.taskId);
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      expect(capturedModel, equals('opus'));
    });

    test('no matching default: step uses own config only', () async {
      final definition = WorkflowDefinition(
        name: 'wf',
        description: 'desc',
        steps: const [
          WorkflowStep(id: 'custom-step', name: 'Custom Step', prompts: ['p']),
        ],
        stepDefaults: const [StepConfigDefault(match: 'review*', model: 'opus')],
      );

      final run = makeDefaultsRun(definition);
      await h.repository.insert(run);

      Map<String, dynamic>? capturedConfig;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final task = await h.taskService.get(e.taskId);
        capturedConfig = task?.configJson;
        await completeDefaultsTask(e.taskId);
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      expect(capturedConfig!.containsKey('model'), isFalse);
    });

    test('no stepDefaults on definition: existing behavior unchanged', () async {
      final definition = WorkflowDefinition(
        name: 'wf',
        description: 'desc',
        steps: const [
          WorkflowStep(id: 's', name: 'S', prompts: ['p']),
        ],
      );

      final run = makeDefaultsRun(definition);
      await h.repository.insert(run);

      var taskCount = 0;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        taskCount++;
        await completeDefaultsTask(e.taskId);
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      expect(taskCount, equals(1));
      final finalRun = await h.repository.getById('run-s03');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('workflow-spawned task carries no _workflow* or model keys in configJson', () async {
      final definition = WorkflowDefinition(
        name: 'wf',
        description: 'desc',
        steps: const [
          WorkflowStep(id: 'review-code', name: 'Review Code', prompts: ['p']),
        ],
        stepDefaults: const [StepConfigDefault(match: 'review*', model: 'claude-opus-4')],
      );

      final run = makeDefaultsRun(definition);
      await h.repository.insert(run);

      Map<String, dynamic>? capturedConfig;
      String? capturedAeModel;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final task = await h.taskService.get(e.taskId);
        capturedConfig = task?.configJson;
        capturedAeModel = task?.agentExecution?.model;
        await completeDefaultsTask(e.taskId);
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();

      expect(capturedConfig, isNotNull);
      expect(capturedAeModel, equals('claude-opus-4'));
      expect(capturedConfig!.containsKey('model'), isFalse);
      final leakedWorkflowKeys = capturedConfig!.keys.where((k) => k.startsWith('_workflow')).toList();
      expect(leakedWorkflowKeys, isEmpty, reason: 'Task.configJson must not carry _workflow* keys');
    });
  });

  group('step timeout', () {
    test('step timeout pauses workflow', () async {
      const timeoutSeconds = 1;
      final definition = h.makeDefinition(
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1'], timeoutSeconds: timeoutSeconds),
        ],
      );

      final run = h.makeRun(definition);
      await h.repository.insert(run);

      // Do NOT complete the task — let it time out.
      await h.executor.execute(run, definition, WorkflowContext());

      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
      expect(finalRun?.errorMessage, contains('timed out'));
    }, timeout: const Timeout(Duration(seconds: 10)));
  });

  group('budget warning', () {
    test('fires WorkflowBudgetWarningEvent at 80% of maxTokens', () async {
      final definition = h.makeDefinition(
        maxTokens: 10000,
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
        ],
      );

      var run = h.makeRun(definition);
      run = run.copyWith(totalTokens: 8000);
      await h.repository.insert(run);

      final warnings = <WorkflowBudgetWarningEvent>[];
      final warnSub = h.eventBus.on<WorkflowBudgetWarningEvent>().listen(warnings.add);

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await h.completeTask(e.taskId);
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();
      await warnSub.cancel();

      expect(warnings, hasLength(1));
      expect(warnings.first.consumed, equals(8000));
      expect(warnings.first.limit, equals(10000));
    });

    test('warning fires only once per run (deduplication)', () async {
      final definition = h.makeDefinition(
        maxTokens: 10000,
        steps: [
          const WorkflowStep(id: 'step1', name: 'Step 1', prompts: ['Do step 1']),
          const WorkflowStep(id: 'step2', name: 'Step 2', prompts: ['Do step 2']),
          const WorkflowStep(id: 'step3', name: 'Step 3', prompts: ['Do step 3']),
        ],
      );

      var run = h.makeRun(definition);
      run = run.copyWith(totalTokens: 8500);
      await h.repository.insert(run);

      final warnings = <WorkflowBudgetWarningEvent>[];
      final warnSub = h.eventBus.on<WorkflowBudgetWarningEvent>().listen(warnings.add);

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        await h.completeTask(e.taskId);
      });

      await h.executor.execute(run, definition, WorkflowContext());
      await sub.cancel();
      await warnSub.cancel();

      expect(warnings, hasLength(1));
    });
  });
}
