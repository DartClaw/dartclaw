import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.parse('2026-03-10T10:00:00Z');

  group('TaskEventCreatedEvent', () {
    TaskEventCreatedEvent eventCreated({
      String taskId = 'task-1',
      String eventId = 'evt-1',
      String kind = 'statusChanged',
      Map<String, dynamic> details = const {},
    }) {
      return TaskEventCreatedEvent(taskId: taskId, eventId: eventId, kind: kind, details: details, timestamp: now);
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
  });
}
