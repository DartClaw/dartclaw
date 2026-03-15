import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  Task createTask({
    TaskStatus status = TaskStatus.draft,
    TaskType type = TaskType.coding,
    Map<String, dynamic> configJson = const {},
    Map<String, dynamic>? worktreeJson,
    DateTime? startedAt,
    DateTime? completedAt,
  }) {
    return Task(
      id: 'task-1',
      title: 'Write task model',
      description: 'Implement the task domain model',
      type: type,
      status: status,
      goalId: 'goal-1',
      acceptanceCriteria: 'Tests pass',
      sessionId: 'session-1',
      configJson: configJson,
      worktreeJson: worktreeJson,
      createdAt: DateTime.parse('2026-03-10T10:00:00Z'),
      startedAt: startedAt,
      completedAt: completedAt,
    );
  }

  group('Task', () {
    group('copyWith', () {
      test('copies with changed title', () {
        final task = createTask();
        final updated = task.copyWith(title: 'New title');

        expect(updated.title, 'New title');
        expect(updated.id, task.id);
        expect(updated.description, task.description);
        expect(updated.status, task.status);
      });

      test('copies with changed status', () {
        final task = createTask();
        final updated = task.copyWith(status: TaskStatus.queued);

        expect(updated.status, TaskStatus.queued);
        expect(updated.title, task.title);
        expect(updated.createdAt, task.createdAt);
      });

      test('preserves configJson by default', () {
        final task = createTask(configJson: const {'pushBackCount': 1});
        final updated = task.copyWith(title: 'Updated');

        expect(updated.configJson, {'pushBackCount': 1});
      });

      test('can clear nullable fields', () {
        final task = createTask(
          worktreeJson: const {'path': '/tmp/worktree'},
          startedAt: DateTime.parse('2026-03-10T10:05:00Z'),
          completedAt: DateTime.parse('2026-03-10T10:15:00Z'),
        );
        final updated = task.copyWith(
          goalId: null,
          acceptanceCriteria: null,
          sessionId: null,
          worktreeJson: null,
          startedAt: null,
          completedAt: null,
        );

        expect(updated.goalId, isNull);
        expect(updated.acceptanceCriteria, isNull);
        expect(updated.sessionId, isNull);
        expect(updated.worktreeJson, isNull);
        expect(updated.startedAt, isNull);
        expect(updated.completedAt, isNull);
      });
    });

    group('transition', () {
      test('draft to queued updates status', () {
        final task = createTask();
        final updated = task.transition(TaskStatus.queued, now: DateTime.parse('2026-03-10T10:05:00Z'));

        expect(updated.status, TaskStatus.queued);
        expect(updated.startedAt, isNull);
        expect(updated.completedAt, isNull);
      });

      test('queued to running sets startedAt', () {
        final task = createTask(status: TaskStatus.queued);
        final timestamp = DateTime.parse('2026-03-10T10:05:00Z');
        final updated = task.transition(TaskStatus.running, now: timestamp);

        expect(updated.status, TaskStatus.running);
        expect(updated.startedAt, timestamp);
        expect(updated.completedAt, isNull);
      });

      test('running to review does not set completedAt', () {
        final startedAt = DateTime.parse('2026-03-10T10:05:00Z');
        final task = createTask(status: TaskStatus.running, startedAt: startedAt);
        final updated = task.transition(TaskStatus.review, now: DateTime.parse('2026-03-10T10:10:00Z'));

        expect(updated.status, TaskStatus.review);
        expect(updated.startedAt, startedAt);
        expect(updated.completedAt, isNull);
      });

      test('review to accepted sets completedAt', () {
        final task = createTask(status: TaskStatus.review, startedAt: DateTime.parse('2026-03-10T10:05:00Z'));
        final timestamp = DateTime.parse('2026-03-10T10:15:00Z');
        final updated = task.transition(TaskStatus.accepted, now: timestamp);

        expect(updated.status, TaskStatus.accepted);
        expect(updated.completedAt, timestamp);
      });

      test('review to queued increments pushBackCount', () {
        final task = createTask(
          status: TaskStatus.review,
          configJson: const {'pushBackCount': 1},
          startedAt: DateTime.parse('2026-03-10T10:05:00Z'),
          completedAt: DateTime.parse('2026-03-10T10:10:00Z'),
        );
        final updated = task.transition(TaskStatus.queued, now: DateTime.parse('2026-03-10T10:12:00Z'));
        final updatedAgain = updated
            .transition(TaskStatus.running, now: DateTime.parse('2026-03-10T10:13:00Z'))
            .transition(TaskStatus.review, now: DateTime.parse('2026-03-10T10:14:00Z'))
            .transition(TaskStatus.queued, now: DateTime.parse('2026-03-10T10:15:00Z'));

        expect(updated.configJson['pushBackCount'], 2);
        expect(updatedAgain.configJson['pushBackCount'], 3);
      });

      test('review to queued clears completedAt', () {
        final task = createTask(status: TaskStatus.review, completedAt: DateTime.parse('2026-03-10T10:10:00Z'));
        final updated = task.transition(TaskStatus.queued, now: DateTime.parse('2026-03-10T10:11:00Z'));

        expect(updated.completedAt, isNull);
      });

      test('interrupted to queued preserves startedAt', () {
        final startedAt = DateTime.parse('2026-03-10T10:05:00Z');
        final task = createTask(
          status: TaskStatus.interrupted,
          startedAt: startedAt,
          completedAt: DateTime.parse('2026-03-10T10:09:00Z'),
        );
        final updated = task.transition(TaskStatus.queued, now: DateTime.parse('2026-03-10T10:10:00Z'));

        expect(updated.startedAt, startedAt);
        expect(updated.completedAt, isNull);
      });

      test('interrupted to queued to running refreshes startedAt on resume', () {
        final initialStartedAt = DateTime.parse('2026-03-10T10:05:00Z');
        final requeuedAt = DateTime.parse('2026-03-10T10:10:00Z');
        final resumedAt = DateTime.parse('2026-03-10T10:12:00Z');
        final task = createTask(
          status: TaskStatus.interrupted,
          startedAt: initialStartedAt,
          completedAt: DateTime.parse('2026-03-10T10:09:00Z'),
        );

        final requeued = task.transition(TaskStatus.queued, now: requeuedAt);
        final resumed = requeued.transition(TaskStatus.running, now: resumedAt);

        expect(requeued.startedAt, initialStartedAt);
        expect(requeued.completedAt, isNull);
        expect(resumed.startedAt, resumedAt);
        expect(resumed.completedAt, isNull);
      });

      test('running to failed sets completedAt', () {
        final task = createTask(status: TaskStatus.running);
        final timestamp = DateTime.parse('2026-03-10T10:10:00Z');
        final updated = task.transition(TaskStatus.failed, now: timestamp);

        expect(updated.status, TaskStatus.failed);
        expect(updated.completedAt, timestamp);
      });

      test('running to cancelled sets completedAt', () {
        final task = createTask(status: TaskStatus.running);
        final timestamp = DateTime.parse('2026-03-10T10:10:00Z');
        final updated = task.transition(TaskStatus.cancelled, now: timestamp);

        expect(updated.status, TaskStatus.cancelled);
        expect(updated.completedAt, timestamp);
      });

      test('invalid transition throws StateError', () {
        final task = createTask();

        expect(() => task.transition(TaskStatus.running), throwsStateError);
      });

      test('transition from terminal throws StateError', () {
        final task = createTask(status: TaskStatus.accepted);

        expect(() => task.transition(TaskStatus.queued), throwsStateError);
      });

    });

    group('JSON serialization', () {
      test('round-trips through toJson and fromJson', () {
        final task = createTask(
          status: TaskStatus.review,
          type: TaskType.research,
          configJson: const {'pushBackCount': 2, 'budget': 1000},
          worktreeJson: const {'path': '/tmp/worktree'},
          startedAt: DateTime.parse('2026-03-10T10:05:00Z'),
          completedAt: DateTime.parse('2026-03-10T10:15:00Z'),
        );
        final restored = Task.fromJson(task.toJson());

        expect(restored.toJson(), equals(task.toJson()));
      });

      test('toJson omits null optional fields', () {
        final task = Task(
          id: 'task-1',
          title: 'Minimal task',
          description: 'Describe the work',
          type: TaskType.custom,
          createdAt: DateTime.parse('2026-03-10T10:00:00Z'),
        );
        final json = task.toJson();

        expect(json.containsKey('goalId'), isFalse);
        expect(json.containsKey('acceptanceCriteria'), isFalse);
        expect(json.containsKey('sessionId'), isFalse);
        expect(json.containsKey('worktreeJson'), isFalse);
        expect(json.containsKey('startedAt'), isFalse);
        expect(json.containsKey('completedAt'), isFalse);
      });

      test('fromJson defaults configJson to empty map when null', () {
        final task = Task.fromJson({
          'id': 'task-1',
          'title': 'Task',
          'description': 'Describe the work',
          'type': 'coding',
          'status': 'draft',
          'configJson': null,
          'createdAt': '2026-03-10T10:00:00Z',
        });

        expect(task.configJson, isEmpty);
      });

      test('fromJson throws FormatException when status is missing', () {
        expect(
          () => Task.fromJson({
            'id': 'task-1',
            'title': 'Task',
            'description': 'Describe the work',
            'type': 'coding',
            'configJson': const {},
            'createdAt': '2026-03-10T10:00:00Z',
          }),
          throwsFormatException,
        );
      });

      test('fromJson parses status and type enums', () {
        final task = Task.fromJson({
          'id': 'task-1',
          'title': 'Task',
          'description': 'Describe the work',
          'type': 'automation',
          'status': 'running',
          'configJson': const {},
          'createdAt': '2026-03-10T10:00:00Z',
        });

        expect(task.type, TaskType.automation);
        expect(task.status, TaskStatus.running);
      });
    });
  });
}
