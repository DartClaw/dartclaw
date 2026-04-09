import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart'
    show
        EventBus,
        KvService,
        MapIterationCompletedEvent,
        MapStepCompletedEvent,
        MessageService,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowStep;
import 'package:dartclaw_server/dartclaw_server.dart'
    show ContextExtractor, GateEvaluator, TaskService, WorkflowExecutor;
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String sessionsDir;
  late TaskService taskService;
  late MessageService messageService;
  late KvService kvService;
  late SqliteWorkflowRunRepository repository;
  late EventBus eventBus;
  late WorkflowExecutor executor;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_map_step_test_');
    sessionsDir = p.join(tempDir.path, 'sessions');
    Directory(sessionsDir).createSync(recursive: true);

    final db = sqlite3.openInMemory();
    eventBus = EventBus();
    taskService = TaskService(SqliteTaskRepository(db), eventBus: eventBus);
    repository = SqliteWorkflowRunRepository(db);
    messageService = MessageService(baseDir: sessionsDir);
    kvService = KvService(filePath: p.join(tempDir.path, 'kv.json'));

    executor = WorkflowExecutor(
      taskService: taskService,
      eventBus: eventBus,
      kvService: kvService,
      repository: repository,
      gateEvaluator: GateEvaluator(),
      contextExtractor: ContextExtractor(
        taskService: taskService,
        messageService: messageService,
        dataDir: tempDir.path,
      ),
      dataDir: tempDir.path,
    );
  });

  tearDown(() async {
    await taskService.dispose();
    await messageService.dispose();
    await kvService.dispose();
    await eventBus.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  WorkflowRun makeRun(WorkflowDefinition definition) {
    final now = DateTime.now();
    return WorkflowRun(
      id: 'run-1',
      definitionName: definition.name,
      status: WorkflowRunStatus.running,
      startedAt: now,
      updatedAt: now,
      currentStepIndex: 0,
      definitionJson: definition.toJson(),
    );
  }

  /// Simulates task completion: queued → running → terminal.
  Future<void> completeTask(String taskId, {TaskStatus status = TaskStatus.accepted}) async {
    try {
      await taskService.transition(taskId, TaskStatus.running, trigger: 'test');
    } on StateError {
      // May already be running.
    }
    if (status == TaskStatus.accepted || status == TaskStatus.rejected) {
      try {
        await taskService.transition(taskId, TaskStatus.review, trigger: 'test');
      } on StateError {
        // May already be in review.
      }
    }
    await taskService.transition(taskId, status, trigger: 'test');
  }

  group('core map execution', () {
    test('3-item array creates 3 tasks', () async {
      final collection = [
        {'id': 's01', 'name': 'Story 1'},
        {'id': 's02', 'name': 'Story 2'},
        {'id': 's03', 'name': 'Story 3'},
      ];
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Map test',
        steps: const [
          WorkflowStep(
            id: 'produce',
            name: 'Produce',
            prompts: ['produce'],
            contextOutputs: ['stories'],
          ),
          WorkflowStep(
            id: 'implement',
            name: 'Implement',
            prompts: ['Implement {{map.item}}'],
            mapOver: 'stories',
            maxParallel: 3,
            contextOutputs: ['results'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['stories'] = collection;

      final taskIds = <String>[];
      final sub = eventBus.on<TaskStatusChangedEvent>()
          .where((e) => e.newStatus == TaskStatus.queued)
          .listen((e) async {
            taskIds.add(e.taskId);
            await Future<void>.delayed(Duration.zero);
            await completeTask(e.taskId);
          });

      await executor.execute(run, definition, context, startFromStepIndex: 1);
      await sub.cancel();

      expect(taskIds.length, equals(3), reason: '3 tasks should be created, one per item');
    });

    test('results collected in index order (not completion order)', () async {
      final collection = ['item0', 'item1', 'item2'];
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Map test',
        steps: const [
          WorkflowStep(
            id: 'produce',
            name: 'Produce',
            prompts: ['p'],
            contextOutputs: ['items'],
          ),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['Process {{map.item}}'],
            mapOver: 'items',
            maxParallel: 3,
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = collection;

      // Complete tasks in reverse order (2, 1, 0).
      final taskIds = <String>[];
      final sub = eventBus.on<TaskStatusChangedEvent>()
          .where((e) => e.newStatus == TaskStatus.queued)
          .listen((e) async {
            taskIds.add(e.taskId);
          });

      // Run executor in background, manually complete tasks in reverse.
      final executorFuture = executor.execute(run, definition, context, startFromStepIndex: 1);

      // Wait for all 3 tasks to be created.
      await Future.doWhile(() async {
        await Future<void>.delayed(Duration.zero);
        return taskIds.length < 3;
      });
      await sub.cancel();

      // Complete in reverse order.
      for (final id in taskIds.reversed) {
        await completeTask(id);
        await Future<void>.delayed(Duration.zero);
      }
      await executorFuture;

      // Results should be index-ordered (3 slots, all null from default extraction).
      expect(context['mapped'], isA<List<Object?>>());
      expect((context['mapped'] as List).length, equals(3));
    });

    test('maxParallel: 1 (default) executes sequentially', () async {
      final collection = ['a', 'b', 'c'];
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Map test',
        steps: const [
          WorkflowStep(
            id: 'produce',
            name: 'Produce',
            prompts: ['p'],
            contextOutputs: ['items'],
          ),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['Process {{map.item}}'],
            mapOver: 'items',
            // maxParallel omitted → defaults to 1 (sequential)
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = collection;

      var maxConcurrent = 0;
      var concurrent = 0;
      final sub = eventBus.on<TaskStatusChangedEvent>()
          .where((e) => e.newStatus == TaskStatus.queued)
          .listen((e) async {
            concurrent++;
            if (concurrent > maxConcurrent) maxConcurrent = concurrent;
            await Future<void>.delayed(Duration.zero);
            await completeTask(e.taskId);
            concurrent--;
          });

      await executor.execute(run, definition, context, startFromStepIndex: 1);
      await sub.cancel();

      expect(maxConcurrent, equals(1), reason: 'maxParallel default is 1 (sequential)');
    });

    test('maxParallel: "unlimited" dispatches all items', () async {
      final collection = ['a', 'b', 'c', 'd', 'e'];
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Map test',
        steps: const [
          WorkflowStep(
            id: 'produce',
            name: 'Produce',
            prompts: ['p'],
            contextOutputs: ['items'],
          ),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['Process {{map.item}}'],
            mapOver: 'items',
            maxParallel: 'unlimited',
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = collection;

      final taskIds = <String>[];
      final sub = eventBus.on<TaskStatusChangedEvent>()
          .where((e) => e.newStatus == TaskStatus.queued)
          .listen((e) async {
            taskIds.add(e.taskId);
          });

      final executorFuture = executor.execute(run, definition, context, startFromStepIndex: 1);

      // Wait for all tasks to be queued.
      await Future.doWhile(() async {
        await Future<void>.delayed(Duration.zero);
        return taskIds.length < 5;
      });
      await sub.cancel();

      for (final id in taskIds) {
        await completeTask(id);
        await Future<void>.delayed(Duration.zero);
      }
      await executorFuture;

      expect(taskIds.length, equals(5));
    });
  });

  group('error handling', () {
    test('empty collection succeeds with empty result array', () async {
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Map test',
        steps: const [
          WorkflowStep(
            id: 'produce',
            name: 'Produce',
            prompts: ['p'],
            contextOutputs: ['items'],
          ),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['Process {{map.item}}'],
            mapOver: 'items',
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = <Object?>[];

      await executor.execute(run, definition, context, startFromStepIndex: 1);

      final updatedRun = await repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.completed));
      expect(context['mapped'], isA<List<Object?>>());
      expect((context['mapped'] as List).length, equals(0));
    });

    test('mapOver references null key → step fails', () async {
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Map test',
        steps: const [
          WorkflowStep(
            id: 'produce',
            name: 'Produce',
            prompts: ['p'],
            contextOutputs: ['items'],
          ),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['Process {{map.item}}'],
            mapOver: 'items',
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      // 'items' not set in context — should be null.
      final context = WorkflowContext();

      await executor.execute(run, definition, context, startFromStepIndex: 1);

      final updatedRun = await repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.paused));
      expect(updatedRun?.errorMessage, contains('null or missing'));
    });

    test('mapOver references non-List → step fails', () async {
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Map test',
        steps: const [
          WorkflowStep(
            id: 'produce',
            name: 'Produce',
            prompts: ['p'],
            contextOutputs: ['items'],
          ),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['Process {{map.item}}'],
            mapOver: 'items',
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = 'not a list';

      await executor.execute(run, definition, context, startFromStepIndex: 1);

      final updatedRun = await repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.paused));
      expect(updatedRun?.errorMessage, contains('not a List'));
    });

    test('collection exceeding maxItems → step fails with decomposition hint', () async {
      final collection = List.generate(5, (i) => 'item$i');
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Map test',
        steps: const [
          WorkflowStep(
            id: 'produce',
            name: 'Produce',
            prompts: ['p'],
            contextOutputs: ['items'],
          ),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['Process {{map.item}}'],
            mapOver: 'items',
            maxItems: 3,
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = collection;

      await executor.execute(run, definition, context, startFromStepIndex: 1);

      final updatedRun = await repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.paused));
      expect(updatedRun?.errorMessage, contains('maxItems'));
      expect(updatedRun?.errorMessage, contains('decompos'));
    });

    test('single iteration failure — others continue, result array has error object', () async {
      final collection = ['a', 'b', 'c'];
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Map test',
        steps: const [
          WorkflowStep(
            id: 'produce',
            name: 'Produce',
            prompts: ['p'],
            contextOutputs: ['items'],
          ),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['Process {{map.item}}'],
            mapOver: 'items',
            maxParallel: 3,
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = collection;

      // Fail the second task (index 1), succeed the others.
      final taskIds = <String>[];
      final sub = eventBus.on<TaskStatusChangedEvent>()
          .where((e) => e.newStatus == TaskStatus.queued)
          .listen((e) async {
            taskIds.add(e.taskId);
          });

      final executorFuture = executor.execute(run, definition, context, startFromStepIndex: 1);

      await Future.doWhile(() async {
        await Future<void>.delayed(Duration.zero);
        return taskIds.length < 3;
      });
      await sub.cancel();

      // Complete tasks: fail index 1, succeed others.
      for (var i = 0; i < taskIds.length; i++) {
        await completeTask(taskIds[i], status: i == 1 ? TaskStatus.failed : TaskStatus.accepted);
        await Future<void>.delayed(Duration.zero);
      }
      await executorFuture;

      // Step should be paused (has failures).
      final updatedRun = await repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.paused));

      // Results array is still stored in context before pausing.
      expect(context['mapped'], isA<List<Object?>>());
      final mapped = context['mapped'] as List;
      expect(mapped.length, equals(3));

      // Index 1 should be an error object.
      final errorResult = mapped[1] as Map;
      expect(errorResult['error'], isTrue);
      expect(errorResult, contains('message'));
    });

    test('circular dependency detected at step start → step fails', () async {
      final collection = [
        {'id': 's01', 'name': 'S1', 'dependencies': ['s02']},
        {'id': 's02', 'name': 'S2', 'dependencies': ['s01']},
      ];
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Dep test',
        steps: const [
          WorkflowStep(
            id: 'produce',
            name: 'Produce',
            prompts: ['p'],
            contextOutputs: ['stories'],
          ),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['Implement {{map.item}}'],
            mapOver: 'stories',
            contextOutputs: ['results'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['stories'] = collection;

      await executor.execute(run, definition, context, startFromStepIndex: 1);

      final updatedRun = await repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.paused));
      expect(updatedRun?.errorMessage, contains('Circular dependency'));
    });
  });

  group('dependency ordering', () {
    test('item with dependency not dispatched until dep completes', () async {
      final collection = [
        {'id': 's01', 'name': 'S1'},
        {'id': 's02', 'name': 'S2', 'dependencies': ['s01']},
      ];
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Dep test',
        steps: const [
          WorkflowStep(
            id: 'produce',
            name: 'Produce',
            prompts: ['p'],
            contextOutputs: ['stories'],
          ),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['Implement {{map.item}}'],
            mapOver: 'stories',
            maxParallel: 3,
            contextOutputs: ['results'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['stories'] = collection;

      // Track order of task creation.
      final taskIds = <String>[];
      final sub = eventBus.on<TaskStatusChangedEvent>()
          .where((e) => e.newStatus == TaskStatus.queued)
          .listen((e) async {
            taskIds.add(e.taskId);
          });

      final executorFuture = executor.execute(run, definition, context, startFromStepIndex: 1);

      // Wait for first task to be queued.
      await Future.doWhile(() async {
        await Future<void>.delayed(Duration.zero);
        return taskIds.isEmpty;
      });

      // At this point only s01 (index 0) should be dispatched.
      expect(taskIds.length, equals(1), reason: 's02 blocked by s01 dependency');

      // Complete s01.
      await completeTask(taskIds[0]);
      await Future<void>.delayed(Duration.zero);

      // Wait for s02 to be dispatched.
      await Future.doWhile(() async {
        await Future<void>.delayed(Duration.zero);
        return taskIds.length < 2;
      });
      await sub.cancel();

      // Complete s02.
      await completeTask(taskIds[1]);
      await executorFuture;

      expect(taskIds.length, equals(2));
      final updatedRun = await repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.completed));
    });

    test('items without id field are all independent (dispatched immediately)', () async {
      final collection = ['plain-a', 'plain-b', 'plain-c'];
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'No dep test',
        steps: const [
          WorkflowStep(
            id: 'produce',
            name: 'Produce',
            prompts: ['p'],
            contextOutputs: ['items'],
          ),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['{{map.item}}'],
            mapOver: 'items',
            maxParallel: 3,
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = collection;

      final taskIds = <String>[];
      final sub = eventBus.on<TaskStatusChangedEvent>()
          .where((e) => e.newStatus == TaskStatus.queued)
          .listen((e) async {
            taskIds.add(e.taskId);
          });

      final executorFuture = executor.execute(run, definition, context, startFromStepIndex: 1);

      // All 3 should be dispatched immediately.
      await Future.doWhile(() async {
        await Future<void>.delayed(Duration.zero);
        return taskIds.length < 3;
      });
      await sub.cancel();

      expect(taskIds.length, equals(3), reason: 'no deps means all dispatched at once');

      for (final id in taskIds) {
        await completeTask(id);
        await Future<void>.delayed(Duration.zero);
      }
      await executorFuture;
    });
  });

  group('events', () {
    test('MapIterationCompletedEvent fired per iteration with correct fields', () async {
      final collection = ['x', 'y'];
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Event test',
        steps: const [
          WorkflowStep(
            id: 'produce',
            name: 'Produce',
            prompts: ['p'],
            contextOutputs: ['items'],
          ),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['{{map.item}}'],
            mapOver: 'items',
            maxParallel: 2,
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = collection;

      final iterEvents = <MapIterationCompletedEvent>[];
      final iterSub = eventBus.on<MapIterationCompletedEvent>().listen(iterEvents.add);

      final sub = eventBus.on<TaskStatusChangedEvent>()
          .where((e) => e.newStatus == TaskStatus.queued)
          .listen((e) async {
            await Future<void>.delayed(Duration.zero);
            await completeTask(e.taskId);
          });

      await executor.execute(run, definition, context, startFromStepIndex: 1);
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
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'Event test',
        steps: const [
          WorkflowStep(
            id: 'produce',
            name: 'Produce',
            prompts: ['p'],
            contextOutputs: ['items'],
          ),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['{{map.item}}'],
            mapOver: 'items',
            maxParallel: 3,
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = collection;

      MapStepCompletedEvent? completedEvent;
      final completeSub = eventBus.on<MapStepCompletedEvent>()
          .listen((e) => completedEvent = e);

      final sub = eventBus.on<TaskStatusChangedEvent>()
          .where((e) => e.newStatus == TaskStatus.queued)
          .listen((e) async {
            await Future<void>.delayed(Duration.zero);
            await completeTask(e.taskId);
          });

      await executor.execute(run, definition, context, startFromStepIndex: 1);
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
  });

  group('maxParallel resolution', () {
    test('maxParallel as int is used directly', () async {
      final collection = List.generate(4, (i) => 'item$i');
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'maxParallel test',
        steps: const [
          WorkflowStep(
            id: 'produce',
            name: 'Produce',
            prompts: ['p'],
            contextOutputs: ['items'],
          ),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['{{map.item}}'],
            mapOver: 'items',
            maxParallel: 2,
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = collection;

      var maxConcurrent = 0;
      var concurrent = 0;
      final taskIds = <String>[];

      final sub = eventBus.on<TaskStatusChangedEvent>()
          .where((e) => e.newStatus == TaskStatus.queued)
          .listen((e) async {
            concurrent++;
            taskIds.add(e.taskId);
            if (concurrent > maxConcurrent) maxConcurrent = concurrent;
          });

      final executorFuture = executor.execute(run, definition, context, startFromStepIndex: 1);

      // Manually complete tasks to control concurrency observation.
      await Future.doWhile(() async {
        await Future<void>.delayed(Duration.zero);
        if (taskIds.isNotEmpty) {
          final id = taskIds.removeAt(0);
          await completeTask(id);
          concurrent--;
        }
        final updatedRun = await repository.getById('run-1');
        return updatedRun?.status == WorkflowRunStatus.running;
      });
      await sub.cancel();
      await executorFuture;

      expect(maxConcurrent, lessThanOrEqualTo(2));
    });

    test('invalid maxParallel string → step fails', () async {
      final collection = ['a', 'b'];
      final definition = WorkflowDefinition(
        name: 'test-wf',
        description: 'maxParallel test',
        steps: const [
          WorkflowStep(
            id: 'produce',
            name: 'Produce',
            prompts: ['p'],
            contextOutputs: ['items'],
          ),
          WorkflowStep(
            id: 'map',
            name: 'Map',
            prompts: ['{{map.item}}'],
            mapOver: 'items',
            maxParallel: 'not-a-number',
            contextOutputs: ['mapped'],
          ),
        ],
      );

      final run = makeRun(definition);
      await repository.insert(run);
      final context = WorkflowContext()..['items'] = collection;

      await executor.execute(run, definition, context, startFromStepIndex: 1);

      final updatedRun = await repository.getById('run-1');
      expect(updatedRun?.status, equals(WorkflowRunStatus.paused));
      expect(updatedRun?.errorMessage, contains('maxParallel'));
    });
  });
}
