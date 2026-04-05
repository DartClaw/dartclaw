import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  Task baseTask({int maxRetries = 0, int retryCount = 0}) => Task(
    id: 'task-1',
    title: 'Test task',
    description: 'Do something',
    type: TaskType.automation,
    status: TaskStatus.queued,
    createdAt: DateTime.parse('2026-04-01T10:00:00Z'),
    maxRetries: maxRetries,
    retryCount: retryCount,
  );

  group('Task retry fields', () {
    group('defaults', () {
      test('maxRetries defaults to 0', () {
        expect(baseTask().maxRetries, 0);
      });

      test('retryCount defaults to 0', () {
        expect(baseTask().retryCount, 0);
      });
    });

    group('copyWith', () {
      test('updates maxRetries', () {
        final updated = baseTask().copyWith(maxRetries: 3);
        expect(updated.maxRetries, 3);
      });

      test('updates retryCount', () {
        final updated = baseTask(maxRetries: 2).copyWith(retryCount: 1);
        expect(updated.retryCount, 1);
      });

      test('preserves existing values when not specified', () {
        final task = baseTask(maxRetries: 2, retryCount: 1);
        final updated = task.copyWith(title: 'New title');
        expect(updated.maxRetries, 2);
        expect(updated.retryCount, 1);
      });
    });

    group('toJson', () {
      test('omits maxRetries and retryCount when both are 0', () {
        final json = baseTask().toJson();
        expect(json.containsKey('maxRetries'), isFalse);
        expect(json.containsKey('retryCount'), isFalse);
      });

      test('includes maxRetries when non-zero', () {
        final json = baseTask(maxRetries: 2).toJson();
        expect(json['maxRetries'], 2);
      });

      test('includes retryCount when non-zero', () {
        final json = baseTask(maxRetries: 2, retryCount: 1).toJson();
        expect(json['retryCount'], 1);
      });

      test('round-trips maxRetries and retryCount', () {
        final original = baseTask(maxRetries: 3, retryCount: 2);
        final json = original.toJson();
        final restored = Task.fromJson(json);
        expect(restored.maxRetries, 3);
        expect(restored.retryCount, 2);
      });
    });

    group('fromJson', () {
      test('defaults to 0 when fields absent', () {
        final task = baseTask();
        final json = task.toJson()
          ..remove('maxRetries')
          ..remove('retryCount');
        final restored = Task.fromJson(json);
        expect(restored.maxRetries, 0);
        expect(restored.retryCount, 0);
      });

      test('parses maxRetries and retryCount from JSON', () {
        final task = baseTask();
        final json = task.toJson()
          ..['maxRetries'] = 5
          ..['retryCount'] = 3;
        final restored = Task.fromJson(json);
        expect(restored.maxRetries, 5);
        expect(restored.retryCount, 3);
      });
    });
  });

  group('TaskStatus retry transition', () {
    test('failed.canTransitionTo(queued) returns true', () {
      expect(TaskStatus.failed.canTransitionTo(TaskStatus.queued), isTrue);
    });

    test('failed.terminal still returns true', () {
      expect(TaskStatus.failed.terminal, isTrue);
    });

    test('failed.canTransitionTo only allows queued', () {
      for (final target in TaskStatus.values.where((s) => s != TaskStatus.queued)) {
        expect(
          TaskStatus.failed.canTransitionTo(target),
          isFalse,
          reason: 'failed should not transition to $target',
        );
      }
    });

    test('Task.transition from failed to queued succeeds', () {
      final failed = Task(
        id: 'task-1',
        title: 'Test',
        description: 'Test',
        type: TaskType.automation,
        status: TaskStatus.failed,
        createdAt: DateTime.parse('2026-04-01T10:00:00Z'),
        completedAt: DateTime.parse('2026-04-01T10:05:00Z'),
        maxRetries: 1,
      );
      final requeued = failed.transition(TaskStatus.queued);
      expect(requeued.status, TaskStatus.queued);
      expect(requeued.completedAt, isNull); // cleared on retry re-queue
    });
  });
}
