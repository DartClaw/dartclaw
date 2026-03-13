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

  group('TaskStatusChangedEvent', () {
    test('carries all fields', () {
      final event = statusEvent();

      expect(event.taskId, 'task-1');
      expect(event.oldStatus, TaskStatus.queued);
      expect(event.newStatus, TaskStatus.running);
      expect(event.trigger, 'system');
      expect(event.timestamp, now);
    });

    test('toString returns readable representation', () {
      expect(statusEvent().toString(), 'TaskStatusChangedEvent(task: task-1, queued -> running, trigger: system)');
    });
  });

  group('TaskReviewReadyEvent', () {
    test('carries all fields', () {
      final event = reviewEvent();

      expect(event.taskId, 'task-1');
      expect(event.artifactCount, 2);
      expect(event.artifactKinds, ['data', 'document']);
      expect(event.timestamp, now);
    });

    test('toString returns readable representation', () {
      expect(
        reviewEvent().toString(),
        'TaskReviewReadyEvent(task: task-1, artifacts: 2, kinds: [data, document])',
      );
    });
  });

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
}
