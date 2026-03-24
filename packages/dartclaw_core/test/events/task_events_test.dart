import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  late EventBus bus;
  final now = DateTime.parse('2026-03-10T10:00:00Z');

  setUp(() => bus = EventBus());
  tearDown(() async {
    if (!bus.isDisposed) await bus.dispose();
  });

  TaskStatusChangedEvent statusEvent({
    String taskId = 'task-1',
    TaskStatus oldStatus = TaskStatus.queued,
    TaskStatus newStatus = TaskStatus.running,
    String trigger = 'system',
  }) {
    return TaskStatusChangedEvent(
      taskId: taskId,
      oldStatus: oldStatus,
      newStatus: newStatus,
      trigger: trigger,
      timestamp: now,
    );
  }

  TaskReviewReadyEvent reviewEvent({
    String taskId = 'task-1',
    int artifactCount = 2,
    List<String> artifactKinds = const ['data', 'document'],
  }) {
    return TaskReviewReadyEvent(
      taskId: taskId,
      artifactCount: artifactCount,
      artifactKinds: artifactKinds,
      timestamp: now,
    );
  }

  group('TaskLifecycleEvent filtering', () {
    test('on<TaskLifecycleEvent>() receives both event types', () async {
      final events = <TaskLifecycleEvent>[];
      bus.on<TaskLifecycleEvent>().listen(events.add);

      bus.fire(statusEvent());
      bus.fire(reviewEvent());
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(2));
      expect(events[0], isA<TaskStatusChangedEvent>());
      expect(events[1], isA<TaskReviewReadyEvent>());
    });

    test('on<TaskStatusChangedEvent>() filters correctly', () async {
      final events = <TaskStatusChangedEvent>[];
      bus.on<TaskStatusChangedEvent>().listen(events.add);

      bus.fire(statusEvent());
      bus.fire(reviewEvent());
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.single.newStatus, TaskStatus.running);
    });

    test('on<TaskReviewReadyEvent>() filters correctly', () async {
      final events = <TaskReviewReadyEvent>[];
      bus.on<TaskReviewReadyEvent>().listen(events.add);

      bus.fire(statusEvent());
      bus.fire(reviewEvent());
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.single.artifactCount, 2);
    });
  });

  group('TaskEventCreatedEvent', () {
    TaskEventCreatedEvent eventCreated({
      String taskId = 'task-1',
      String eventId = 'evt-1',
      String kind = 'statusChanged',
      Map<String, dynamic> details = const {},
    }) {
      return TaskEventCreatedEvent(
        taskId: taskId,
        eventId: eventId,
        kind: kind,
        details: details,
        timestamp: now,
      );
    }

    test('construction and field access', () {
      final event = eventCreated(
        taskId: 'task-X',
        eventId: 'evt-X',
        kind: 'toolCalled',
        details: {'name': 'bash', 'success': true},
      );
      expect(event.taskId, 'task-X');
      expect(event.eventId, 'evt-X');
      expect(event.kind, 'toolCalled');
      expect(event.details['name'], 'bash');
      expect(event.timestamp, now);
    });

    test('toString() includes taskId and kind', () {
      final event = eventCreated(taskId: 'task-Y', kind: 'error');
      expect(event.toString(), contains('task-Y'));
      expect(event.toString(), contains('error'));
    });

    test('on<TaskEventCreatedEvent>() filters correctly', () async {
      final events = <TaskEventCreatedEvent>[];
      bus.on<TaskEventCreatedEvent>().listen(events.add);

      bus.fire(statusEvent());
      bus.fire(eventCreated());
      bus.fire(reviewEvent());
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.single.kind, 'statusChanged');
    });

    test('on<TaskLifecycleEvent>() receives TaskEventCreatedEvent', () async {
      final events = <TaskLifecycleEvent>[];
      bus.on<TaskLifecycleEvent>().listen(events.add);

      bus.fire(eventCreated(kind: 'tokenUpdate'));
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.single, isA<TaskEventCreatedEvent>());
    });
  });
}
