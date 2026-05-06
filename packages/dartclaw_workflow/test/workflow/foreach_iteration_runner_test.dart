// Focused component tests for foreach iteration runner behavior.
// The existing map_step_execution_test.dart covers the full feature matrix;
// these tests are additive for fast regression localization.
@Tags(['component'])
library;

import 'dart:async';

import 'package:dartclaw_models/dartclaw_models.dart' show SessionType;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        OnFailurePolicy,
        MapIterationCompletedEvent,
        OutputConfig,
        OutputFormat,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowGitPromotionError,
        WorkflowGitIntegrationBranchResult,
        WorkflowGitPromotionSuccess,
        WorkflowGitPublishStrategy,
        WorkflowGitStrategy,
        WorkflowGitWorktreeStrategy,
        WorkflowRunStatus,
        WorkflowStepCompletedEvent,
        WorkflowStep,
        WorkflowTurnAdapter,
        WorkflowTurnOutcome;
import 'package:test/test.dart';

import 'workflow_executor_test_support.dart';

void main() {
  final h = WorkflowExecutorHarness();
  setUp(h.setUp);
  tearDown(h.tearDown);

  test('empty collection succeeds with zero tasks', () async {
    final definition = h.makeDefinition(
      steps: [
        const WorkflowStep(id: 'map-step', name: 'Map Step', prompts: ['p'], mapOver: 'items'),
      ],
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);
    final context = WorkflowContext()..['items'] = <dynamic>[];

    var taskCount = 0;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      taskCount++;
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, context);
    await sub.cancel();

    expect(taskCount, equals(0));
    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });

  test('single-item collection spawns exactly one task', () async {
    final definition = h.makeDefinition(
      steps: [
        const WorkflowStep(id: 'map-step', name: 'Map Step', prompts: ['Process {{map.item}}'], mapOver: 'items'),
      ],
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);
    final context = WorkflowContext()..['items'] = ['alpha'];

    var taskCount = 0;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      taskCount++;
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, context);
    await sub.cancel();

    expect(taskCount, equals(1));
    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });

  test('3-item collection spawns 3 tasks (sequential by default)', () async {
    final definition = h.makeDefinition(
      steps: [
        const WorkflowStep(id: 'map-step', name: 'Map Step', prompts: ['Process {{map.item}}'], mapOver: 'items'),
      ],
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);
    final context = WorkflowContext()..['items'] = ['a', 'b', 'c'];

    var taskCount = 0;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      taskCount++;
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, context);
    await sub.cancel();

    expect(taskCount, equals(3));
    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
  });

  test('null mapOver key fails the step cleanly', () async {
    final definition = h.makeDefinition(
      steps: [
        const WorkflowStep(id: 'map-step', name: 'Map Step', prompts: ['p'], mapOver: 'missing_key'),
      ],
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);
    final context = WorkflowContext(); // 'missing_key' not set

    var taskCount = 0;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      taskCount++;
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, context);
    await sub.cancel();

    expect(taskCount, equals(0));
    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
  });

  test('single-item failure fails the run', () async {
    final definition = h.makeDefinition(
      steps: [
        const WorkflowStep(id: 'map-step', name: 'Map Step', prompts: ['p'], mapOver: 'items'),
      ],
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);
    final context = WorkflowContext()..['items'] = ['only-item'];

    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      await h.completeTask(e.taskId, status: TaskStatus.failed);
    });

    await h.executor.execute(run, definition, context);
    await sub.cancel();

    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
  });

  test('continue-on-failure foreach records needsInput item and runs the next step', () async {
    final definition = WorkflowDefinition(
      name: 'resilient-foreach',
      description: 'Resilient foreach',
      steps: const [
        WorkflowStep(
          id: 'story-pipeline',
          name: 'Story Pipeline',
          type: 'foreach',
          mapOver: 'story_specs',
          foreachSteps: ['implement'],
          onFailure: OnFailurePolicy.continueWorkflow,
          outputs: {'story_results': OutputConfig(format: OutputFormat.json)},
        ),
        WorkflowStep(id: 'implement', name: 'Implement', prompts: ['implement {{map.item.id}}']),
        WorkflowStep(id: 'summarize', name: 'Summarize', prompts: ['summarize {{context.story_results}}']),
      ],
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);
    const storySpecs = {
      'items': [
        {'id': 'S01', 'title': 'Story One', 'dependencies': <String>[], 'spec_path': 'fis/s01.md'},
        {'id': 'S02', 'title': 'Story Two', 'dependencies': <String>[], 'spec_path': 'fis/s02.md'},
      ],
    };

    var implementCount = 0;
    var summarizeDispatched = false;
    final implementDisplayScopes = <Object?>[];
    final stepEvents = <WorkflowStepCompletedEvent>[];
    final stepSub = h.eventBus.on<WorkflowStepCompletedEvent>().listen(stepEvents.add);
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      final task = await h.taskService.get(e.taskId);
      if (task == null) return;
      final session = await h.sessionService.createSession(type: SessionType.task);
      await h.taskService.updateFields(e.taskId, sessionId: session.id);
      if (task.title.contains('Summarize')) {
        summarizeDispatched = true;
        await h.messageService.insertMessage(
          sessionId: session.id,
          role: 'assistant',
          content: '<step-outcome>{"outcome":"succeeded","reason":"summary written"}</step-outcome>',
        );
        await h.completeTask(e.taskId);
        return;
      }

      implementDisplayScopes.add(task.configJson['displayScope']);
      implementCount++;
      final outcome = implementCount == 1
          ? '<step-outcome>{"outcome":"needsInput","reason":"story needs human decision"}</step-outcome>'
          : '<step-outcome>{"outcome":"succeeded","reason":"story done"}</step-outcome>';
      await h.messageService.insertMessage(sessionId: session.id, role: 'assistant', content: outcome);
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, WorkflowContext(data: {'story_specs': storySpecs}));
    await sub.cancel();
    await stepSub.cancel();

    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    expect(implementCount, equals(2));
    expect(summarizeDispatched, isTrue);
    expect(implementDisplayScopes, equals(['S01', 'S02']));
    expect(
      stepEvents.where((event) => event.stepId == 'implement').map((event) => event.displayScope),
      containsAll(['S01', 'S02']),
    );
    expect(finalRun?.contextJson['data']?['step.implement[0].outcome'], equals('needsInput'));
    expect(finalRun?.contextJson['data']?['step.story-pipeline.outcome'], equals('failed'));
    final storyResults = finalRun?.contextJson['data']?['story_results'] as List<dynamic>;
    expect(storyResults[0], isA<Map<Object?, Object?>>().having((value) => value['error'], 'error', isTrue));
    expect(
      storyResults[1],
      isA<Map<Object?, Object?>>().having(
        (value) => value['implement'],
        'implement result',
        isA<Map<Object?, Object?>>(),
      ),
    );
  });

  test('foreach hard failure takes precedence over later needsInput hold', () async {
    final definition = WorkflowDefinition(
      name: 'strict-foreach',
      description: 'Strict foreach',
      steps: const [
        WorkflowStep(
          id: 'story-pipeline',
          name: 'Story Pipeline',
          type: 'foreach',
          mapOver: 'story_specs',
          foreachSteps: ['implement'],
          maxParallel: 2,
          outputs: {'story_results': OutputConfig(format: OutputFormat.json)},
        ),
        WorkflowStep(id: 'implement', name: 'Implement', prompts: ['implement {{map.item.id}}']),
      ],
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);
    const storySpecs = {
      'items': [
        {'id': 'S01', 'title': 'Story One', 'dependencies': <String>[], 'spec_path': 'fis/s01.md'},
        {'id': 'S02', 'title': 'Story Two', 'dependencies': <String>[], 'spec_path': 'fis/s02.md'},
      ],
    };

    final taskSub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      final task = await h.taskService.get(e.taskId);
      if (task == null) return;
      final session = await h.sessionService.createSession(type: SessionType.task);
      await h.taskService.updateFields(e.taskId, sessionId: session.id);
      final scope = task.configJson['displayScope'];
      if (scope == 'S02') {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await h.messageService.insertMessage(
          sessionId: session.id,
          role: 'assistant',
          content: '<step-outcome>{"outcome":"needsInput","reason":"story needs human decision"}</step-outcome>',
        );
        await h.completeTask(e.taskId);
        return;
      }
      await Future<void>.delayed(Duration.zero);
      await h.messageService.insertMessage(
        sessionId: session.id,
        role: 'assistant',
        content: '<step-outcome>{"outcome":"failed","reason":"story cannot be implemented"}</step-outcome>',
      );
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, WorkflowContext(data: {'story_specs': storySpecs}));
    await taskSub.cancel();

    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    expect(finalRun?.errorMessage, contains("Foreach step 'story-pipeline': 2 iteration(s) failed"));
    expect(finalRun?.contextJson['data']?['_approval.pending.stepId'], isNull);
  });

  test('continue-on-failure foreach still fails controller preflight errors', () async {
    final definition = WorkflowDefinition(
      name: 'resilient-foreach',
      description: 'Resilient foreach',
      steps: const [
        WorkflowStep(
          id: 'story-pipeline',
          name: 'Story Pipeline',
          type: 'foreach',
          mapOver: 'missing_story_specs',
          foreachSteps: ['implement'],
          onFailure: OnFailurePolicy.continueWorkflow,
          outputs: {'story_results': OutputConfig(format: OutputFormat.json)},
        ),
        WorkflowStep(id: 'implement', name: 'Implement', prompts: ['implement {{map.item.id}}']),
        WorkflowStep(id: 'summarize', name: 'Summarize', prompts: ['summarize {{context.story_results}}']),
      ],
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);

    var taskCount = 0;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      taskCount++;
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, WorkflowContext());
    await sub.cancel();

    final finalRun = await h.repository.getById('run-1');
    expect(taskCount, equals(0));
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
  });

  test('continue-on-failure foreach still fails unexpected controller errors', () async {
    final definition = WorkflowDefinition(
      name: 'resilient-promotion-aware-foreach',
      description: 'Resilient promotion-aware foreach',
      project: '{{PROJECT}}',
      gitStrategy: const WorkflowGitStrategy(
        integrationBranch: true,
        worktree: WorkflowGitWorktreeStrategy(mode: 'per-map-item'),
        promotion: 'merge',
        publish: WorkflowGitPublishStrategy(enabled: false),
      ),
      steps: const [
        WorkflowStep(
          id: 'story-pipeline',
          name: 'Story Pipeline',
          type: 'foreach',
          mapOver: 'story_specs',
          foreachSteps: ['implement'],
          maxParallel: 1,
          onFailure: OnFailurePolicy.continueWorkflow,
          outputs: {'story_results': OutputConfig(format: OutputFormat.json)},
        ),
        WorkflowStep(id: 'implement', name: 'Implement', prompts: ['implement {{map.item.id}}']),
        WorkflowStep(id: 'summarize', name: 'Summarize', prompts: ['summarize {{context.story_results}}']),
      ],
    );
    final run = h.makeRun(definition).copyWith(variablesJson: const {'PROJECT': 'my-project', 'BRANCH': 'main'});
    await h.repository.insert(run);
    const storySpecs = {
      'items': [
        {'id': 'S01', 'title': 'Story One', 'dependencies': <String>[], 'spec_path': 'fis/s01.md'},
        {'id': 'S02', 'title': 'Story Two', 'dependencies': <String>[], 'spec_path': 'fis/s02.md'},
      ],
    };
    final runtimeExecutor = h.makeExecutor(
      outputTransformer: (run, definition, step, task, outputs) {
        final result = Map<String, dynamic>.from(outputs);
        if (step.id == 'implement') {
          result['implement.branch'] = 'story-branch-${task.id}';
        }
        return result;
      },
      turnAdapter: WorkflowTurnAdapter(
        reserveTurn: (_) => Future.value('turn-1'),
        executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
        waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
        initializeWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async =>
            const WorkflowGitIntegrationBranchResult(integrationBranch: 'dartclaw/integration/test'),
        promoteWorkflowBranch:
            ({
              required runId,
              required projectId,
              required branch,
              required integrationBranch,
              required strategy,
              String? storyId,
            }) async => throw StateError('promotion callback exploded'),
      ),
    );

    var summarizeDispatched = false;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      final task = await h.taskService.get(e.taskId);
      if (task == null) return;
      if (task.title.contains('Summarize')) {
        summarizeDispatched = true;
      }
      final session = await h.sessionService.createSession(type: SessionType.task);
      await h.taskService.updateFields(e.taskId, sessionId: session.id);
      await h.messageService.insertMessage(
        sessionId: session.id,
        role: 'assistant',
        content: '<step-outcome>{"outcome":"succeeded","reason":"story done"}</step-outcome>',
      );
      await h.completeTask(e.taskId);
    });

    await runtimeExecutor.execute(
      run,
      definition,
      WorkflowContext(data: {'story_specs': storySpecs}, variables: const {'PROJECT': 'my-project', 'BRANCH': 'main'}),
    );
    await sub.cancel();

    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    expect(finalRun?.errorMessage, startsWith('foreach-controller-failure:'));
    expect(summarizeDispatched, isFalse);
    final storyResults = finalRun?.contextJson['data']?['story_results'] as List<dynamic>;
    expect(storyResults, hasLength(2));
    expect(storyResults.every((slot) => slot != null), isTrue);
  });

  test('continue-on-failure foreach still fails promotion result errors', () async {
    final definition = WorkflowDefinition(
      name: 'resilient-promotion-aware-foreach',
      description: 'Resilient promotion-aware foreach',
      project: '{{PROJECT}}',
      gitStrategy: const WorkflowGitStrategy(
        integrationBranch: true,
        worktree: WorkflowGitWorktreeStrategy(mode: 'per-map-item'),
        promotion: 'merge',
        publish: WorkflowGitPublishStrategy(enabled: false),
      ),
      steps: const [
        WorkflowStep(
          id: 'story-pipeline',
          name: 'Story Pipeline',
          type: 'foreach',
          mapOver: 'story_specs',
          foreachSteps: ['implement'],
          maxParallel: 1,
          onFailure: OnFailurePolicy.continueWorkflow,
          outputs: {'story_results': OutputConfig(format: OutputFormat.json)},
        ),
        WorkflowStep(id: 'implement', name: 'Implement', prompts: ['implement {{map.item.id}}']),
        WorkflowStep(id: 'summarize', name: 'Summarize', prompts: ['summarize {{context.story_results}}']),
      ],
    );
    final run = h.makeRun(definition).copyWith(variablesJson: const {'PROJECT': 'my-project', 'BRANCH': 'main'});
    await h.repository.insert(run);
    const storySpecs = {
      'items': [
        {'id': 'S01', 'title': 'Story One', 'dependencies': <String>[], 'spec_path': 'fis/s01.md'},
      ],
    };
    final runtimeExecutor = h.makeExecutor(
      outputTransformer: (run, definition, step, task, outputs) {
        final result = Map<String, dynamic>.from(outputs);
        if (step.id == 'implement') {
          result['implement.branch'] = 'story-branch-${task.id}';
        }
        return result;
      },
      turnAdapter: WorkflowTurnAdapter(
        reserveTurn: (_) => Future.value('turn-1'),
        executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
        waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
        initializeWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async =>
            const WorkflowGitIntegrationBranchResult(integrationBranch: 'dartclaw/integration/test'),
        promoteWorkflowBranch:
            ({
              required runId,
              required projectId,
              required branch,
              required integrationBranch,
              required strategy,
              String? storyId,
            }) async => const WorkflowGitPromotionError('remote rejected promotion'),
      ),
    );

    var summarizeDispatched = false;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      final task = await h.taskService.get(e.taskId);
      if (task == null) return;
      if (task.title.contains('Summarize')) {
        summarizeDispatched = true;
      }
      final session = await h.sessionService.createSession(type: SessionType.task);
      await h.taskService.updateFields(e.taskId, sessionId: session.id);
      await h.messageService.insertMessage(
        sessionId: session.id,
        role: 'assistant',
        content: '<step-outcome>{"outcome":"succeeded","reason":"story done"}</step-outcome>',
      );
      await h.completeTask(e.taskId);
    });

    await runtimeExecutor.execute(
      run,
      definition,
      WorkflowContext(data: {'story_specs': storySpecs}, variables: const {'PROJECT': 'my-project', 'BRANCH': 'main'}),
    );
    await sub.cancel();

    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    expect(finalRun?.errorMessage, startsWith('promotion-failure:'));
    expect(summarizeDispatched, isFalse);
  });

  test('budget-exhausted foreach cancellation fails controller and emits iteration events', () async {
    final definition = WorkflowDefinition(
      name: 'budgeted-foreach',
      description: 'Budgeted foreach',
      maxTokens: 1,
      steps: const [
        WorkflowStep(
          id: 'story-pipeline',
          name: 'Story Pipeline',
          type: 'foreach',
          mapOver: 'story_specs',
          foreachSteps: ['implement'],
          maxParallel: 1,
          onFailure: OnFailurePolicy.continueWorkflow,
          outputs: {'story_results': OutputConfig(format: OutputFormat.json)},
        ),
        WorkflowStep(id: 'implement', name: 'Implement', prompts: ['implement {{map.item.id}}']),
        WorkflowStep(id: 'summarize', name: 'Summarize', prompts: ['summarize {{context.story_results}}']),
      ],
    );
    final run = h.makeRun(definition);
    await h.repository.insert(run);
    const storySpecs = {
      'items': [
        {'id': 'S01', 'title': 'Story One', 'dependencies': <String>[], 'spec_path': 'fis/s01.md'},
        {'id': 'S02', 'title': 'Story Two', 'dependencies': <String>[], 'spec_path': 'fis/s02.md'},
      ],
    };

    final iterationEvents = <MapIterationCompletedEvent>[];
    final iterSub = h.eventBus.on<MapIterationCompletedEvent>().listen(iterationEvents.add);
    final taskSub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      final task = await h.taskService.get(e.taskId);
      if (task == null) return;
      final session = await h.sessionService.createSession(type: SessionType.task);
      await h.taskService.updateFields(e.taskId, sessionId: session.id);
      await h.messageService.insertMessage(
        sessionId: session.id,
        role: 'assistant',
        content: '<step-outcome>{"outcome":"succeeded","reason":"story done"}</step-outcome>',
      );
      final currentRun = await h.repository.getById('run-1');
      await h.repository.update(currentRun!.copyWith(totalTokens: 1));
      await h.completeTask(e.taskId);
    });

    await h.executor.execute(run, definition, WorkflowContext(data: {'story_specs': storySpecs}));
    await taskSub.cancel();
    await iterSub.cancel();

    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    expect(finalRun?.errorMessage, startsWith('foreach-controller-failure:'));
    expect(
      iterationEvents,
      contains(
        isA<MapIterationCompletedEvent>()
            .having((event) => event.itemId, 'itemId', 'S02')
            .having((event) => event.success, 'success', isFalse)
            .having((event) => event.taskId, 'taskId', isEmpty),
      ),
    );
  });

  test('dependency-cancelled foreach items emit iteration completion events', () async {
    final definition = WorkflowDefinition(
      name: 'resilient-promotion-aware-foreach',
      description: 'Resilient promotion-aware foreach',
      project: '{{PROJECT}}',
      gitStrategy: const WorkflowGitStrategy(
        integrationBranch: true,
        worktree: WorkflowGitWorktreeStrategy(mode: 'per-map-item'),
        promotion: 'merge',
        publish: WorkflowGitPublishStrategy(enabled: false),
      ),
      steps: const [
        WorkflowStep(
          id: 'story-pipeline',
          name: 'Story Pipeline',
          type: 'foreach',
          mapOver: 'story_specs',
          foreachSteps: ['implement'],
          maxParallel: 2,
          onFailure: OnFailurePolicy.continueWorkflow,
          outputs: {'story_results': OutputConfig(format: OutputFormat.json)},
        ),
        WorkflowStep(id: 'implement', name: 'Implement', prompts: ['implement {{map.item.id}}']),
        WorkflowStep(id: 'summarize', name: 'Summarize', prompts: ['summarize {{context.story_results}}']),
      ],
    );
    final run = h.makeRun(definition).copyWith(variablesJson: const {'PROJECT': 'my-project', 'BRANCH': 'main'});
    await h.repository.insert(run);
    const storySpecs = {
      'items': [
        {'id': 'S01', 'title': 'Story One', 'dependencies': <String>[], 'spec_path': 'fis/s01.md'},
        {
          'id': 'S02',
          'title': 'Story Two',
          'dependencies': <String>['S01'],
          'spec_path': 'fis/s02.md',
        },
      ],
    };
    final runtimeExecutor = h.makeExecutor(
      turnAdapter: WorkflowTurnAdapter(
        reserveTurn: (_) => Future.value('turn-1'),
        executeTurn: (sessionId, turnId, messages, {required source, required resume}) {},
        waitForOutcome: (sessionId, turnId) async => const WorkflowTurnOutcome(status: 'completed'),
        initializeWorkflowGit: ({required runId, required projectId, required baseRef, required perMapItem}) async =>
            const WorkflowGitIntegrationBranchResult(integrationBranch: 'dartclaw/integration/test'),
        promoteWorkflowBranch:
            ({
              required runId,
              required projectId,
              required branch,
              required integrationBranch,
              required strategy,
              String? storyId,
            }) async => const WorkflowGitPromotionSuccess(commitSha: 'abc123'),
      ),
    );

    final iterationEvents = <MapIterationCompletedEvent>[];
    final iterSub = h.eventBus.on<MapIterationCompletedEvent>().listen(iterationEvents.add);
    final taskSub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      final task = await h.taskService.get(e.taskId);
      if (task == null) return;
      final session = await h.sessionService.createSession(type: SessionType.task);
      await h.taskService.updateFields(e.taskId, sessionId: session.id);
      if (task.title.contains('Summarize')) {
        await h.messageService.insertMessage(
          sessionId: session.id,
          role: 'assistant',
          content: '<step-outcome>{"outcome":"succeeded","reason":"summary written"}</step-outcome>',
        );
        await h.completeTask(e.taskId);
        return;
      }
      await h.messageService.insertMessage(
        sessionId: session.id,
        role: 'assistant',
        content: '<step-outcome>{"outcome":"needsInput","reason":"story needs human decision"}</step-outcome>',
      );
      await h.completeTask(e.taskId);
    });

    await runtimeExecutor.execute(
      run,
      definition,
      WorkflowContext(data: {'story_specs': storySpecs}, variables: const {'PROJECT': 'my-project', 'BRANCH': 'main'}),
    );
    await taskSub.cancel();
    await iterSub.cancel();

    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    expect(
      iterationEvents,
      contains(
        isA<MapIterationCompletedEvent>()
            .having((event) => event.itemId, 'itemId', 'S02')
            .having((event) => event.success, 'success', isFalse)
            .having((event) => event.taskId, 'taskId', isEmpty)
            .having((event) => event.tokenCount, 'tokenCount', 0),
      ),
    );
    final storyResults = finalRun?.contextJson['data']?['story_results'] as List<dynamic>;
    expect(storyResults[1], isA<Map<Object?, Object?>>().having((value) => value['error'], 'error', isTrue));
    expect(
      storyResults[1],
      isA<Map<Object?, Object?>>().having((value) => value['message'], 'message', contains('dependency failed')),
    );
  });
}
