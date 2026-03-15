import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  group('InMemoryTaskRepository', () {
    test('stores tasks and lists them newest first with filters', () async {
      final repo = InMemoryTaskRepository();
      final older = _task(id: 'task-1', createdAt: DateTime.parse('2026-03-10T10:00:00Z'));
      final newer = _task(
        id: 'task-2',
        type: TaskType.research,
        status: TaskStatus.running,
        createdAt: DateTime.parse('2026-03-10T11:00:00Z'),
      );

      await repo.insert(older);
      await repo.insert(newer);

      expect((await repo.list()).map((task) => task.id).toList(), ['task-2', 'task-1']);
      expect((await repo.list(status: TaskStatus.running)).map((task) => task.id).toList(), ['task-2']);
      expect((await repo.list(type: TaskType.coding)).map((task) => task.id).toList(), ['task-1']);
    });

    test('supports transition-safe updates and spoofed next reads', () async {
      final repo = InMemoryTaskRepository();
      await repo.insert(_task(status: TaskStatus.queued));

      repo.taskReturnedOnNextReadAfterSuccessfulTransition = _task(
        status: TaskStatus.review,
        startedAt: DateTime.parse('2026-03-10T10:05:00Z'),
      );

      final updated = _task(status: TaskStatus.running, startedAt: DateTime.parse('2026-03-10T10:01:00Z'));
      final wrote = await repo.updateIfStatus(updated, expectedStatus: TaskStatus.queued);

      expect(wrote, isTrue);
      expect((await repo.getById('task-1'))?.status, TaskStatus.review);
      expect((await repo.getById('task-1'))?.status, TaskStatus.running);
    });

    test('can simulate concurrent writes and manage artifacts', () async {
      final repo = InMemoryTaskRepository();
      await repo.insert(_task());
      repo.concurrentStatusOnNextMutableUpdate = TaskStatus.running;

      final wrote = await repo.updateMutableFieldsIfStatus(_task(title: 'Updated'), expectedStatus: TaskStatus.draft);

      expect(wrote, isFalse);
      expect((await repo.getById('task-1'))?.status, TaskStatus.running);

      final artifactA = TaskArtifact(
        id: 'artifact-a',
        taskId: 'task-1',
        name: 'A',
        kind: ArtifactKind.document,
        path: '/tmp/a.md',
        createdAt: DateTime.parse('2026-03-10T10:00:00Z'),
      );
      final artifactB = TaskArtifact(
        id: 'artifact-b',
        taskId: 'task-1',
        name: 'B',
        kind: ArtifactKind.diff,
        path: '/tmp/b.diff',
        createdAt: DateTime.parse('2026-03-10T10:05:00Z'),
      );

      await repo.insertArtifact(artifactB);
      await repo.insertArtifact(artifactA);

      expect((await repo.listArtifactsByTask('task-1')).map((artifact) => artifact.id).toList(), [
        'artifact-a',
        'artifact-b',
      ]);

      await repo.dispose();
      expect(repo.disposed, isTrue);
    });
  });
}

Task _task({
  String id = 'task-1',
  String title = 'Task title',
  String description = 'Describe the work',
  TaskType type = TaskType.coding,
  TaskStatus status = TaskStatus.draft,
  DateTime? createdAt,
  DateTime? startedAt,
}) {
  return Task(
    id: id,
    title: title,
    description: description,
    type: type,
    status: status,
    createdAt: createdAt ?? DateTime.parse('2026-03-10T10:00:00Z'),
    startedAt: startedAt,
  );
}
