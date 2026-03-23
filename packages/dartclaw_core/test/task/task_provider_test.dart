import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

Task _task({String? provider}) {
  return Task(
    id: 'task-1',
    title: 'Provider-aware task',
    description: 'Exercise provider persistence and copying.',
    type: TaskType.research,
    status: TaskStatus.draft,
    goalId: 'goal-1',
    acceptanceCriteria: 'Keep provider intact',
    sessionId: 'session-1',
    configJson: const {'priority': 'high'},
    worktreeJson: const {'path': '/tmp/worktree'},
    createdAt: DateTime.parse('2026-03-10T10:00:00Z'),
    startedAt: DateTime.parse('2026-03-10T10:05:00Z'),
    completedAt: DateTime.parse('2026-03-10T10:10:00Z'),
    createdBy: 'operator',
    provider: provider,
  );
}

void main() {
  group('Task.provider', () {
    test('copyWith can set and clear provider', () {
      final task = _task();

      final updated = task.copyWith(provider: 'codex');
      final cleared = updated.copyWith(provider: null);

      expect(updated.provider, 'codex');
      expect(cleared.provider, isNull);
    });

    test('toJson includes provider when non-null and omits it when null', () {
      final taskWithProvider = _task(provider: 'codex');
      final taskWithoutProvider = _task();

      expect(taskWithProvider.toJson()['provider'], 'codex');
      expect(taskWithoutProvider.toJson().containsKey('provider'), isFalse);
    });

    test('fromJson parses provider and defaults to null when absent', () {
      final task = Task.fromJson({
        'id': 'task-1',
        'title': 'Provider-aware task',
        'description': 'Exercise provider persistence and copying.',
        'type': 'research',
        'status': 'draft',
        'goalId': 'goal-1',
        'acceptanceCriteria': 'Keep provider intact',
        'sessionId': 'session-1',
        'configJson': {'priority': 'high'},
        'worktreeJson': {'path': '/tmp/worktree'},
        'createdAt': '2026-03-10T10:00:00Z',
        'startedAt': '2026-03-10T10:05:00Z',
        'completedAt': '2026-03-10T10:10:00Z',
        'createdBy': 'operator',
        'provider': 'codex',
      });
      final withoutProvider = Task.fromJson({
        'id': 'task-2',
        'title': 'No provider',
        'description': 'Provider defaults to null.',
        'type': 'research',
        'status': 'draft',
        'configJson': const {},
        'createdAt': '2026-03-10T10:00:00Z',
      });

      expect(task.provider, 'codex');
      expect(withoutProvider.provider, isNull);
    });

    test('transition preserves provider', () {
      final task = _task(provider: 'codex');
      final transitioned = task.transition(TaskStatus.queued, now: DateTime.parse('2026-03-10T10:20:00Z'));

      expect(transitioned.provider, 'codex');
      expect(transitioned.status, TaskStatus.queued);
    });
  });
}
