import 'package:dartclaw_server/src/task/task_service.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  group('InMemoryTaskRepository', () => _runLockingTests(() => InMemoryTaskRepository()));

  group('SqliteTaskRepository (in-memory SQLite)', () {
    late Database db;

    setUp(() {
      db = openTaskDbInMemory();
    });

    tearDown(() {
      db.close();
    });

    _runLockingTests(() => SqliteTaskRepository(db));
  });

  group('Version model field', () {
    test('Task defaults version to 1', () {
      final task = Task(
        id: 'task-1',
        title: 'Test',
        description: 'desc',
        type: TaskType.coding,
        configJson: const {},
        createdAt: DateTime.parse('2026-03-10T10:00:00Z'),
      );

      expect(task.version, 1);
    });

    test('Task.toJson includes version', () {
      final task = Task(
        id: 'task-1',
        title: 'Test',
        description: 'desc',
        type: TaskType.coding,
        configJson: const {},
        createdAt: DateTime.parse('2026-03-10T10:00:00Z'),
      );

      expect(task.toJson()['version'], 1);
    });

    test('Task.fromJson reads version with fallback to 1', () {
      final json = {
        'id': 'task-1',
        'title': 'Test',
        'description': 'desc',
        'type': 'coding',
        'status': 'draft',
        'configJson': <String, dynamic>{},
        'createdAt': '2026-03-10T10:00:00.000Z',
      };

      final task = Task.fromJson(json);
      expect(task.version, 1);
    });

    test('Task.fromJson reads explicit version', () {
      final json = {
        'id': 'task-1',
        'title': 'Test',
        'description': 'desc',
        'type': 'coding',
        'status': 'draft',
        'version': 5,
        'configJson': <String, dynamic>{},
        'createdAt': '2026-03-10T10:00:00.000Z',
      };

      final task = Task.fromJson(json);
      expect(task.version, 5);
    });

    test('Task.copyWith updates version', () {
      final task = Task(
        id: 'task-1',
        title: 'Test',
        description: 'desc',
        type: TaskType.coding,
        configJson: const {},
        createdAt: DateTime.parse('2026-03-10T10:00:00Z'),
      );

      final updated = task.copyWith(version: 3);
      expect(updated.version, 3);
    });

    test('VersionConflictException message includes task id and versions', () {
      final ex = VersionConflictException(taskId: 'task-1', expectedVersion: 2, currentVersion: 3);

      expect(ex.toString(), contains('task-1'));
      expect(ex.toString(), contains('2'));
      expect(ex.toString(), contains('3'));
    });
  });
}

void _runLockingTests(TaskRepository Function() repoFactory) {
  late TaskRepository repo;
  late TaskService service;

  setUp(() {
    repo = repoFactory();
    service = TaskService(repo);
  });

  tearDown(() async {
    await service.dispose();
  });

  Task makeTask({TaskStatus status = TaskStatus.draft}) {
    return Task(
      id: 'task-1',
      title: 'Test task',
      description: 'Do the work',
      type: TaskType.coding,
      status: status,
      configJson: const {},
      createdAt: DateTime.parse('2026-03-10T10:00:00Z'),
    );
  }

  test('successful transition increments version', () async {
    await repo.insert(makeTask(status: TaskStatus.queued));

    final before = (await repo.getById('task-1'))!;
    expect(before.version, 1);

    await service.transition('task-1', TaskStatus.running);

    final after = (await repo.getById('task-1'))!;
    expect(after.version, 2);
  });

  test('multiple successive transitions each increment version', () async {
    await repo.insert(makeTask(status: TaskStatus.queued));

    await service.transition('task-1', TaskStatus.running);
    await service.transition('task-1', TaskStatus.review);

    final task = (await repo.getById('task-1'))!;
    expect(task.version, 3);
  });

  test('version conflict: throws VersionConflictException when version is stale', () async {
    // Use InMemoryTaskRepository-specific helper only for this test variant
    if (repo is InMemoryTaskRepository) {
      await repo.insert(makeTask(status: TaskStatus.queued));
      final taskBefore = (await repo.getById('task-1'))!;

      // Simulate a concurrent write bumping the version.
      (repo as InMemoryTaskRepository).concurrentVersionOnNextTransition = true;

      await expectLater(
        service.transition('task-1', TaskStatus.running),
        throwsA(
          isA<VersionConflictException>()
              .having((e) => e.taskId, 'taskId', 'task-1')
              .having((e) => e.expectedVersion, 'expectedVersion', taskBefore.version),
        ),
      );
    }
  });

  test('newly created task has version 1', () async {
    final created = await service.create(
      id: 'task-1',
      title: 'New task',
      description: 'desc',
      type: TaskType.research,
    );

    expect(created.version, 1);
    final stored = (await repo.getById('task-1'))!;
    expect(stored.version, 1);
  });
}
