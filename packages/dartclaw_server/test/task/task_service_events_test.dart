import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/task/task_event_recorder.dart';
import 'package:dartclaw_server/src/task/task_service.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late InMemoryTaskRepository repo;
  late TestEventBus eventBus;
  late TaskService service;

  setUp(() {
    repo = InMemoryTaskRepository();
    eventBus = TestEventBus();
    service = TaskService(repo, eventBus: eventBus);
  });

  tearDown(() async {
    await eventBus.dispose();
    await service.dispose();
  });

  Task makeTask({String id = 'task-1', TaskStatus status = TaskStatus.draft}) {
    return Task(
      id: id,
      title: 'Test task',
      description: 'Do the work',
      type: TaskType.coding,
      status: status,
      configJson: const {},
      createdAt: DateTime.parse('2026-03-10T10:00:00Z'),
    );
  }

  group('create()', () {
    test('autoStart:false does not fire any events', () async {
      await service.create(
        id: 'task-1',
        title: 'Draft',
        description: 'desc',
        type: TaskType.research,
        autoStart: false,
      );

      expect(eventBus.firedEvents, isEmpty);
    });

    test('autoStart:true fires TaskStatusChangedEvent for draft->queued', () async {
      final now = DateTime.parse('2026-03-10T10:00:00Z');

      await service.create(
        id: 'task-1',
        title: 'Auto start',
        description: 'desc',
        type: TaskType.coding,
        autoStart: true,
        now: now,
        trigger: 'user',
      );

      final events = eventBus.eventsOfType<TaskStatusChangedEvent>();
      expect(events, hasLength(1));
      expect(events.single.taskId, 'task-1');
      expect(events.single.oldStatus, TaskStatus.draft);
      expect(events.single.newStatus, TaskStatus.queued);
      expect(events.single.trigger, 'user');
      expect(events.single.timestamp, now);
    });

    test('autoStart:true uses default trigger "system"', () async {
      await service.create(
        id: 'task-1',
        title: 'Auto start',
        description: 'desc',
        type: TaskType.coding,
        autoStart: true,
      );

      final events = eventBus.eventsOfType<TaskStatusChangedEvent>();
      expect(events.single.trigger, 'system');
    });
  });

  group('transition()', () {
    test('fires TaskStatusChangedEvent with correct fields', () async {
      await repo.insert(makeTask(status: TaskStatus.queued));
      final now = DateTime.parse('2026-03-10T10:05:00Z');

      await service.transition('task-1', TaskStatus.running, now: now, trigger: 'executor');

      final events = eventBus.eventsOfType<TaskStatusChangedEvent>();
      expect(events, hasLength(1));
      expect(events.single.taskId, 'task-1');
      expect(events.single.oldStatus, TaskStatus.queued);
      expect(events.single.newStatus, TaskStatus.running);
      expect(events.single.trigger, 'executor');
      expect(events.single.timestamp, now);
    });

    test('fires event with default trigger "system"', () async {
      await repo.insert(makeTask(status: TaskStatus.queued));

      await service.transition('task-1', TaskStatus.running);

      final events = eventBus.eventsOfType<TaskStatusChangedEvent>();
      expect(events.single.trigger, 'system');
    });

    test('transition to review fires both TaskStatusChangedEvent and TaskReviewReadyEvent', () async {
      await repo.insert(makeTask(status: TaskStatus.running));

      await service.transition('task-1', TaskStatus.review, trigger: 'system');
      // Pump the async artifact lookup in _fireReviewReadyEvent.
      await Future<void>.delayed(Duration.zero);

      final statusEvents = eventBus.eventsOfType<TaskStatusChangedEvent>();
      final reviewEvents = eventBus.eventsOfType<TaskReviewReadyEvent>();
      expect(statusEvents, hasLength(1));
      expect(statusEvents.single.newStatus, TaskStatus.review);
      expect(reviewEvents, hasLength(1));
      expect(reviewEvents.single.taskId, 'task-1');
      expect(reviewEvents.single.artifactCount, 0);
      expect(reviewEvents.single.artifactKinds, isEmpty);
    });

    test('TaskReviewReadyEvent includes artifact count and kinds', () async {
      await repo.insert(makeTask(status: TaskStatus.running));
      await repo.insertArtifact(
        TaskArtifact(
          id: 'art-1',
          taskId: 'task-1',
          name: 'patch.diff',
          kind: ArtifactKind.diff,
          path: '/tmp/patch.diff',
          createdAt: DateTime.parse('2026-03-10T10:05:00Z'),
        ),
      );
      await repo.insertArtifact(
        TaskArtifact(
          id: 'art-2',
          taskId: 'task-1',
          name: 'notes.md',
          kind: ArtifactKind.document,
          path: '/tmp/notes.md',
          createdAt: DateTime.parse('2026-03-10T10:05:00Z'),
        ),
      );

      await service.transition('task-1', TaskStatus.review);
      await Future<void>.delayed(Duration.zero);

      final reviewEvents = eventBus.eventsOfType<TaskReviewReadyEvent>();
      expect(reviewEvents.single.artifactCount, 2);
      expect(reviewEvents.single.artifactKinds, containsAll(['diff', 'document']));
    });

    test('non-review transitions do not fire TaskReviewReadyEvent', () async {
      await repo.insert(makeTask(status: TaskStatus.queued));

      await service.transition('task-1', TaskStatus.running);
      await Future<void>.delayed(Duration.zero);

      expect(eventBus.eventsOfType<TaskReviewReadyEvent>(), isEmpty);
    });

    test('failed transition (state error) does not fire any events', () async {
      await repo.insert(makeTask(status: TaskStatus.draft));

      // draft -> running is invalid
      await expectLater(service.transition('task-1', TaskStatus.running), throwsA(isA<StateError>()));

      expect(eventBus.firedEvents, isEmpty);
    });
  });

  group('no EventBus', () {
    test('transition without EventBus does not throw', () async {
      final serviceNoEvents = TaskService(repo);
      addTearDown(serviceNoEvents.dispose);
      await repo.insert(makeTask(status: TaskStatus.queued));

      final result = await serviceNoEvents.transition('task-1', TaskStatus.running);

      expect(result.status, TaskStatus.running);
      expect(eventBus.firedEvents, isEmpty);
    });
  });

  group('TaskEventRecorder integration', () {
    late Database db;
    late TaskEventService eventService;
    late TaskEventRecorder recorder;

    setUp(() {
      db = openTaskDbInMemory();
      eventService = TaskEventService(db);
      recorder = TaskEventRecorder(eventService: eventService);
    });

    tearDown(() {
      db.close();
    });

    test('transition() records statusChanged event via eventRecorder', () async {
      final serviceWithRecorder = TaskService(repo, eventBus: eventBus, eventRecorder: recorder);
      addTearDown(serviceWithRecorder.dispose);

      await repo.insert(makeTask(status: TaskStatus.queued));
      await serviceWithRecorder.transition('task-1', TaskStatus.running, trigger: 'system');

      final events = eventService.listForTask('task-1');
      expect(events, hasLength(1));
      expect(events[0].kind.name, 'statusChanged');
      expect(events[0].details['oldStatus'], 'queued');
      expect(events[0].details['newStatus'], 'running');
      expect(events[0].details['trigger'], 'system');
    });

    test('create(autoStart: true) records statusChanged event via eventRecorder', () async {
      final serviceWithRecorder = TaskService(repo, eventBus: eventBus, eventRecorder: recorder);
      addTearDown(serviceWithRecorder.dispose);

      await serviceWithRecorder.create(
        id: 'task-2',
        title: 'Auto start',
        description: 'desc',
        type: TaskType.coding,
        autoStart: true,
        trigger: 'user',
      );

      final events = eventService.listForTask('task-2');
      expect(events, hasLength(1));
      expect(events[0].kind.name, 'statusChanged');
      expect(events[0].details['oldStatus'], 'draft');
      expect(events[0].details['trigger'], 'user');
    });

    test('null eventRecorder does not affect existing behavior', () async {
      final serviceNoRecorder = TaskService(repo, eventBus: eventBus);
      addTearDown(serviceNoRecorder.dispose);

      await repo.insert(makeTask(status: TaskStatus.queued));
      final result = await serviceNoRecorder.transition('task-1', TaskStatus.running);
      expect(result.status, TaskStatus.running);
    });
  });
}
