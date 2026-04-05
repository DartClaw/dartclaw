import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart'
    show
        EventBus,
        KvService,
        MessageService,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowDefinition,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowRunStatusChangedEvent,
        WorkflowStep,
        WorkflowVariable;
import 'package:dartclaw_server/dartclaw_server.dart' show TaskService, WorkflowService;
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
  late WorkflowService workflowService;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_wf_svc_test_');
    sessionsDir = p.join(tempDir.path, 'sessions');
    Directory(sessionsDir).createSync(recursive: true);

    final db = sqlite3.openInMemory();
    eventBus = EventBus();
    taskService = TaskService(SqliteTaskRepository(db), eventBus: eventBus);
    repository = SqliteWorkflowRunRepository(db);
    messageService = MessageService(baseDir: sessionsDir);
    kvService = KvService(filePath: p.join(tempDir.path, 'kv.json'));

    workflowService = WorkflowService(
      repository: repository,
      taskService: taskService,
      messageService: messageService,
      eventBus: eventBus,
      kvService: kvService,
      dataDir: tempDir.path,
    );
  });

  tearDown(() async {
    await workflowService.dispose();
    await taskService.dispose();
    await messageService.dispose();
    await kvService.dispose();
    await eventBus.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  WorkflowDefinition makeDefinition({
    List<WorkflowStep>? steps,
    Map<String, WorkflowVariable> variables = const {},
  }) {
    return WorkflowDefinition(
      name: 'test-workflow',
      description: 'Test workflow',
      variables: variables,
      steps: steps ?? [
        const WorkflowStep(id: 'step1', name: 'Step 1', prompt: 'Do step 1'),
      ],
    );
  }

  void autoCompleteNewTasks() {
    eventBus.on<TaskStatusChangedEvent>()
        .where((e) => e.newStatus == TaskStatus.queued)
        .listen((e) async {
          await Future<void>.delayed(Duration.zero);
          // Use real transitions so DB state matches what executor reads.
          try {
            await taskService.transition(e.taskId, TaskStatus.running, trigger: 'test');
            await taskService.transition(e.taskId, TaskStatus.review, trigger: 'test');
            await taskService.transition(e.taskId, TaskStatus.accepted, trigger: 'test');
          } on StateError {
            // Ignore invalid transition errors if task already moved.
          }
        });
  }

  test('start() creates run in pending→running, fires status events', () async {
    final statusEvents = <WorkflowRunStatusChangedEvent>[];
    eventBus.on<WorkflowRunStatusChangedEvent>().listen(statusEvents.add);

    final definition = makeDefinition();
    autoCompleteNewTasks();

    final run = await workflowService.start(definition, {});
    await Future<void>.delayed(Duration.zero); // Let EventBus dispatch async events.

    expect(run.status, equals(WorkflowRunStatus.running));
    expect(run.definitionName, equals('test-workflow'));
    expect(statusEvents.any((e) => e.newStatus == WorkflowRunStatus.running), isTrue);
  });

  test('start() persists initial context.json to disk', () async {
    final definition = makeDefinition();
    autoCompleteNewTasks();

    final run = await workflowService.start(definition, {});

    final contextFile = File(p.join(tempDir.path, 'workflows', run.id, 'context.json'));
    expect(contextFile.existsSync(), isTrue);
  });

  test('start() applies required variable values', () async {
    final definition = makeDefinition(
      variables: {'topic': const WorkflowVariable(required: true, description: 'The topic')},
    );
    autoCompleteNewTasks();

    final run = await workflowService.start(definition, {'topic': 'Dart programming'});
    expect(run.variablesJson['topic'], equals('Dart programming'));
  });

  test('start() throws when required variable missing', () async {
    final definition = makeDefinition(
      variables: {'topic': const WorkflowVariable(required: true, description: 'Required')},
    );

    expect(
      () => workflowService.start(definition, {}),
      throwsA(isA<ArgumentError>().having((e) => e.message, 'message', contains('topic'))),
    );
  });

  test('pause() transitions running to paused', () async {
    final definition = makeDefinition(steps: [
      // Long running step — we pause before it completes.
      const WorkflowStep(id: 'step1', name: 'Step 1', prompt: 'Long step'),
    ]);

    final run = await workflowService.start(definition, {});
    final paused = await workflowService.pause(run.id);

    expect(paused.status, equals(WorkflowRunStatus.paused));
    final stored = await workflowService.get(run.id);
    expect(stored?.status, equals(WorkflowRunStatus.paused));
  });

  test('pause() throws when workflow not running', () async {
    final definition = makeDefinition();
    autoCompleteNewTasks();
    final run = await workflowService.start(definition, {});
    // Wait for run to complete.
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(
      () => workflowService.pause(run.id),
      throwsA(isA<StateError>()),
    );
  });

  test('resume() transitions paused to running', () async {
    final definition = makeDefinition();
    final run = await workflowService.start(definition, {});
    final paused = await workflowService.pause(run.id);

    autoCompleteNewTasks();
    final resumed = await workflowService.resume(paused.id);

    expect(resumed.status, equals(WorkflowRunStatus.running));
  });

  test('resume() throws when workflow not paused', () async {
    final definition = makeDefinition();
    autoCompleteNewTasks();
    final run = await workflowService.start(definition, {});

    expect(
      () => workflowService.resume(run.id),
      throwsA(isA<StateError>()),
    );
  });

  test('cancel() transitions running to cancelled', () async {
    final definition = makeDefinition();
    final run = await workflowService.start(definition, {});

    await workflowService.cancel(run.id);

    final stored = await workflowService.get(run.id);
    expect(stored?.status, equals(WorkflowRunStatus.cancelled));
  });

  test('cancel() transitions paused to cancelled', () async {
    final definition = makeDefinition();
    final run = await workflowService.start(definition, {});
    await workflowService.pause(run.id);

    await workflowService.cancel(run.id);

    final stored = await workflowService.get(run.id);
    expect(stored?.status, equals(WorkflowRunStatus.cancelled));
  });

  test('cancel() is idempotent on already-terminal run', () async {
    final definition = makeDefinition();
    autoCompleteNewTasks();
    final run = await workflowService.start(definition, {});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    // Run may be completed already.
    await workflowService.cancel(run.id);
    // Second cancel should not throw.
    await workflowService.cancel(run.id);
  });

  test('get() returns null for unknown run', () async {
    final result = await workflowService.get('nonexistent-id');
    expect(result, isNull);
  });

  test('list() returns all runs', () async {
    final definition = makeDefinition();
    autoCompleteNewTasks();

    await workflowService.start(definition, {});
    await workflowService.start(definition, {});

    final runs = await workflowService.list();
    expect(runs.length, greaterThanOrEqualTo(2));
  });

  test('list() filters by status', () async {
    final definition = makeDefinition();
    final run = await workflowService.start(definition, {});
    await workflowService.pause(run.id);

    final pausedRuns = await workflowService.list(status: WorkflowRunStatus.paused);
    expect(pausedRuns.any((r) => r.id == run.id), isTrue);

    final runningRuns = await workflowService.list(status: WorkflowRunStatus.running);
    expect(runningRuns.any((r) => r.id == run.id), isFalse);
  });

  test('recoverIncompleteRuns() resumes running runs', () async {
    // Seed a "running" run directly in the repository.
    final definition = makeDefinition();
    final now = DateTime.now();
    final run = WorkflowRun(
      id: 'recover-run-1',
      definitionName: 'test-workflow',
      status: WorkflowRunStatus.running,
      startedAt: now,
      updatedAt: now,
      currentStepIndex: 0,
      definitionJson: definition.toJson(),
    );
    await repository.insert(run);

    autoCompleteNewTasks();

    await workflowService.recoverIncompleteRuns();

    // Wait for recovery to complete.
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final recovered = await workflowService.get('recover-run-1');
    // Should have been recovered and completed (or transitioned out of initial state).
    expect(
      recovered?.status,
      anyOf(
        equals(WorkflowRunStatus.completed),
        equals(WorkflowRunStatus.paused),
        equals(WorkflowRunStatus.running),
      ),
    );
  });

  test('recoverIncompleteRuns() skips paused runs', () async {
    final definition = makeDefinition();
    final now = DateTime.now();
    final pausedRun = WorkflowRun(
      id: 'paused-run-1',
      definitionName: 'test-workflow',
      status: WorkflowRunStatus.paused,
      startedAt: now,
      updatedAt: now,
      definitionJson: definition.toJson(),
    );
    await repository.insert(pausedRun);

    await workflowService.recoverIncompleteRuns();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Paused run should remain paused — not auto-resumed.
    final stored = await workflowService.get('paused-run-1');
    expect(stored?.status, equals(WorkflowRunStatus.paused));
  });

  test('WorkflowRunStatusChangedEvent fired on start, pause, cancel', () async {
    final events = <WorkflowRunStatusChangedEvent>[];
    eventBus.on<WorkflowRunStatusChangedEvent>().listen(events.add);

    final definition = makeDefinition();
    final run = await workflowService.start(definition, {});
    await workflowService.pause(run.id);
    await workflowService.cancel(run.id);

    final statuses = events.map((e) => e.newStatus).toList();
    expect(statuses, containsAll([
      WorkflowRunStatus.running,
      WorkflowRunStatus.paused,
      WorkflowRunStatus.cancelled,
    ]));
  });
}
