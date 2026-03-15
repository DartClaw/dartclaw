import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  group('TestEventBus', () {
    test('captures fired events and filters by type', () {
      final bus = TestEventBus();
      final created = SessionCreatedEvent(
        sessionId: 'session-1',
        sessionType: 'user',
        timestamp: DateTime.parse('2026-03-10T10:00:00Z'),
      );
      final changed = TaskStatusChangedEvent(
        taskId: 'task-1',
        oldStatus: TaskStatus.draft,
        newStatus: TaskStatus.queued,
        trigger: 'test',
        timestamp: DateTime.parse('2026-03-10T10:05:00Z'),
      );

      bus.fire(created);
      bus.fire(changed);

      expect(bus.firedEvents, [created, changed]);
      expect(bus.eventsOfType<SessionCreatedEvent>(), [created]);
      expect(bus.eventsOfType<TaskStatusChangedEvent>(), [changed]);
    });

    test('expectEvent waits for the next matching event', () async {
      final bus = TestEventBus();
      final eventFuture = bus.expectEvent<TaskStatusChangedEvent>();
      final event = TaskStatusChangedEvent(
        taskId: 'task-1',
        oldStatus: TaskStatus.queued,
        newStatus: TaskStatus.running,
        trigger: 'scheduler',
        timestamp: DateTime.parse('2026-03-10T10:10:00Z'),
      );

      bus.fire(event);

      await expectLater(eventFuture, completion(event));
    });

    test('clear removes captured history', () {
      final bus = TestEventBus();
      bus.fire(
        SessionCreatedEvent(
          sessionId: 'session-1',
          sessionType: 'user',
          timestamp: DateTime.parse('2026-03-10T10:00:00Z'),
        ),
      );

      bus.clear();

      expect(bus.firedEvents, isEmpty);
    });
  });
}
