import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('TaskStatus — push-back transition (review → running)', () {
    test('review allows transition to running', () {
      final task = Task(
        id: 'task-1',
        title: 'Test task',
        description: 'desc',
        type: TaskType.research,
        createdAt: DateTime.utc(2026, 3, 21),
      );
      final queued = task.transition(TaskStatus.queued);
      final running = queued.transition(TaskStatus.running);
      final review = running.transition(TaskStatus.review);

      // D19: review → running (push-back)
      expect(() => review.transition(TaskStatus.running), returnsNormally);
      expect(review.transition(TaskStatus.running).status, TaskStatus.running);
    });

    test('review still allows transition to accepted', () {
      final task = Task(
        id: 'task-1',
        title: 'Test task',
        description: 'desc',
        type: TaskType.research,
        createdAt: DateTime.utc(2026, 3, 21),
      );
      final review = task
          .transition(TaskStatus.queued)
          .transition(TaskStatus.running)
          .transition(TaskStatus.review);

      expect(() => review.transition(TaskStatus.accepted), returnsNormally);
    });

    test('review still allows transition to rejected', () {
      final task = Task(
        id: 'task-1',
        title: 'Test task',
        description: 'desc',
        type: TaskType.research,
        createdAt: DateTime.utc(2026, 3, 21),
      );
      final review = task
          .transition(TaskStatus.queued)
          .transition(TaskStatus.running)
          .transition(TaskStatus.review);

      expect(() => review.transition(TaskStatus.rejected), returnsNormally);
    });

    test('running is not terminal (can be pushed back and transition again)', () {
      expect(TaskStatus.running.terminal, isFalse);
    });

    test('accepted is terminal', () {
      expect(TaskStatus.accepted.terminal, isTrue);
    });

    test('rejected is terminal', () {
      expect(TaskStatus.rejected.terminal, isTrue);
    });
  });
}
