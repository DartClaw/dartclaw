@Tags(['component'])
library;

import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowGitWorktreeMode, WorkflowTaskType;

import 'package:dartclaw_models/dartclaw_models.dart' show SessionType;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        MapIterationCompletedEvent,
        MapStepCompletedEvent,
        OutputConfig,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowDefinitionParser,
        WorkflowExecutionCursor,
        WorkflowGitPromotionConflict,
        WorkflowGitPromotionError,
        WorkflowGitPromotionSuccess,
        WorkflowGitPublishStrategy,
        WorkflowGitStrategy,
        WorkflowGitWorktreeStrategy,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowStepCompletedEvent,
        WorkflowStep;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'foreach_iteration_runner_test_support.dart';
import 'workflow_executor_test_support.dart';

void main() {
  final h = WorkflowExecutorHarness();
  setUp(h.setUp);
  tearDown(h.tearDown);

  for (final row in [
    (
      name: 'empty collection succeeds with zero tasks',
      definition: () => h.mapStepDefinition(prompt: 'p'),
      context: () => h.itemsContext(<dynamic>[]),
      completionStatus: TaskStatus.accepted,
      expectedTasks: 0,
      expectedRunStatus: WorkflowRunStatus.completed,
    ),
    (
      name: 'single-item collection spawns exactly one task',
      definition: h.mapStepDefinition,
      context: () => h.itemsContext(['alpha']),
      completionStatus: TaskStatus.accepted,
      expectedTasks: 1,
      expectedRunStatus: WorkflowRunStatus.completed,
    ),
    (
      name: '3-item collection spawns 3 tasks (sequential by default)',
      definition: h.mapStepDefinition,
      context: () => h.itemsContext(['a', 'b', 'c']),
      completionStatus: TaskStatus.accepted,
      expectedTasks: 3,
      expectedRunStatus: WorkflowRunStatus.completed,
    ),
    (
      name: 'null mapOver key fails the step cleanly',
      definition: () => h.mapStepDefinition(prompt: 'p', mapOver: 'missing_key'),
      context: WorkflowContext.new,
      completionStatus: TaskStatus.accepted,
      expectedTasks: 0,
      expectedRunStatus: WorkflowRunStatus.failed,
    ),
    (
      name: 'single-item failure fails the run',
      definition: () => h.mapStepDefinition(prompt: 'p'),
      context: () => h.itemsContext(['only-item']),
      completionStatus: TaskStatus.failed,
      expectedTasks: 1,
      expectedRunStatus: WorkflowRunStatus.failed,
    ),
  ]) {
    test(row.name, () async {
      final result = await h.executeCountingQueuedTasks(
        row.definition(),
        row.context(),
        completionStatus: row.completionStatus,
      );
      expect(result.taskCount, equals(row.expectedTasks));
      expect(result.finalRun?.status, equals(row.expectedRunStatus));
    });
  }

  for (final row in [
    (
      name: 'S03 foreach inner step retries completed-task failed outcome exactly once with maxRetries 1',
      completer: (String taskId, int taskCount) => h.completeTaskWithOutcome(
        taskId,
        outcomeContent: taskCount == 1
            ? '<step-outcome>{"outcome":"failed","reason":"missing artifact"}</step-outcome>'
            : '<step-outcome>{"outcome":"succeeded","reason":"artifact found"}</step-outcome>',
      ),
      expectedRunStatus: WorkflowRunStatus.completed,
      expectedError: null,
    ),
    (
      name: 'S03 foreach inner step retries terminal task failure exactly once with maxRetries 1',
      completer: (String taskId, int taskCount) => taskCount == 1
          ? h.completeTask(taskId, status: TaskStatus.failed)
          : h.completeTaskWithOutcome(
              taskId,
              outcomeContent: '<step-outcome>{"outcome":"succeeded","reason":"task recovered"}</step-outcome>',
            ),
      expectedRunStatus: WorkflowRunStatus.completed,
      expectedError: null,
    ),
    (
      name: 'S03 foreach inner step exhausts persistent terminal task failures after N plus 1 attempts',
      completer: (String taskId, int _) => h.completeTask(taskId, status: TaskStatus.failed),
      expectedRunStatus: WorkflowRunStatus.failed,
      expectedError: "Foreach step 'controller'",
    ),
  ]) {
    test(row.name, () async {
      final result = await h.executeQueuedTasks(
        h.foreachRetryDefinition(),
        h.itemsContext(['alpha']),
        completer: row.completer,
      );
      expect(result.taskCount, equals(2));
      expect(result.finalRun?.status, equals(row.expectedRunStatus));
      if (row.expectedError case final expectedError?) {
        expect(result.finalRun?.errorMessage, contains(expectedError));
      }
    });
  }

  test('continue-on-failure foreach records needsInput item and runs the next step', () async {
    final definition = h.storyPipelineDefinition();
    final run = await h.insertRun(definition);

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

    await h.executor.execute(run, definition, h.storySpecsContext(twoStorySpecs));
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
    final definition = h.storyPipelineDefinition(
      name: 'strict-foreach',
      description: 'Strict foreach',
      maxParallel: 2,
      onFailure: null,
      includeSummarize: false,
    );
    final run = await h.insertRun(definition);

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

    await h.executor.execute(run, definition, h.storySpecsContext(twoStorySpecs));
    await taskSub.cancel();

    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    expect(finalRun?.errorMessage, contains("Foreach step 'story-pipeline': 2 iteration(s) failed"));
    expect(finalRun?.contextJson['data']?['_approval.pending.stepId'], isNull);
  });

  test('continue-on-failure foreach still fails controller preflight errors', () async {
    final definition = h.storyPipelineDefinition(mapOver: 'missing_story_specs');
    final result = await h.executeCountingQueuedTasks(definition, WorkflowContext());
    expect(result.taskCount, equals(0));
    expect(result.finalRun?.status, equals(WorkflowRunStatus.failed));
  });

  test('continue-on-failure foreach still fails unexpected controller errors', () async {
    final definition = h.storyPipelineDefinition(
      name: 'resilient-promotion-aware-foreach',
      description: 'Resilient promotion-aware foreach',
      maxParallel: 1,
      promotionAware: true,
    );
    final run = h.makeRun(definition).copyWith(variablesJson: const {'PROJECT': 'my-project', 'BRANCH': 'main'});
    await h.repository.insert(run);
    final runtimeExecutor = h.makeExecutor(
      outputTransformer: (run, definition, step, task, outputs) {
        final result = Map<String, dynamic>.from(outputs);
        if (step.id == 'implement') {
          result['implement.branch'] = 'story-branch-${task.id}';
        }
        return result;
      },
      turnAdapter: standardTurnAdapter(
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
      h.storySpecsContext(twoStorySpecs, variables: const {'PROJECT': 'my-project', 'BRANCH': 'main'}),
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
    final definition = h.storyPipelineDefinition(
      name: 'resilient-promotion-aware-foreach',
      description: 'Resilient promotion-aware foreach',
      maxParallel: 1,
      promotionAware: true,
    );
    final run = h.makeRun(definition).copyWith(variablesJson: const {'PROJECT': 'my-project', 'BRANCH': 'main'});
    await h.repository.insert(run);
    final runtimeExecutor = h.makeExecutor(
      outputTransformer: (run, definition, step, task, outputs) {
        final result = Map<String, dynamic>.from(outputs);
        if (step.id == 'implement') {
          result['implement.branch'] = 'story-branch-${task.id}';
        }
        return result;
      },
      turnAdapter: standardTurnAdapter(
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
      h.storySpecsContext(oneStorySpecs, variables: const {'PROJECT': 'my-project', 'BRANCH': 'main'}),
    );
    await sub.cancel();

    final finalRun = await h.repository.getById('run-1');
    expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    expect(finalRun?.errorMessage, startsWith('promotion-failure:'));
    expect(summarizeDispatched, isFalse);
  });

  test('budget-exhausted foreach cancellation fails controller and emits iteration events', () async {
    final definition = h.storyPipelineDefinition(
      name: 'budgeted-foreach',
      description: 'Budgeted foreach',
      maxTokens: 1,
      maxParallel: 1,
    );
    final run = await h.insertRun(definition);

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

    await h.executor.execute(run, definition, h.storySpecsContext(twoStorySpecs));
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

  test('budget exhausted by an earlier child stops the remaining children of the same item', () async {
    const yaml = r'''
name: two-child-foreach
description: per-item pair of children
steps:
  - id: pair
    name: Pair
    type: foreach
    map_over: items
    outputs: { results: { format: json } }
    steps:
      - id: first
        name: First Child
        prompt: a
      - id: second
        name: Second Child
        prompt: b
''';
    final def = WorkflowDefinitionParser().parse(yaml).copyWith(maxTokens: 100);
    final run = h.makeRun(def);
    await h.repository.insert(run);
    final context = WorkflowContext()..['items'] = ['A'];

    var firstCount = 0;
    var secondCount = 0;
    final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      final t = await h.taskService.get(e.taskId);
      if (t!.title.contains('First Child')) {
        firstCount++;
        await h.completeTaskWithOutcome(
          e.taskId,
          outcomeContent: '<step-outcome>{"outcome":"succeeded","reason":"done"}</step-outcome>',
          tokenCount: 150,
        );
      } else {
        secondCount++;
        await h.completeTask(e.taskId);
      }
    });

    await h.executor.execute(run, def, context);
    await sub.cancel();

    final finalRun = await h.repository.getById(run.id);
    expect(firstCount, 1);
    expect(secondCount, 0, reason: 'second child must not dispatch once the first spent the budget');
    expect(finalRun?.status, WorkflowRunStatus.failed);
    expect(finalRun?.errorMessage, contains('budget exhausted'));
    expect(finalRun?.totalTokens, 150, reason: 'consumed tokens reach the run exactly once via the completion sum');
  });

  test('dependency-cancelled foreach items emit iteration completion events', () async {
    final definition = h.storyPipelineDefinition(
      name: 'resilient-promotion-aware-foreach',
      description: 'Resilient promotion-aware foreach',
      maxParallel: 2,
      promotionAware: true,
    );
    final run = h.makeRun(definition).copyWith(variablesJson: const {'PROJECT': 'my-project', 'BRANCH': 'main'});
    await h.repository.insert(run);
    final runtimeExecutor = h.makeExecutor(turnAdapter: standardTurnAdapter());

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
      h.storySpecsContext(dependentStorySpecs, variables: const {'PROJECT': 'my-project', 'BRANCH': 'main'}),
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

  group('foreach execution', () {
    test('dependency-aware foreach duplicate ids fail before dispatch', () async {
      final definition = WorkflowDefinition(
        name: 'foreach-duplicate-id',
        description: 'Duplicate dependency-aware ids',
        steps: const [
          WorkflowStep(
            id: 'fe',
            name: 'FE',
            type: WorkflowTaskType.foreach,
            mapOver: 'stories',
            foreachSteps: ['child'],
            outputs: {'results': OutputConfig()},
          ),
          WorkflowStep(id: 'child', name: 'Child', type: WorkflowTaskType.agent, prompts: ['Do {{map.item.id}}']),
        ],
      );

      final run = await h.insertRun(definition);
      final context = WorkflowContext()
        ..['stories'] = [
          {'id': 'S01', 'dependencies': <String>[]},
          {'id': 'S01', 'dependencies': <String>[]},
        ];

      await h.executor.execute(run, definition, context);

      final updatedRun = await h.repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.failed));
      expect(updatedRun?.errorMessage, contains('duplicate id `S01`'));
      final tasks = await h.taskService.list();
      expect(
        tasks.where((task) => task.workflowRunId == run.id),
        isEmpty,
        reason: 'Validation should fail before dispatch',
      );
    });

    test('end-to-end: `as:` on inline `type: foreach` parses and reaches child prompts', () async {
      final definition = WorkflowDefinitionParser().parse(inlineForeachAsYaml);

      final controller = definition.steps.firstWhere((s) => s.id == 'story-pipeline');
      expect(controller.mapAlias, 'story', reason: 'Parser must propagate `as:` on inline foreach');

      final descriptions = await h.executeAndCaptureDescriptions(
        definition,
        WorkflowContext()..['stories'] = aliasStoryCollection,
      );

      expect(descriptions, hasLength(2));
      expect(descriptions[0], contains('Story 1/2: implement docs/s01.md'));
      expect(descriptions[1], contains('Story 2/2: implement docs/s02.md'));
    });

    test('foreach with `as:` resolves aliased refs in child prompts', () async {
      final descriptions = await h.executeAndCaptureDescriptions(
        h.aliasedForeachDefinition(),
        WorkflowContext()..['stories'] = aliasStoryCollection,
      );

      expect(descriptions, hasLength(2));
      expect(descriptions[0], contains('Story 1/2: implement docs/s01.md'));
      expect(descriptions[1], contains('Story 2/2: implement docs/s02.md'));
    });

    test('plain mapOver step with `as:` substitutes in the controller prompt', () async {
      final descriptions = await h.executeAndCaptureDescriptions(
        h.aliasedMapDefinition(),
        WorkflowContext()..['items'] = mapAliasCollection,
      );

      expect(descriptions, hasLength(2));
      expect(descriptions[0], contains('Process item 0: first'));
      expect(descriptions[1], contains('Process item 1: second'));
    });

    test('foreach iterates items and runs child steps sequentially per item', () async {
      final collection = [
        {'id': 'S01', 'title': 'Story 1'},
        {'id': 'S02', 'title': 'Story 2'},
        {'id': 'S03', 'title': 'Story 3'},
      ];
      final definition = h.sequentialChildDefinition();

      final run = await h.insertRun(definition);
      final context = WorkflowContext()..['stories'] = collection;

      var taskCount = 0;
      final taskTitles = <String>[];
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        taskCount++;
        final task = await h.taskService.get(e.taskId);
        if (task != null) taskTitles.add(task.title);
        await Future<void>.delayed(Duration.zero);
        await h.completeTask(e.taskId);
      });

      await h.executor.execute(run, definition, context, startFromStepIndex: 1);
      await sub.cancel();

      expect(taskCount, 6);
      expect(taskTitles.length, 6);

      final updatedRun = await h.repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('dependency-aware foreach waits for prerequisite completion before dispatch', () async {
      final definition = WorkflowDefinition(
        name: 'foreach-dependency-ordering',
        description: 'Dependency-aware foreach ordering',
        steps: const [
          WorkflowStep(
            id: 'story-pipeline',
            name: 'Story Pipeline',
            type: WorkflowTaskType.foreach,
            mapOver: 'stories',
            foreachSteps: ['implement'],
            maxParallel: 2,
            outputs: {'story_results': OutputConfig()},
          ),
          WorkflowStep(
            id: 'implement',
            name: 'Implement',
            type: WorkflowTaskType.agent,
            prompts: ['Build {{map.item.id}}'],
          ),
        ],
      );

      final run = await h.insertRun(definition);
      final context = WorkflowContext()
        ..['stories'] = [
          {'id': 'S01', 'dependencies': <String>[]},
          {
            'id': 'S02',
            'dependencies': <String>['S01'],
          },
        ];

      final taskIds = <String>[];
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        taskIds.add(e.taskId);
      });

      final executorFuture = h.executor.execute(run, definition, context);

      await Future.doWhile(() async {
        await Future<void>.delayed(Duration.zero);
        return taskIds.isEmpty;
      });

      expect(taskIds, hasLength(1), reason: 'Dependent foreach item must stay blocked until S01 settles');

      await h.completeTask(taskIds.first);
      await Future.doWhile(() async {
        await Future<void>.delayed(Duration.zero);
        return taskIds.length < 2;
      });
      await sub.cancel();

      await h.completeTask(taskIds.last);
      await executorFuture;

      expect(taskIds, hasLength(2));
      final updatedRun = await h.repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('promotion-aware foreach keeps dependents blocked until prerequisite is promoted', () async {
      final definition = WorkflowDefinition(
        name: 'promotion-aware-foreach',
        description: 'Promotion-aware dependency gating',
        project: '{{PROJECT}}',
        gitStrategy: const WorkflowGitStrategy(
          integrationBranch: true,
          worktree: WorkflowGitWorktreeStrategy(mode: WorkflowGitWorktreeMode.perMapItem),
          promotion: 'merge',
          publish: WorkflowGitPublishStrategy(enabled: false),
        ),
        steps: const [
          WorkflowStep(
            id: 'story-pipeline',
            name: 'Story Pipeline',
            type: WorkflowTaskType.foreach,
            mapOver: 'stories',
            foreachSteps: ['implement'],
            maxParallel: 2,
            outputs: {'story_results': OutputConfig()},
          ),
          WorkflowStep(id: 'implement', name: 'Implement', prompts: ['Implement {{map.item.id}}']),
        ],
      );

      final run = WorkflowRun(
        id: 'run-promotion-aware-foreach',
        definitionName: definition.name,
        status: WorkflowRunStatus.running,
        startedAt: DateTime.now(),
        updatedAt: DateTime.now(),
        variablesJson: const {'PROJECT': 'my-project', 'BRANCH': 'main'},
        definitionJson: definition.toJson(),
      );
      await h.repository.insert(run);

      final stories = [
        {'id': 'S01', 'dependencies': <String>[]},
        {
          'id': 'S02',
          'dependencies': <String>['S01'],
        },
      ];
      final firstContext = WorkflowContext(
        data: {'stories': stories},
        variables: const {'PROJECT': 'my-project', 'BRANCH': 'main'},
      );

      final conflictExecutor = h.makeExecutor(
        turnAdapter: standardTurnAdapter(
          promoteWorkflowBranch:
              ({
                required runId,
                required projectId,
                required branch,
                required integrationBranch,
                required strategy,
                String? storyId,
              }) async => const WorkflowGitPromotionConflict(conflictingFiles: ['lib/foo.dart'], details: 'conflict'),
        ),
      );

      final firstRunTaskIds = <String>[];
      final firstSub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        firstRunTaskIds.add(e.taskId);
        final task = await h.taskService.get(e.taskId);
        if (task != null) {
          await h.taskService.updateFields(
            task.id,
            worktreeJson: {
              'path': p.join(h.tempDir.path, 'worktrees', task.id),
              'branch': 'story-s01',
              'createdAt': DateTime.now().toIso8601String(),
            },
          );
        }
        await Future<void>.delayed(Duration.zero);
        await h.completeTask(e.taskId);
      });

      await conflictExecutor.execute(run, definition, firstContext);
      await firstSub.cancel();

      expect(firstRunTaskIds, hasLength(1), reason: 'Dependent story must remain undispatched during conflict');

      final conflictedRun = await h.repository.getById(run.id);
      expect(conflictedRun?.status, equals(WorkflowRunStatus.failed));
      expect(conflictedRun?.executionCursor, isNotNull);
      final conflictedSlot = conflictedRun?.executionCursor?.resultSlots.first as Map<Object?, Object?>?;
      expect(conflictedSlot?['message'], contains('promotion-conflict'));
      expect(
        conflictedRun?.executionCursor?.cancelledIndices,
        isEmpty,
        reason: 'Pending dependents must remain resumable',
      );

      final resumedExecutor = h.makeExecutor(
        turnAdapter: standardTurnAdapter(
          turnId: 'turn-2',
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

      final resumedContext = WorkflowContext(
        data: {'stories': stories},
        variables: const {'PROJECT': 'my-project', 'BRANCH': 'main'},
      );
      final retryingRun = conflictedRun!.copyWith(
        status: WorkflowRunStatus.running,
        errorMessage: null,
        completedAt: null,
        updatedAt: DateTime.now(),
      );
      await h.repository.update(retryingRun);
      final resumedTaskIds = <String>[];
      final resumedSub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        resumedTaskIds.add(e.taskId);
        final task = await h.taskService.get(e.taskId);
        if (task != null) {
          final branch = resumedTaskIds.length == 1 ? 'story-s01-retry' : 'story-s02';
          await h.taskService.updateFields(
            task.id,
            worktreeJson: {
              'path': p.join(h.tempDir.path, 'worktrees', task.id),
              'branch': branch,
              'createdAt': DateTime.now().toIso8601String(),
            },
          );
        }
        await Future<void>.delayed(Duration.zero);
        await h.completeTask(e.taskId);
      });

      await resumedExecutor.execute(retryingRun, definition, resumedContext, startCursor: retryingRun.executionCursor);
      await resumedSub.cancel();

      expect(resumedTaskIds, hasLength(2), reason: 'Resume should retry S01, promote it, then dispatch dependent S02');
      final updatedRun = await h.repository.getById(run.id);
      expect(updatedRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('foreach with empty collection succeeds with empty results', () async {
      final definition = h.simpleForeachDefinition(
        name: 'foreach-empty',
        description: 'Empty foreach',
        collectionKey: 'stories',
      );

      final run = await h.insertRun(definition);
      final context = WorkflowContext()..['stories'] = <Map<String, dynamic>>[];

      await h.executor.execute(run, definition, context, startFromStepIndex: 1);

      final updatedRun = await h.repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.completed));
      expect(context['results'], isA<List<Object?>>());
      expect((context['results'] as List<Object?>), isEmpty);
    });

    test('foreach child step failure records iteration failure', () async {
      final definition = h.simpleForeachDefinition(
        name: 'foreach-fail',
        description: 'Foreach with child failure',
        foreachSteps: const ['step-a', 'step-b'],
      );

      final run = await h.insertRun(definition);
      final context = WorkflowContext()..['items'] = ['item1', 'item2'];

      var taskCount = 0;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        taskCount++;
        await Future<void>.delayed(Duration.zero);
        if (taskCount == 1) {
          // Fail the first child step of item1 — item1 should fail, item2 proceeds.
          await h.completeTask(e.taskId, status: TaskStatus.failed);
        } else {
          await h.completeTask(e.taskId);
        }
      });

      await h.executor.execute(run, definition, context, startFromStepIndex: 1);
      await sub.cancel();

      // item1: step-a fails → no step-b for item1. item2 still runs (step-a + step-b).
      expect(taskCount, 3);

      // Foreach with a failed iteration pauses the workflow (consistent with map step behavior).
      final updatedRun = await h.repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.failed));
    });

    test('foreach fires MapIterationCompletedEvent per item', () async {
      final definition = h.simpleForeachDefinition(name: 'foreach-events', description: 'Event test');

      final context = WorkflowContext()..['items'] = ['a', 'b'];

      final iterEvents = <MapIterationCompletedEvent>[];
      final iterSub = h.eventBus.on<MapIterationCompletedEvent>().listen(iterEvents.add);

      await h.executeCountingQueuedTasks(definition, context, startFromStepIndex: 1);
      await iterSub.cancel();

      expect(iterEvents.length, 2);
      expect(iterEvents[0].iterationIndex, 0);
      expect(iterEvents[1].iterationIndex, 1);
      expect(iterEvents[0].stepId, 'fe');
    });

    test('foreach fires MapStepCompletedEvent with aggregate stats', () async {
      final definition = h.simpleForeachDefinition(
        name: 'foreach-complete-event',
        description: 'Completion event test',
      );

      final context = WorkflowContext()..['items'] = ['a', 'b'];

      MapStepCompletedEvent? completionEvent;
      final completeSub = h.eventBus.on<MapStepCompletedEvent>().listen((e) => completionEvent = e);

      await h.executeCountingQueuedTasks(definition, context, startFromStepIndex: 1);
      await completeSub.cancel();

      expect(completionEvent, isNotNull);
      expect(completionEvent!.stepId, 'fe');
      expect(completionEvent!.totalIterations, 2);
    });

    test('foreach crash recovery resumes from crashed iteration without replaying completed', () async {
      final collection = [
        {'id': 'S01'},
        {'id': 'S02'},
        {'id': 'S03'},
      ];
      final definition = h.simpleForeachDefinition(
        name: 'foreach-recovery',
        description: 'Recovery test',
        collectionKey: 'stories',
        childPrompt: 'Do {{map.item}}',
      );

      final run = h.makeRun(definition);
      // Seed cursor: iteration 0 completed, iterations 1 and 2 pending.
      final foreachCursor = WorkflowExecutionCursor.foreach(
        stepId: 'fe',
        stepIndex: 1, // index of the foreach controller in the step list
        totalItems: 3,
        completedIndices: [0],
        resultSlots: [
          {'child': {}},
          null,
          null,
        ],
      );
      final seededRun = run.copyWith(
        executionCursor: foreachCursor,
        contextJson: {
          'stories': collection,
          '_foreach.current.stepId': 'fe',
          '_foreach.current.total': 3,
          '_foreach.current.completedIndices': [0],
          '_foreach.current.failedIndices': <int>[],
          '_foreach.current.cancelledIndices': <int>[],
        },
      );
      await h.repository.insert(seededRun);
      final context = WorkflowContext()..['stories'] = collection;

      var taskCount = 0;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        taskCount++;
        await Future<void>.delayed(Duration.zero);
        await h.completeTask(e.taskId);
      });

      // Resume: the executor should skip iteration 0 and run iterations 1 and 2.
      await h.executor.execute(seededRun, definition, context, startCursor: foreachCursor);
      await sub.cancel();

      // Only 2 tasks (for iterations 1 and 2), not 3.
      expect(taskCount, 2, reason: 'Already-completed iteration 0 should not be replayed');

      final updatedRun = await h.repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('foreach exceeding maxItems fails the step', () async {
      final definition = h.simpleForeachDefinition(name: 'foreach-max', description: 'MaxItems test', maxItems: 2);

      final run = await h.insertRun(definition);
      final context = WorkflowContext()..['items'] = ['a', 'b', 'c'];

      await h.executor.execute(run, definition, context, startFromStepIndex: 1);

      final updatedRun = await h.repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.failed));
      expect(updatedRun?.errorMessage, contains('maxItems'));
    });

    test('foreach above 20 succeeds when maxItems is unset', () async {
      final definition = h.simpleForeachDefinition(
        name: 'foreach-uncapped',
        description: 'Uncapped foreach test',
        maxParallel: 5,
      );
      final context = WorkflowContext()..['items'] = List.generate(30, (i) => 'item$i');
      final result = await h.executeCountingQueuedTasks(definition, context, startFromStepIndex: 1);
      expect(result.finalRun?.status, equals(WorkflowRunStatus.completed));
      expect(context['results'], isA<List<Object?>>());
      expect((context['results'] as List).length, equals(30));
    });
  });

  group('nested remediation loop in a foreach body', () {
    // Body: review → loop(remediate + re-review), exitGate gating==0. Items run
    // sequentially (no real-time waits: the queued listener completes each task
    // with Duration.zero), so the current item is tracked via the Review step.
    const nestedYaml = r'''
name: nested-remediation
description: per-item converging loop
steps:
  - id: per-item
    name: Per Item
    type: foreach
    map_over: items
    onFailure: continue
    outputs: { story_results: { format: json } }
    steps:
      - id: review
        name: Review
        prompt: review
        outputs:
          gating_findings_count: gating_findings_count
          review_findings: text
      - id: remediation
        name: Remediation Loop
        type: loop
        maxIterations: 4
        exitGate: "gating_findings_count == 0"
        steps:
          - id: remediate
            name: Remediate
            prompt: fix
          - id: re-review
            name: Re-review
            prompt: rr
            outputs:
              gating_findings_count: gating_findings_count
              review_findings: text
''';

    test('converges independently per item; review output never leaks (S03/S04)', () async {
      final def = WorkflowDefinitionParser().parse(nestedYaml);
      final run = h.makeRun(def);
      await h.repository.insert(run);
      final context = WorkflowContext()..['items'] = ['A', 'B'];

      var currentItem = -1;
      final reReviewByItem = <int, int>{0: 0, 1: 0};
      final remediateByItem = <int, int>{0: 0, 1: 0};
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final t = await h.taskService.get(e.taskId);
        final title = t!.title;
        if (title.contains('Re-review')) {
          reReviewByItem[currentItem] = reReviewByItem[currentItem]! + 1;
          // Item A (index 0) needs 2 loop iterations; item B (index 1) needs 1.
          final converged = reReviewByItem[currentItem]! >= (currentItem == 0 ? 2 : 1);
          await h.completeTaskWithOutcome(
            e.taskId,
            outcomeContent:
                '<workflow-context>{"gating_findings_count": ${converged ? 0 : 1}, "review_findings": "rf"}</workflow-context>',
          );
        } else if (title.contains('Remediate')) {
          remediateByItem[currentItem] = remediateByItem[currentItem]! + 1;
          await h.completeTask(e.taskId);
        } else if (title.contains('Review')) {
          currentItem++;
          await h.completeTaskWithOutcome(
            e.taskId,
            outcomeContent:
                '<workflow-context>{"gating_findings_count": 1, "review_findings": "rf"}</workflow-context>',
          );
        } else {
          await h.completeTask(e.taskId);
        }
      });

      await h.executor.execute(run, def, context);
      await sub.cancel();

      final finalRun = await h.repository.getById(run.id);
      expect(finalRun?.status, WorkflowRunStatus.completed);
      // S03: each item terminates on its own exit gate, counts do not bleed.
      expect(reReviewByItem, {0: 2, 1: 1});
      expect(remediateByItem, {0: 2, 1: 1});
      // S04: the loop body's bare review keys live only inside each iteration's
      // context. The run-level context (asserted live, where the foreach writes
      // its per-child namespaced keys) holds no bare gating_findings_count /
      // review_findings originating in the loop, and no ${loopStepId}[i].* keys
      // from the loop controller (which declares no outputs).
      expect(context['gating_findings_count'], isNull, reason: 'no bare loop count leaks to the parent');
      expect(context['review_findings'], isNull, reason: 'no bare loop findings path leaks to the parent');
      expect(context['remediation[0].review_findings'], isNull);
      expect(context['remediation[1].review_findings'], isNull);
      expect(context['remediation[0].gating_findings_count'], isNull);
      // Sanity: the per-iteration loop state keys were cleared on convergence.
      expect(context.data.keys.where((k) => k.startsWith('_loop.remediation.foreach.')), isEmpty);
    });

    test('resume restarts the nested loop at the right item/iteration/step (S05)', () async {
      final def = WorkflowDefinitionParser().parse(nestedYaml);
      final perItemIndex = def.steps.indexWhere((s) => s.id == 'per-item');
      final run = h.makeRun(def);
      // Seed: item 0 complete; item 1's review done, loop interrupted at
      // iteration 2's re-review (remediate of iter 2 already done).
      final cursor = WorkflowExecutionCursor.foreach(
        stepId: 'per-item',
        stepIndex: perItemIndex,
        totalItems: 2,
        completedIndices: [0],
        resultSlots: [
          {'review': <String, dynamic>{}, 'remediation': <String, dynamic>{}},
          null,
        ],
        completedSubStepIdsByIndex: {
          1: ['review'],
        },
      );
      final seeded = run.copyWith(executionCursor: cursor);
      await h.repository.insert(seeded);
      // Mirror production resume (`_loadResumeContext` rebuilds the context from
      // run.contextJson): the nested-loop checkpoint keys must be present.
      final seededContext = WorkflowContext()
        ..['items'] = ['A', 'B']
        ..['review[1].gating_findings_count'] = 1
        ..['_loop.remediation.foreach.per-item[1].iteration'] = 2
        ..['_loop.remediation.foreach.per-item[1].stepId'] = 're-review'
        ..['_loop.remediation.foreach.per-item[1].tokens'] = 70
        ..['_loop.remediation.foreach.per-item[1].iterData'] = {
          'gating_findings_count': 1,
          'remediation_summary': 'prior remediation',
          'map': {'item': 'B', 'index': 1, 'length': 2},
        };
      // Exercise the real production serialization leg: persisted contextJson is
      // JSON-encoded to SQLite and rebuilt via WorkflowContext.fromJson, so the
      // nested-loop checkpoint (including the iterData snapshot's bare review
      // keys) must survive an encode→decode→fromJson round-trip.
      final context = WorkflowContext.fromJson(
        Map<String, dynamic>.from(jsonDecode(jsonEncode(seededContext.toJson())) as Map),
      );

      var remediateCount = 0;
      var reReviewCount = 0;
      var reviewCount = 0;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final t = await h.taskService.get(e.taskId);
        final title = t!.title;
        if (title.contains('Remediate')) {
          remediateCount++;
          await h.completeTask(e.taskId);
        } else if (title.contains('Re-review')) {
          reReviewCount++;
          await h.completeTaskWithOutcome(
            e.taskId,
            outcomeContent:
                '<workflow-context>{"gating_findings_count": 0, "review_findings": "rf"}</workflow-context>',
            tokenCount: 40,
          );
        } else if (title.contains('Review')) {
          reviewCount++;
          await h.completeTask(e.taskId);
        } else {
          await h.completeTask(e.taskId);
        }
      });

      await h.executor.execute(seeded, def, context, startCursor: cursor);
      await sub.cancel();

      final finalRun = await h.repository.getById(run.id);
      expect(finalRun?.status, WorkflowRunStatus.completed);
      // Item 0 not re-run, item 1 review not re-run.
      expect(reviewCount, 0, reason: 'completed reviews are not replayed');
      // Iteration 2 resumes at re-review; iter-2 remediate already done.
      expect(reReviewCount, 1, reason: 'only iteration 2 re-review runs on resume');
      expect(remediateCount, 0, reason: 'iteration 2 remediate was already completed before the crash');
      // Pre-crash body tokens (seeded `.tokens` checkpoint) plus the resumed
      // re-review's tokens reach run.totalTokens exactly once via the foreach.
      expect(finalRun?.totalTokens, 110, reason: 'pre-crash loop tokens (70) + resumed re-review (40)');
    });

    test('budget check inside the nested loop counts locally accumulated body tokens', () async {
      final def = WorkflowDefinitionParser().parse(nestedYaml).copyWith(maxTokens: 100);
      final run = h.makeRun(def);
      await h.repository.insert(run);
      final context = WorkflowContext()..['items'] = ['A'];

      var remediateCount = 0;
      var reReviewCount = 0;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final t = await h.taskService.get(e.taskId);
        final title = t!.title;
        if (title.contains('Re-review')) {
          reReviewCount++;
          await h.completeTaskWithOutcome(
            e.taskId,
            outcomeContent:
                '<workflow-context>{"gating_findings_count": 1, "review_findings": "rf"}</workflow-context>',
            tokenCount: 60,
          );
        } else if (title.contains('Remediate')) {
          remediateCount++;
          await h.completeTask(e.taskId);
        } else if (title.contains('Review')) {
          await h.completeTaskWithOutcome(
            e.taskId,
            outcomeContent:
                '<workflow-context>{"gating_findings_count": 1, "review_findings": "rf"}</workflow-context>',
          );
        } else {
          await h.completeTask(e.taskId);
        }
      });

      await h.executor.execute(run, def, context);
      await sub.cancel();

      // Iteration 1 and 2 each burn 60 tokens in re-review; before iteration
      // 3's first body step the check sees 120 >= 100 and stops the loop –
      // without counting loopTokens it would run to maxIterations (4).
      expect(reReviewCount, 2, reason: 'budget stops the loop before iteration 3');
      expect(remediateCount, 2);
      expect(context['step.remediation[0].outcome.reason'], contains('budget'));
      // The consumed body tokens are still attributed to the run exactly once.
      final finalRun = await h.repository.getById(run.id);
      expect(finalRun?.totalTokens, 120);
    });

    test('settled item tokens stop the next item before dispatch', () async {
      final def = WorkflowDefinitionParser().parse(nestedYaml).copyWith(maxTokens: 100);
      final run = h.makeRun(def);
      await h.repository.insert(run);
      final context = WorkflowContext()..['items'] = ['A', 'B'];

      var reviewCount = 0;
      var reReviewCount = 0;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final t = await h.taskService.get(e.taskId);
        final title = t!.title;
        if (title.contains('Re-review')) {
          reReviewCount++;
          await h.completeTaskWithOutcome(
            e.taskId,
            outcomeContent:
                '<workflow-context>{"gating_findings_count": 0, "review_findings": "rf"}</workflow-context>',
            tokenCount: 80,
          );
        } else if (title.contains('Remediate')) {
          await h.completeTask(e.taskId);
        } else if (title.contains('Review')) {
          reviewCount++;
          await h.completeTaskWithOutcome(
            e.taskId,
            outcomeContent:
                '<workflow-context>{"gating_findings_count": 1, "review_findings": "rf"}</workflow-context>',
            tokenCount: 30,
          );
        } else {
          await h.completeTask(e.taskId);
        }
      });

      await h.executor.execute(run, def, context);
      await sub.cancel();

      final finalRun = await h.repository.getById(run.id);
      // Item A burns 110 tokens (review 30 + converging loop pass 80) >= 100.
      // The controller's check sees A's settled tokens and cancels item B
      // before dispatch – previously B ran to its own limit on a fresh basis.
      expect(reviewCount, 1, reason: "item B's review never dispatches");
      expect(reReviewCount, 1);
      expect(finalRun?.status, WorkflowRunStatus.failed);
      expect(finalRun?.errorMessage, contains('budget exhausted'));
      expect(finalRun?.totalTokens, 110, reason: "item A's tokens reach the run exactly once via the foreach sum");
    });

    test('nested loop budget check includes settled sibling iteration tokens', () async {
      final def = WorkflowDefinitionParser().parse(nestedYaml).copyWith(maxTokens: 100);
      final run = h.makeRun(def);
      await h.repository.insert(run);
      final context = WorkflowContext()..['items'] = ['A', 'B'];

      var currentItem = -1;
      final reReviewByItem = <int, int>{0: 0, 1: 0};
      final remediateByItem = <int, int>{0: 0, 1: 0};
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final t = await h.taskService.get(e.taskId);
        final title = t!.title;
        if (title.contains('Re-review')) {
          reReviewByItem[currentItem] = reReviewByItem[currentItem]! + 1;
          // Item A converges on its first pass; item B never converges.
          await h.completeTaskWithOutcome(
            e.taskId,
            outcomeContent:
                '<workflow-context>{"gating_findings_count": ${currentItem == 0 ? 0 : 1}, "review_findings": "rf"}</workflow-context>',
            tokenCount: 60,
          );
        } else if (title.contains('Remediate')) {
          remediateByItem[currentItem] = remediateByItem[currentItem]! + 1;
          await h.completeTask(e.taskId);
        } else if (title.contains('Review')) {
          currentItem++;
          await h.completeTaskWithOutcome(
            e.taskId,
            outcomeContent:
                '<workflow-context>{"gating_findings_count": 1, "review_findings": "rf"}</workflow-context>',
          );
        } else {
          await h.completeTask(e.taskId);
        }
      });

      await h.executor.execute(run, def, context);
      await sub.cancel();

      // Item A settles at 60 tokens (< 100), so item B dispatches. Before item
      // B's second loop iteration the check sees A's 60 + B's own 60 = 120 >=
      // 100 and stops – with only the local accumulator B would get a second
      // 60-token pass before stopping.
      expect(reReviewByItem, {0: 1, 1: 1}, reason: "item B's loop stops after one pass on the combined basis");
      expect(remediateByItem, {0: 1, 1: 1});
      expect(context['step.remediation[1].outcome.reason'], contains('budget'));
      final finalRun = await h.repository.getById(run.id);
      expect(finalRun?.status, WorkflowRunStatus.failed);
      expect(finalRun?.errorMessage, contains('budget exhausted'));
      expect(finalRun?.totalTokens, 120, reason: 'both items attributed exactly once via the foreach sum');
    });
  });
}
