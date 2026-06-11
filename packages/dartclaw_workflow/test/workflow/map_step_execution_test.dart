@Tags(['component'])
library;

import 'dart:async';

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        MapIterationCompletedEvent,
        MapStepCompletedEvent,
        OnFailurePolicy,
        OutputConfig,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowGitCleanupStrategy,
        WorkflowGitPublishStrategy,
        WorkflowGitStrategy,
        WorkflowGitWorktreeMode,
        WorkflowGitWorktreeStrategy,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowRunStatusChangedEvent,
        WorkflowStep,
        WorkflowTaskType;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'workflow_executor_test_support.dart'
    show ThrowingContextExtractor, WorkflowExecutorHarness, standardTurnAdapter;

void main() {
  final h = WorkflowExecutorHarness();
  setUp(h.setUp);
  tearDown(h.tearDown);

  WorkflowDefinition mapDefinition({
    required String name,
    required String description,
    int maxParallel = 1,
    OnFailurePolicy onFailure = OnFailurePolicy.fail,
    int? maxRetries,
    int? timeoutSeconds,
  }) {
    return WorkflowDefinition(
      name: name,
      description: description,
      steps: [
        WorkflowStep(
          id: 'implement',
          name: 'Implement',
          prompts: const ['Implement {{map.item}}'],
          mapOver: 'items',
          maxParallel: maxParallel,
          onFailure: onFailure,
          maxRetries: maxRetries,
          timeoutSeconds: timeoutSeconds,
        ),
      ],
    );
  }

  WorkflowContext itemsContext(List<String> items) => WorkflowContext(data: {'items': items});

  WorkflowDefinition producedMapDefinition({
    String name = 'test-wf',
    String description = 'Map test',
    String? project,
    WorkflowGitStrategy? gitStrategy,
    String collectionKey = 'items',
    String mapStepId = 'map',
    String mapStepName = 'Map',
    WorkflowTaskType? mapStepType,
    String prompt = 'Process {{map.item}}',
    Object? maxParallel,
    int? maxItems,
    Map<String, OutputConfig> outputs = const {'mapped': OutputConfig()},
  }) {
    return WorkflowDefinition(
      name: name,
      description: description,
      project: project,
      gitStrategy: gitStrategy,
      steps: [
        WorkflowStep(
          id: 'produce',
          name: 'Produce',
          prompts: const ['p'],
          outputs: {collectionKey: const OutputConfig()},
        ),
        WorkflowStep(
          id: mapStepId,
          name: mapStepName,
          type: mapStepType,
          prompts: [prompt],
          mapOver: collectionKey,
          maxParallel: maxParallel,
          maxItems: maxItems,
          outputs: outputs,
        ),
      ],
    );
  }

  Future<WorkflowRun> insertRun(WorkflowDefinition definition) async {
    final run = h.makeRun(definition);
    await h.repository.insert(run);
    return run;
  }

  StreamSubscription<TaskStatusChangedEvent> completeQueuedTasks({
    Future<void> Function(TaskStatusChangedEvent event)? beforeComplete,
  }) {
    return h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((e) async {
      await Future<void>.delayed(Duration.zero);
      await beforeComplete?.call(e);
      await h.completeTask(e.taskId);
    });
  }

  group('core map execution', () {
    test('S02 map item retries task failure exactly once with maxRetries 1', () async {
      final definition = mapDefinition(
        name: 'map-retry-task-failure',
        description: 'Map retry count test',
        onFailure: OnFailurePolicy.retry,
        maxRetries: 1,
      );
      final run = await insertRun(definition);
      final context = itemsContext(['a']);

      final taskIds = <String>[];
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        taskIds.add(e.taskId);
        await h.completeTask(e.taskId, status: TaskStatus.failed);
      });

      await h.executor.execute(run, definition, context);
      await sub.cancel();

      expect(taskIds, hasLength(2));
      for (final taskId in taskIds) {
        expect((await h.taskService.get(taskId))?.maxRetries, equals(0));
      }
      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    });

    test('S02 map item retries completed-task failed outcome once and accumulates retry tokens', () async {
      final definition = mapDefinition(
        name: 'map-retry-outcome-failure',
        description: 'Map retry outcome count test',
        onFailure: OnFailurePolicy.retry,
        maxRetries: 1,
      );
      final run = await insertRun(definition);
      final context = itemsContext(['a']);

      var taskCount = 0;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        taskCount++;
        await h.completeTaskWithOutcome(
          e.taskId,
          outcomeContent: taskCount == 1
              ? '<step-outcome>{"outcome":"failed","reason":"missing artifact"}</step-outcome>'
              : '<step-outcome>{"outcome":"succeeded","reason":"artifact found"}</step-outcome>',
          tokenCount: taskCount == 1 ? 7 : 11,
        );
      });

      await h.executor.execute(run, definition, context);
      await sub.cancel();

      expect(taskCount, equals(2));
      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
      expect(finalRun?.totalTokens, equals(18));
      expect(finalRun?.contextJson['data']?['implement[0].tokenCount'], equals(18));
    });

    test('settled map item tokens stop the next item before dispatch', () async {
      // Mid-map budget regression: each iteration's tokens reach run.totalTokens
      // only at map completion, so the mid-map check must add the settled
      // per-iteration `<stepId>[i].tokenCount` keys as an evaluation-only basis.
      // Without it item B dispatches on a stale 0-token basis and the map
      // overruns maxTokens by ~N× per-item burn.
      final definition = producedMapDefinition(
        name: 'map-budget-stop',
        description: 'Map mid-budget stop',
        prompt: 'Process {{map.item}}',
        maxParallel: 1,
      ).copyWith(maxTokens: 100);
      final run = await insertRun(definition);
      final context = WorkflowContext()..['items'] = ['A', 'B'];

      final dispatched = <String>[];
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final task = await h.taskService.get(e.taskId);
        dispatched.add(task?.description ?? '');
        // Item A burns the whole budget; the settled basis must stop item B.
        await h.completeTaskWithOutcome(e.taskId, outcomeContent: 'done', tokenCount: 120);
      });

      await h.executor.execute(run, definition, context, startFromStepIndex: 1);
      await sub.cancel();

      expect(
        dispatched,
        hasLength(1),
        reason: "item B must not dispatch once item A's settled tokens exhaust the budget",
      );
      expect(dispatched.single, contains('A'));
      final mapped = context['mapped'] as List;
      expect((mapped[1] as Map)['message'], contains('budget exhausted'), reason: 'item B is cancelled by budget');
      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.totalTokens, equals(120), reason: "item A's tokens reach the run exactly once via the map sum");
    });

    test('S02 map retry stays inside the item branch and does not block sibling dispatch', () async {
      final definition = mapDefinition(
        name: 'map-retry-concurrency',
        description: 'Map retry concurrency test',
        maxParallel: 2,
        onFailure: OnFailurePolicy.retry,
        maxRetries: 1,
      );
      final run = await insertRun(definition);
      final context = itemsContext(['slow', 'fast']);

      final queuedDescriptions = <String>[];
      String? slowFirstTaskId;
      var slowAttempts = 0;
      final secondInitialQueued = Completer<void>();
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final task = await h.taskService.get(e.taskId);
        final description = task?.description ?? '';
        queuedDescriptions.add(description);
        if (description.contains('slow')) {
          slowAttempts++;
          if (slowAttempts == 1) {
            slowFirstTaskId = e.taskId;
            if (queuedDescriptions.length >= 2 && !secondInitialQueued.isCompleted) {
              secondInitialQueued.complete();
            }
            return;
          }
          await h.completeTaskWithOutcome(
            e.taskId,
            outcomeContent: '<step-outcome>{"outcome":"succeeded","reason":"slow recovered"}</step-outcome>',
          );
          return;
        }
        if (description.contains('fast')) {
          if (slowFirstTaskId != null && !secondInitialQueued.isCompleted) {
            secondInitialQueued.complete();
          }
          await h.completeTaskWithOutcome(
            e.taskId,
            outcomeContent: '<step-outcome>{"outcome":"succeeded","reason":"fast done"}</step-outcome>',
          );
        }
      });

      final execution = h.executor.execute(run, definition, context).timeout(const Duration(seconds: 5));
      await secondInitialQueued.future.timeout(const Duration(seconds: 2));
      expect(
        queuedDescriptions.take(2).where((description) => description.contains('fast')),
        isNotEmpty,
        reason: 'sibling item should be dispatched before the slow item retry is released',
      );
      await h.completeTaskWithOutcome(
        slowFirstTaskId!,
        outcomeContent: '<step-outcome>{"outcome":"failed","reason":"transient slow failure"}</step-outcome>',
      );
      await execution;
      await sub.cancel();

      expect(slowAttempts, equals(2));
      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('S02 map item run-abort during wait is not retried and does not complete the run', () async {
      // Regression: a run pause/cancel mid-wait must abort the item without
      // retrying (no orphan task triples) AND propagate to the step so the
      // runner stops dispatching siblings and the h.executor exits without
      // overwriting the cancelled status to completed. Mirrors single-step.
      final definition = mapDefinition(
        name: 'map-abort-not-retried',
        description: 'Map abort-not-retried test',
        onFailure: OnFailurePolicy.retry,
        maxRetries: 2,
      );
      final run = await insertRun(definition);
      // Two items: the second proves the abort stops sibling dispatch.
      final context = itemsContext(['a', 'b']);

      final taskIds = <String>[];
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        taskIds.add(e.taskId);
        // Run leaves `running` mid-wait. Persist the status so any (buggy) retry
        // attempt's re-check also aborts, bounding the failure mode instead of
        // hanging; then signal the abort. The task is intentionally not completed.
        final current = await h.repository.getById(run.id);
        if (current != null) {
          await h.repository.update(current.copyWith(status: WorkflowRunStatus.cancelled));
        }
        h.eventBus.fire(
          WorkflowRunStatusChangedEvent(
            runId: run.id,
            definitionName: definition.name,
            oldStatus: WorkflowRunStatus.running,
            newStatus: WorkflowRunStatus.cancelled,
            timestamp: DateTime.now(),
          ),
        );
      });

      await h.executor.execute(run, definition, context).timeout(const Duration(seconds: 5));
      await sub.cancel();

      expect(
        taskIds,
        hasLength(1),
        reason: 'run-abort must not be retried into orphan tasks nor dispatch the sibling item',
      );
      final finalRun = await h.repository.getById('run-1');
      expect(
        finalRun?.status,
        equals(WorkflowRunStatus.cancelled),
        reason: 'an aborted map step must not overwrite the cancelled run with completed',
      );
    });

    test('S02 map item wait timeout is terminal, not retried', () async {
      // Regression: a per-item timeout is an infra failure, not an OC02 outcome
      // failure, so it must not consume the workflow retry budget.
      final definition = mapDefinition(
        name: 'map-timeout-not-retried',
        description: 'Map timeout-not-retried test',
        onFailure: OnFailurePolicy.retry,
        maxRetries: 2,
        timeoutSeconds: 1,
      );
      final run = await insertRun(definition);
      final context = itemsContext(['a']);

      final taskIds = <String>[];
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        taskIds.add(e.taskId);
        // Never complete the task: the wait times out. A timeout must be terminal.
      });

      await h.executor.execute(run, definition, context).timeout(const Duration(seconds: 10));
      await sub.cancel();

      expect(taskIds, hasLength(1), reason: 'a per-item timeout must be terminal, not retried');
      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.failed));
    });

    test('S02 map item fails when context extraction throws an unexpected error', () async {
      // Parity with the single-step path: an unexpected (non-MissingArtifact,
      // non-StateError) extraction exception must fail the item, not silently
      // succeed with empty outputs.
      final definition = mapDefinition(
        name: 'map-extraction-error',
        description: 'Map generic extraction failure test',
      );
      final run = await insertRun(definition);
      final context = itemsContext(['a']);

      final throwingExecutor = h.makeExecutor(
        contextExtractor: ThrowingContextExtractor(
          taskService: h.taskService,
          messageService: h.messageService,
          dataDir: h.tempDir.path,
          workflowStepExecutionRepository: h.workflowStepExecutionRepository,
        ),
      );

      final sub = completeQueuedTasks();

      await throwingExecutor.execute(run, definition, context);
      await sub.cancel();

      final finalRun = await h.repository.getById('run-1');
      expect(
        finalRun?.status,
        equals(WorkflowRunStatus.failed),
        reason: 'an unexpected extraction exception must fail the map item, not silently succeed',
      );
    });

    test('workflow-owned map coding task auto-advances on accepted terminal status', () async {
      final definition = WorkflowDefinition(
        name: 'map-auto-accept',
        description: 'Workflow-owned map tasks should unblock on accepted.',
        project: '{{PROJECT}}',
        gitStrategy: const WorkflowGitStrategy(
          integrationBranch: true,
          worktree: WorkflowGitWorktreeStrategy(mode: WorkflowGitWorktreeMode.perMapItem),
          promotion: 'merge',
          publish: WorkflowGitPublishStrategy(enabled: false),
        ),
        steps: const [
          WorkflowStep(
            id: 'implement',
            name: 'Implement Stories',
            prompts: ['Implement {{map.item.id}}'],
            mapOver: 'stories',
            maxParallel: 1,
            outputs: {'story_result': OutputConfig()},
          ),
        ],
      );

      final run = WorkflowRun(
        id: 'map-review-ready-run',
        definitionName: definition.name,
        status: WorkflowRunStatus.running,
        startedAt: DateTime.now(),
        updatedAt: DateTime.now(),
        variablesJson: const {'PROJECT': 'my-project', 'BRANCH': 'main'},
        definitionJson: definition.toJson(),
      );
      await h.repository.insert(run);

      final context = WorkflowContext(
        data: {
          'stories': [
            {'id': 'S01'},
          ],
        },
        variables: const {'PROJECT': 'my-project', 'BRANCH': 'main'},
      );

      final runtimeExecutor = h.makeExecutor(turnAdapter: standardTurnAdapter());

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        final task = await h.taskService.get(e.taskId);
        if (task == null) return;
        await h.taskService.updateFields(
          task.id,
          worktreeJson: {
            'path': p.join(h.tempDir.path, 'worktrees', task.id),
            'branch': 'story-s01',
            'createdAt': DateTime.now().toIso8601String(),
          },
        );
        try {
          await h.taskService.transition(task.id, TaskStatus.running, trigger: 'test');
        } on StateError {
          // Already running.
        }
        await h.taskService.transition(task.id, TaskStatus.accepted, trigger: 'test');
      });

      await runtimeExecutor.execute(run, definition, context);
      await sub.cancel();

      final finalRun = await h.repository.getById('map-review-ready-run');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('3-item array creates 3 tasks', () async {
      final collection = [
        {'id': 's01', 'name': 'Story 1'},
        {'id': 's02', 'name': 'Story 2'},
        {'id': 's03', 'name': 'Story 3'},
      ];
      final definition = producedMapDefinition(
        collectionKey: 'stories',
        mapStepId: 'implement',
        mapStepName: 'Implement',
        prompt: 'Implement {{map.item}}',
        maxParallel: 3,
        outputs: const {'results': OutputConfig()},
      );

      final run = await insertRun(definition);
      final context = WorkflowContext()..['stories'] = collection;

      final taskIds = <String>[];
      final sub = completeQueuedTasks(
        beforeComplete: (e) async {
          taskIds.add(e.taskId);
        },
      );

      await h.executor.execute(run, definition, context, startFromStepIndex: 1);
      await sub.cancel();

      expect(taskIds.length, equals(3), reason: '3 tasks should be created, one per item');
    });

    // `gitStrategy.worktree: auto` resolves at dispatch through
    // WorkflowGitStrategy.effectiveWorktreeMode (serial → inline, parallel /
    // unlimited → per-map-item). The pure resolution is unit-tested in
    // workflow_definition_test.dart; this table proves the dispatch wiring
    // persists the resolved mode on the step execution's git['worktree'].
    for (final (label, maxParallel, expectedMode) in <(String, Object, String)>[
      ('serial', 1, 'inline'),
      ('parallel', 2, 'per-map-item'),
      ('unlimited', 'unlimited', 'per-map-item'),
    ]) {
      test('worktree auto resolves to $expectedMode for $label map execution', () async {
        final repoBackedExecutor = h.makeExecutor();
        final definition = producedMapDefinition(
          name: 'map-$label-auto',
          description: 'Map auto worktree $label resolution',
          gitStrategy: const WorkflowGitStrategy(
            worktree: WorkflowGitWorktreeStrategy(mode: WorkflowGitWorktreeMode.auto),
          ),
          collectionKey: 'stories',
          mapStepId: 'implement',
          mapStepName: 'Implement',
          mapStepType: WorkflowTaskType.agent,
          prompt: 'Implement {{map.item}}',
          maxParallel: maxParallel,
          outputs: const {},
        );

        final run = await insertRun(definition);
        final context = WorkflowContext()..['stories'] = ['story-1'];
        final modeCompleter = Completer<String?>();

        final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
          e,
        ) async {
          final task = await h.taskService.get(e.taskId);
          if (task != null && !modeCompleter.isCompleted) {
            final workflowGit = (await h.workflowStepExecutionRepository.getByTaskId(task.id))?.git;
            modeCompleter.complete(workflowGit?['worktree'] as String?);
          }
          await h.completeTask(e.taskId);
        });

        await repoBackedExecutor.execute(run, definition, context, startFromStepIndex: 1);
        await sub.cancel();

        expect(await modeCompleter.future, expectedMode);
      });
    }

    test('results collected in index order (not completion order)', () async {
      final collection = ['item0', 'item1', 'item2'];
      final definition = producedMapDefinition(maxParallel: 3);

      final run = await insertRun(definition);
      final context = WorkflowContext()..['items'] = collection;

      // Complete tasks in reverse order (2, 1, 0).
      final taskIds = <String>[];
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        taskIds.add(e.taskId);
      });

      // Run h.executor in background, manually complete tasks in reverse.
      final executorFuture = h.executor.execute(run, definition, context, startFromStepIndex: 1);

      // Wait for all 3 tasks to be created.
      await Future.doWhile(() async {
        await Future<void>.delayed(Duration.zero);
        return taskIds.length < 3;
      });
      await sub.cancel();

      // Complete in reverse order.
      for (final id in taskIds.reversed) {
        await h.completeTask(id);
        await Future<void>.delayed(Duration.zero);
      }
      await executorFuture;

      // Results should be index-ordered (3 slots, all null from default extraction).
      expect(context['mapped'], isA<List<Object?>>());
      expect((context['mapped'] as List).length, equals(3));
    });

    test('maxParallel: 1 (default) executes sequentially', () async {
      final collection = ['a', 'b', 'c'];
      final definition = producedMapDefinition();

      final run = await insertRun(definition);
      final context = WorkflowContext()..['items'] = collection;

      var maxConcurrent = 0;
      var concurrent = 0;
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        concurrent++;
        if (concurrent > maxConcurrent) maxConcurrent = concurrent;
        await Future<void>.delayed(Duration.zero);
        await h.completeTask(e.taskId);
        concurrent--;
      });

      await h.executor.execute(run, definition, context, startFromStepIndex: 1);
      await sub.cancel();

      expect(maxConcurrent, equals(1), reason: 'maxParallel default is 1 (sequential)');
    });

    test('maxParallel: "unlimited" dispatches all items', () async {
      final collection = ['a', 'b', 'c', 'd', 'e'];
      final definition = producedMapDefinition(maxParallel: 'unlimited');

      final run = await insertRun(definition);
      final context = WorkflowContext()..['items'] = collection;

      final taskIds = <String>[];
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        taskIds.add(e.taskId);
      });

      final executorFuture = h.executor.execute(run, definition, context, startFromStepIndex: 1);

      // Wait for all tasks to be queued.
      await Future.doWhile(() async {
        await Future<void>.delayed(Duration.zero);
        return taskIds.length < 5;
      });
      await sub.cancel();

      for (final id in taskIds) {
        await h.completeTask(id);
        await Future<void>.delayed(Duration.zero);
      }
      await executorFuture;

      expect(taskIds.length, equals(5));
    });

    test('map iterations preserve project binding for coding tasks', () async {
      final collection = ['story-a', 'story-b'];
      final definition = producedMapDefinition(
        name: 'test-wf',
        description: 'Project map test',
        collectionKey: 'stories',
        mapStepId: 'implement',
        mapStepName: 'Implement',
        prompt: 'Implement {{map.item}}',
        maxParallel: 2,
        outputs: const {'results': OutputConfig()},
        project: '{{PROJECT}}',
      );

      final run = await insertRun(definition);
      final context = WorkflowContext(variables: const {'PROJECT': 'my-app'})..['stories'] = collection;

      final projectIds = <String?>[];
      final sub = completeQueuedTasks(
        beforeComplete: (e) async {
          final task = await h.taskService.get(e.taskId);
          projectIds.add(task?.projectId);
        },
      );

      await h.executor.execute(run, definition, context, startFromStepIndex: 1);
      await sub.cancel();

      expect(projectIds, equals(['my-app', 'my-app']));
    });
  });

  group('error handling', () {
    // Validation-failure matrix: each bad input must fail the run with the
    // expected error substring(s) and (for pre-dispatch validation) dispatch no
    // tasks. The pure validation logic is exhaustively unit-tested in
    // dependency_graph_test.dart; this table proves the executor surfaces each
    // failure as run.status=failed with the diagnostic envelope.
    for (final case_ in <_MapValidationCase>[
      _MapValidationCase(
        name: 'dependency-aware map rejects unknown dependency IDs before dispatch',
        runId: 'run-unknown-deps',
        definition: WorkflowDefinition(
          name: 'dependency-aware-map',
          description: 'Unknown dependency validation',
          project: '{{PROJECT}}',
          steps: const [
            WorkflowStep(
              id: 'implement',
              name: 'Implement',
              prompts: ['Implement {{map.item.id}}'],
              mapOver: 'stories',
              maxParallel: 2,
              outputs: {'results': OutputConfig()},
            ),
          ],
        ),
        contextData: const {
          'stories': [
            {
              'id': 'S01',
              'dependencies': ['S99'],
            },
          ],
        },
        errorContains: const ['Unknown dependency IDs'],
        expectNoDispatch: true,
      ),
      _MapValidationCase(
        name: 'dependency-aware map missing dependencies fails before dispatch',
        runId: 'run-missing-deps',
        definition: WorkflowDefinition(
          name: 'dependency-aware-map-shape',
          description: 'Shape validation',
          project: '{{PROJECT}}',
          steps: const [
            WorkflowStep(
              id: 'implement',
              name: 'Implement',
              prompts: ['Implement {{map.item.id}}'],
              mapOver: 'stories',
              maxParallel: 2,
              outputs: {'results': OutputConfig()},
            ),
          ],
        ),
        contextData: const {
          'stories': [
            {'id': 'S01'},
            {
              'id': 'S02',
              'dependencies': ['S01'],
            },
          ],
        },
        errorContains: const ['missing `dependencies`'],
        expectNoDispatch: true,
      ),
      _MapValidationCase(
        name: 'mapOver references null key → step fails',
        definition: producedMapDefinition(),
        // 'items' not set in context — should be null.
        contextData: const {},
        startFromStepIndex: 1,
        errorContains: const ['null or missing'],
      ),
      _MapValidationCase(
        name: 'mapOver references non-List → step fails',
        definition: producedMapDefinition(),
        contextData: const {'items': 'not a list'},
        startFromStepIndex: 1,
        errorContains: const ['not a List'],
      ),
      _MapValidationCase(
        name: 'collection exceeding maxItems → step fails with decomposition hint',
        definition: producedMapDefinition(maxItems: 3),
        contextData: {'items': List.generate(5, (i) => 'item$i')},
        startFromStepIndex: 1,
        errorContains: const ['maxItems', 'decompos'],
      ),
      _MapValidationCase(
        name: 'circular dependency detected at step start → step fails',
        definition: producedMapDefinition(
          name: 'test-wf',
          description: 'Dep test',
          collectionKey: 'stories',
          prompt: 'Implement {{map.item}}',
          outputs: const {'results': OutputConfig()},
        ),
        contextData: const {
          'stories': [
            {
              'id': 's01',
              'name': 'S1',
              'dependencies': ['s02'],
            },
            {
              'id': 's02',
              'name': 'S2',
              'dependencies': ['s01'],
            },
          ],
        },
        startFromStepIndex: 1,
        errorContains: const ['Circular dependency'],
      ),
    ]) {
      test(case_.name, () async {
        final definition = case_.definition;
        var run = h.makeRun(definition);
        if (case_.runId != null) run = run.copyWith(id: case_.runId);
        await h.repository.insert(run);
        final context = WorkflowContext(data: Map<String, dynamic>.from(case_.contextData));

        await h.executor.execute(run, definition, context, startFromStepIndex: case_.startFromStepIndex);

        final finalRun = await h.repository.getById(run.id);
        expect(finalRun?.status, equals(WorkflowRunStatus.failed));
        for (final fragment in case_.errorContains) {
          expect(finalRun?.errorMessage, contains(fragment));
        }
        if (case_.expectNoDispatch) {
          final tasks = await h.taskService.list();
          expect(
            tasks.where((t) => t.workflowRunId == run.id),
            isEmpty,
            reason: 'Validation should fail before dispatch',
          );
        }
      });
    }

    test('empty collection succeeds with empty result array', () async {
      final definition = producedMapDefinition();

      final run = await insertRun(definition);
      final context = WorkflowContext()..['items'] = <Object?>[];

      await h.executor.execute(run, definition, context, startFromStepIndex: 1);

      final updatedRun = await h.repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.completed));
      expect(context['mapped'], isA<List<Object?>>());
      expect((context['mapped'] as List).length, equals(0));
    });
    test('failure invokes workflow git cleanup when cleanup is enabled', () async {
      final cleanupCalls = <({String runId, String projectId, String status, bool preserveWorktrees})>[];
      final cleanupExecutor = h.makeExecutor(
        turnAdapter: standardTurnAdapter(
          cleanupWorkflowGit:
              ({required runId, required projectId, required status, required preserveWorktrees}) async {
                cleanupCalls.add((
                  runId: runId,
                  projectId: projectId,
                  status: status,
                  preserveWorktrees: preserveWorktrees,
                ));
              },
        ),
      );
      final collection = List.generate(5, (i) => 'item$i');
      final definition = producedMapDefinition(
        name: 'test-wf',
        description: 'Map test',
        maxItems: 3,
        gitStrategy: const WorkflowGitStrategy(cleanup: WorkflowGitCleanupStrategy(enabled: true)),
      );

      final run = h.makeRun(definition).copyWith(variablesJson: const {'PROJECT': 'alpha'});
      await h.repository.insert(run);
      final context = WorkflowContext()..['items'] = collection;

      await cleanupExecutor.execute(run, definition, context, startFromStepIndex: 1);

      expect(cleanupCalls, hasLength(1));
      expect(cleanupCalls.single, (runId: 'run-1', projectId: 'alpha', status: 'failed', preserveWorktrees: false));
    });

    test('failure preserves workflow git worktrees when cleanup is disabled', () async {
      final cleanupCalls = <({bool preserveWorktrees})>[];
      final cleanupExecutor = h.makeExecutor(
        turnAdapter: standardTurnAdapter(
          cleanupWorkflowGit:
              ({required runId, required projectId, required status, required preserveWorktrees}) async {
                cleanupCalls.add((preserveWorktrees: preserveWorktrees));
              },
        ),
      );
      final definition = producedMapDefinition(
        name: 'test-wf',
        description: 'Map test',
        maxItems: 1,
        gitStrategy: const WorkflowGitStrategy(cleanup: WorkflowGitCleanupStrategy(enabled: false)),
      );

      final run = h.makeRun(definition).copyWith(variablesJson: const {'PROJECT': 'alpha'});
      await h.repository.insert(run);
      final context = WorkflowContext(variables: const {'PROJECT': 'context-project'})..['items'] = ['a', 'b'];

      await cleanupExecutor.execute(run, definition, context, startFromStepIndex: 1);

      expect(cleanupCalls, hasLength(1));
      expect(cleanupCalls.single.preserveWorktrees, isTrue);
    });

    test('failure preserves worktrees when cleanup policy cannot be parsed', () async {
      final cleanupCalls = <({bool preserveWorktrees})>[];
      final cleanupExecutor = h.makeExecutor(
        turnAdapter: standardTurnAdapter(
          cleanupWorkflowGit:
              ({required runId, required projectId, required status, required preserveWorktrees}) async {
                cleanupCalls.add((preserveWorktrees: preserveWorktrees));
              },
        ),
      );
      final definition = producedMapDefinition(
        name: 'test-wf',
        description: 'Map test',
        maxItems: 1,
        gitStrategy: const WorkflowGitStrategy(cleanup: WorkflowGitCleanupStrategy(enabled: true)),
      );

      final run = h
          .makeRun(definition)
          .copyWith(variablesJson: const {'PROJECT': 'alpha'}, definitionJson: const {'steps': 'not-a-list'});
      await h.repository.insert(run);
      final context = WorkflowContext(variables: const {'PROJECT': 'context-project'})..['items'] = ['a', 'b'];

      await cleanupExecutor.execute(run, definition, context, startFromStepIndex: 1);

      expect(cleanupCalls, hasLength(1));
      expect(cleanupCalls.single.preserveWorktrees, isTrue);
    });

    test('failure cleanup resolves project from persisted context variables', () async {
      final cleanupCalls = <({String projectId})>[];
      final cleanupExecutor = h.makeExecutor(
        turnAdapter: standardTurnAdapter(
          cleanupWorkflowGit:
              ({required runId, required projectId, required status, required preserveWorktrees}) async {
                cleanupCalls.add((projectId: projectId));
              },
        ),
      );
      final definition = producedMapDefinition(
        name: 'test-wf',
        description: 'Map test',
        maxItems: 1,
        gitStrategy: const WorkflowGitStrategy(cleanup: WorkflowGitCleanupStrategy(enabled: true)),
      );

      final run = h
          .makeRun(definition)
          .copyWith(contextJson: WorkflowContext(variables: const {'PROJECT': 'context-project'}).toJson());
      await h.repository.insert(run);
      final context = WorkflowContext(variables: const {'PROJECT': 'context-project'})..['items'] = ['a', 'b'];

      await cleanupExecutor.execute(run, definition, context, startFromStepIndex: 1);

      expect(cleanupCalls, hasLength(1));
      expect(cleanupCalls.single.projectId, 'context-project');
    });

    test('collection above 20 succeeds when maxItems is unset', () async {
      final collection = List.generate(30, (i) => 'item$i');
      final definition = producedMapDefinition(maxParallel: 5);

      final run = await insertRun(definition);
      final context = WorkflowContext()..['items'] = collection;

      final sub = completeQueuedTasks();

      await h.executor.execute(run, definition, context, startFromStepIndex: 1);
      await sub.cancel();

      final updatedRun = await h.repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.completed));
      expect(context['mapped'], isA<List<Object?>>());
      expect((context['mapped'] as List).length, equals(30));
    });

    test('single iteration failure — others continue, result array has error object', () async {
      final collection = ['a', 'b', 'c'];
      final definition = producedMapDefinition(maxParallel: 3);

      final run = await insertRun(definition);
      final context = WorkflowContext()..['items'] = collection;

      // Fail the second task (index 1), succeed the others.
      final taskIds = <String>[];
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        taskIds.add(e.taskId);
      });

      final executorFuture = h.executor.execute(run, definition, context, startFromStepIndex: 1);

      await Future.doWhile(() async {
        await Future<void>.delayed(Duration.zero);
        return taskIds.length < 3;
      });
      await sub.cancel();

      // Complete tasks: fail index 1, succeed others.
      for (var i = 0; i < taskIds.length; i++) {
        await h.completeTask(taskIds[i], status: i == 1 ? TaskStatus.failed : TaskStatus.accepted);
        await Future<void>.delayed(Duration.zero);
      }
      await executorFuture;

      // Step should be paused (has failures).
      final updatedRun = await h.repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.failed));

      // Results array is still stored in context before pausing.
      expect(context['mapped'], isA<List<Object?>>());
      final mapped = context['mapped'] as List;
      expect(mapped.length, equals(3));

      // Index 1 should be an error object.
      final errorResult = mapped[1] as Map;
      expect(errorResult['error'], isTrue);
      expect(errorResult, contains('message'));
    });
  });

  group('dependency ordering', () {
    test('item with dependency not dispatched until dep completes', () async {
      final collection = [
        {'id': 's01', 'name': 'S1', 'dependencies': <String>[]},
        {
          'id': 's02',
          'name': 'S2',
          'dependencies': ['s01'],
        },
      ];
      final definition = producedMapDefinition(
        name: 'test-wf',
        description: 'Dep test',
        collectionKey: 'stories',
        prompt: 'Implement {{map.item}}',
        maxParallel: 3,
        outputs: const {'results': OutputConfig()},
      );

      final run = await insertRun(definition);
      final context = WorkflowContext()..['stories'] = collection;

      // Track order of task creation.
      final taskIds = <String>[];
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        taskIds.add(e.taskId);
      });

      final executorFuture = h.executor.execute(run, definition, context, startFromStepIndex: 1);

      // Wait for first task to be queued.
      await Future.doWhile(() async {
        await Future<void>.delayed(Duration.zero);
        return taskIds.isEmpty;
      });

      // At this point only s01 (index 0) should be dispatched.
      expect(taskIds.length, equals(1), reason: 's02 blocked by s01 dependency');

      // Complete s01.
      await h.completeTask(taskIds[0]);
      await Future<void>.delayed(Duration.zero);

      // Wait for s02 to be dispatched.
      await Future.doWhile(() async {
        await Future<void>.delayed(Duration.zero);
        return taskIds.length < 2;
      });
      await sub.cancel();

      // Complete s02.
      await h.completeTask(taskIds[1]);
      await executorFuture;

      expect(taskIds.length, equals(2));
      final updatedRun = await h.repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('whitespace-bearing ids still unblock dependent items after completion', () async {
      final collection = [
        {'id': ' s01 ', 'name': 'S1', 'dependencies': <String>[]},
        {
          'id': 's02',
          'name': 'S2',
          'dependencies': ['s01'],
        },
      ];
      final definition = producedMapDefinition(
        name: 'test-wf',
        description: 'Whitespace dependency normalization',
        collectionKey: 'stories',
        prompt: 'Implement {{map.item}}',
        maxParallel: 3,
        outputs: const {'results': OutputConfig()},
      );

      final run = await insertRun(definition);
      final context = WorkflowContext()..['stories'] = collection;

      final taskIds = <String>[];
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        taskIds.add(e.taskId);
      });

      final executorFuture = h.executor.execute(run, definition, context, startFromStepIndex: 1);

      await Future.doWhile(() async {
        await Future<void>.delayed(Duration.zero);
        return taskIds.isEmpty;
      });

      expect(taskIds, hasLength(1), reason: 'Dependent item must stay blocked until the trimmed prerequisite settles');

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

    test('items without id field are all independent (dispatched immediately)', () async {
      final collection = ['plain-a', 'plain-b', 'plain-c'];
      final definition = producedMapDefinition(
        name: 'test-wf',
        description: 'No dep test',
        prompt: '{{map.item}}',
        maxParallel: 3,
      );

      final run = await insertRun(definition);
      final context = WorkflowContext()..['items'] = collection;

      final taskIds = <String>[];
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        taskIds.add(e.taskId);
      });

      final executorFuture = h.executor.execute(run, definition, context, startFromStepIndex: 1);

      // All 3 should be dispatched immediately.
      await Future.doWhile(() async {
        await Future<void>.delayed(Duration.zero);
        return taskIds.length < 3;
      });
      await sub.cancel();

      expect(taskIds.length, equals(3), reason: 'no deps means all dispatched at once');

      for (final id in taskIds) {
        await h.completeTask(id);
        await Future<void>.delayed(Duration.zero);
      }
      await executorFuture;
    });
  });

  group('events', () {
    test('MapIterationCompletedEvent fired per iteration with correct fields', () async {
      final collection = ['x', 'y'];
      final definition = producedMapDefinition(
        name: 'test-wf',
        description: 'Event test',
        prompt: '{{map.item}}',
        maxParallel: 2,
      );

      final run = await insertRun(definition);
      final context = WorkflowContext()..['items'] = collection;

      final iterEvents = <MapIterationCompletedEvent>[];
      final iterSub = h.eventBus.on<MapIterationCompletedEvent>().listen(iterEvents.add);

      final sub = completeQueuedTasks();

      await h.executor.execute(run, definition, context, startFromStepIndex: 1);
      await sub.cancel();
      await iterSub.cancel();

      expect(iterEvents.length, equals(2));
      expect(iterEvents.map((e) => e.iterationIndex).toSet(), equals({0, 1}));
      for (final e in iterEvents) {
        expect(e.runId, equals('run-1'));
        expect(e.stepId, equals('map'));
        expect(e.totalIterations, equals(2));
        expect(e.success, isTrue);
      }
    });

    test('MapStepCompletedEvent fired with aggregate stats', () async {
      final collection = ['x', 'y', 'z'];
      final definition = producedMapDefinition(
        name: 'test-wf',
        description: 'Event test',
        prompt: '{{map.item}}',
        maxParallel: 3,
      );

      final run = await insertRun(definition);
      final context = WorkflowContext()..['items'] = collection;

      MapStepCompletedEvent? completedEvent;
      final completeSub = h.eventBus.on<MapStepCompletedEvent>().listen((e) => completedEvent = e);

      final sub = completeQueuedTasks();

      await h.executor.execute(run, definition, context, startFromStepIndex: 1);
      await sub.cancel();
      await completeSub.cancel();

      expect(completedEvent, isNotNull);
      expect(completedEvent!.runId, equals('run-1'));
      expect(completedEvent!.stepId, equals('map'));
      expect(completedEvent!.stepName, equals('Map'));
      expect(completedEvent!.totalIterations, equals(3));
      expect(completedEvent!.successCount, equals(3));
      expect(completedEvent!.failureCount, equals(0));
      expect(completedEvent!.cancelledCount, equals(0));
    });

    test('persists map progress checkpoints between sequential map iterations', () async {
      final collection = ['a', 'b', 'c'];
      final definition = WorkflowDefinition(
        name: 'map-recovery',
        description: 'Map recovery',
        steps: const [
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['Process {{map.item}}'],
            mapOver: 'items',
            maxParallel: 1,
            outputs: {'mapped': OutputConfig()},
          ),
        ],
      );

      var run = h.makeRun(definition);
      await h.repository.insert(run);
      final context = WorkflowContext()..['items'] = collection;

      final queuedTitles = <String>[];
      final checkpointReady = Completer<void>();
      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        await Future<void>.delayed(Duration.zero);
        final task = await h.taskService.get(e.taskId);
        if (task == null) return;
        queuedTitles.add(task.title);
        if (queuedTitles.length == 2 && !checkpointReady.isCompleted) {
          checkpointReady.complete();
        }
        await h.completeTask(e.taskId);
      });

      final executeFuture = h.executor.execute(run, definition, context);
      await checkpointReady.future;

      final checkpointed = await h.repository.getById('run-1');
      expect(checkpointed?.executionCursor?.nodeId, 'map');
      expect(checkpointed?.executionCursor?.completedIndices, [0]);

      await executeFuture;
      await sub.cancel();

      expect(queuedTitles, ['map-recovery – Map (1/3)', 'map-recovery – Map (2/3)', 'map-recovery – Map (3/3)']);
      final finalRun = await h.repository.getById('run-1');
      expect(finalRun?.status, equals(WorkflowRunStatus.completed));
    });
  });

  group('maxParallel resolution', () {
    test('maxParallel as int is used directly', () async {
      final collection = List.generate(4, (i) => 'item$i');
      final definition = producedMapDefinition(
        name: 'test-wf',
        description: 'maxParallel test',
        prompt: '{{map.item}}',
        maxParallel: 2,
      );

      final run = await insertRun(definition);
      final context = WorkflowContext()..['items'] = collection;

      var maxConcurrent = 0;
      var concurrent = 0;
      final taskIds = <String>[];

      final sub = h.eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
        e,
      ) async {
        concurrent++;
        taskIds.add(e.taskId);
        if (concurrent > maxConcurrent) maxConcurrent = concurrent;
      });

      final executorFuture = h.executor.execute(run, definition, context, startFromStepIndex: 1);

      // Manually complete tasks to control concurrency observation.
      await Future.doWhile(() async {
        await Future<void>.delayed(Duration.zero);
        if (taskIds.isNotEmpty) {
          final id = taskIds.removeAt(0);
          await h.completeTask(id);
          concurrent--;
        }
        final updatedRun = await h.repository.getById('run-1');
        return updatedRun?.status == WorkflowRunStatus.running;
      });
      await sub.cancel();
      await executorFuture;

      expect(maxConcurrent, lessThanOrEqualTo(2));
    });

    test('invalid maxParallel string → step fails', () async {
      final collection = ['a', 'b'];
      final definition = producedMapDefinition(
        name: 'test-wf',
        description: 'maxParallel test',
        prompt: '{{map.item}}',
        maxParallel: 'not-a-number',
      );

      final run = await insertRun(definition);
      final context = WorkflowContext()..['items'] = collection;

      await h.executor.execute(run, definition, context, startFromStepIndex: 1);

      final updatedRun = await h.repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.failed));
      expect(updatedRun?.errorMessage, contains('maxParallel'));
    });
  });
}

/// One row of the map validation-failure matrix: a bad-input scenario the
/// executor must surface as `run.status=failed` with [errorContains]
/// substring(s), optionally asserting no tasks were dispatched.
class _MapValidationCase {
  const _MapValidationCase({
    required this.name,
    required this.definition,
    required this.contextData,
    required this.errorContains,
    this.runId,
    this.startFromStepIndex = 0,
    this.expectNoDispatch = false,
  });

  final String name;
  final WorkflowDefinition definition;
  final Map<String, dynamic> contextData;
  final List<String> errorContains;
  final String? runId;
  final int startFromStepIndex;
  final bool expectNoDispatch;
}
