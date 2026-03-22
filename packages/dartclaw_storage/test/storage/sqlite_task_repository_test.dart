import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  group('SqliteTaskRepository', () {
    late Database db;
    late SqliteTaskRepository repository;

    setUp(() {
      db = openTaskDbInMemory();
      repository = SqliteTaskRepository(db);
    });

    tearDown(() async {
      await repository.dispose();
    });

    group('schema', () {
      test('creates tables and indexes', () {
        final tables = db.select("SELECT name FROM sqlite_master WHERE type IN ('table', 'index') ORDER BY name");
        final names = tables.map((row) => row['name']).toList();

        expect(names, contains('tasks'));
        expect(names, contains('task_artifacts'));
        expect(names, contains('idx_tasks_status'));
        expect(names, contains('idx_tasks_type'));
        expect(names, contains('idx_tasks_status_type'));
        expect(names, contains('idx_task_artifacts_task_id'));
      });

      test('enables foreign keys', () {
        final rows = db.select('PRAGMA foreign_keys');
        expect(rows.single.columnAt(0), 1);
      });

      test('enables WAL mode for file databases', () async {
        final tempDir = await Directory.systemTemp.createTemp('sqlite-task-repo-');
        try {
          final fileDb = openTaskDb(p.join(tempDir.path, 'tasks.db'));
          final fileRepo = SqliteTaskRepository(fileDb);
          final rows = fileDb.select('PRAGMA journal_mode');

          expect(rows.single.columnAt(0), 'wal');

          await fileRepo.dispose();
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      });
    });

    group('tasks', () {
      test('inserts and gets a task with all fields', () async {
        final task = _task(
          goalId: 'goal-1',
          sessionId: 'session-1',
          acceptanceCriteria: 'ship it',
          configJson: const {'model': 'opus', 'budget': 1000},
          worktreeJson: const {'branch': 'feature/task-1'},
          startedAt: DateTime.parse('2026-03-10T10:05:00Z'),
          completedAt: DateTime.parse('2026-03-10T10:15:00Z'),
          status: TaskStatus.review,
        );

        await repository.insert(task);
        final loaded = await repository.getById(task.id);

        expect(loaded?.toJson(), task.toJson());
      });

      test('returns null for missing task', () async {
        expect(await repository.getById('missing'), isNull);
      });

      test('lists tasks ordered by created_at desc', () async {
        final oldest = _task(id: 'task-old', createdAt: DateTime.parse('2026-03-10T08:00:00Z'));
        final newest = _task(id: 'task-new', createdAt: DateTime.parse('2026-03-10T10:00:00Z'));
        final middle = _task(id: 'task-mid', createdAt: DateTime.parse('2026-03-10T09:00:00Z'));

        await repository.insert(oldest);
        await repository.insert(newest);
        await repository.insert(middle);

        final tasks = await repository.list();

        expect(tasks.map((task) => task.id), ['task-new', 'task-mid', 'task-old']);
      });

      test('filters by status and type', () async {
        await repository.insert(_task(id: 'draft-coding', status: TaskStatus.draft, type: TaskType.coding));
        await repository.insert(_task(id: 'queued-coding', status: TaskStatus.queued, type: TaskType.coding));
        await repository.insert(_task(id: 'queued-research', status: TaskStatus.queued, type: TaskType.research));

        final queued = await repository.list(status: TaskStatus.queued);
        final coding = await repository.list(type: TaskType.coding);
        final queuedCoding = await repository.list(status: TaskStatus.queued, type: TaskType.coding);

        expect(queued.map((task) => task.id), ['queued-research', 'queued-coding']);
        expect(coding.map((task) => task.id), ['queued-coding', 'draft-coding']);
        expect(queuedCoding.map((task) => task.id), ['queued-coding']);
      });

      test('updates an existing task', () async {
        final task = _task();
        await repository.insert(task);

        final updated = task.copyWith(
          title: 'Updated title',
          description: 'Updated description',
          status: TaskStatus.running,
          sessionId: 'session-2',
          configJson: const {'pushBackCount': 2},
          worktreeJson: const {'branch': 'updated'},
          startedAt: DateTime.parse('2026-03-10T10:05:00Z'),
        );

        await repository.update(updated);
        final loaded = await repository.getById(task.id);

        // update() increments version; compare excluding version.
        expect(loaded?.title, updated.title);
        expect(loaded?.description, updated.description);
        expect(loaded?.status, updated.status);
        expect(loaded?.sessionId, updated.sessionId);
        expect(loaded?.configJson, updated.configJson);
        expect(loaded?.worktreeJson, updated.worktreeJson);
        expect(loaded?.startedAt, updated.startedAt);
        expect(loaded?.version, task.version + 1);
      });

      test('update throws for missing task', () async {
        await expectLater(repository.update(_task(id: 'missing')), throwsArgumentError);
      });

      test(
        'conditionally updates transition fields and transition-provided config without overwriting other fields',
        () async {
          final task = _task(
            status: TaskStatus.review,
            sessionId: 'session-1',
            configJson: const {'pushBackCount': 1, 'budget': 1000},
            completedAt: DateTime.parse('2026-03-10T10:04:00Z'),
          );
          await repository.insert(task);
          await repository.update(task.copyWith(title: 'Fresh title'));

          // Re-fetch after update() to get the incremented version.
          final current = (await repository.getById(task.id))!;
          final transitioned = current
              .transition(TaskStatus.queued, now: DateTime.parse('2026-03-10T10:05:00Z'))
              .copyWith(sessionId: 'session-2', configJson: const {'pushBackCount': 99, 'budget': 5});
          final updated = await repository.updateIfStatus(transitioned, expectedStatus: TaskStatus.review);

          final loaded = await repository.getById(task.id);
          expect(updated, isTrue);
          expect(loaded?.title, 'Fresh title');
          expect(loaded?.status, TaskStatus.queued);
          expect(loaded?.sessionId, 'session-1');
          expect(loaded?.configJson, {'pushBackCount': 99, 'budget': 5});
          expect(loaded?.completedAt, isNull);
        },
      );

      test('conditional update returns false when status changed', () async {
        final task = _task(status: TaskStatus.queued);
        await repository.insert(task);

        final updated = await repository.updateIfStatus(
          task.transition(TaskStatus.running, now: DateTime.parse('2026-03-10T10:05:00Z')),
          expectedStatus: TaskStatus.draft,
        );

        expect(updated, isFalse);
        expect((await repository.getById(task.id))?.status, TaskStatus.queued);
      });

      test('conditionally updates mutable fields without touching lifecycle state', () async {
        final task = _task(status: TaskStatus.running, startedAt: DateTime.parse('2026-03-10T10:05:00Z'));
        await repository.insert(task);

        final updated = await repository.updateMutableFieldsIfStatus(
          task.copyWith(
            title: 'Updated title',
            description: 'Updated description',
            acceptanceCriteria: 'Tests pass',
            sessionId: 'session-2',
            configJson: const {'pushBackCount': 2},
            worktreeJson: const {'branch': 'feature/task-1'},
          ),
          expectedStatus: TaskStatus.running,
        );

        final loaded = await repository.getById(task.id);
        expect(updated, isTrue);
        expect(loaded?.title, 'Updated title');
        expect(loaded?.description, 'Updated description');
        expect(loaded?.acceptanceCriteria, 'Tests pass');
        expect(loaded?.sessionId, 'session-2');
        expect(loaded?.configJson, {'pushBackCount': 2});
        expect(loaded?.worktreeJson, {'branch': 'feature/task-1'});
        expect(loaded?.status, TaskStatus.running);
        expect(loaded?.startedAt, task.startedAt);
        expect(loaded?.completedAt, isNull);
      });

      test('conditional mutable update returns false when status changed', () async {
        final task = _task(status: TaskStatus.queued);
        await repository.insert(task);
        await repository.update(task.copyWith(status: TaskStatus.running));

        final updated = await repository.updateMutableFieldsIfStatus(
          task.copyWith(title: 'Updated title'),
          expectedStatus: TaskStatus.queued,
        );

        expect(updated, isFalse);
        expect((await repository.getById(task.id))?.title, task.title);
        expect((await repository.getById(task.id))?.status, TaskStatus.running);
      });

      test('deletes a task', () async {
        final task = _task();
        await repository.insert(task);

        await repository.delete(task.id);

        expect(await repository.getById(task.id), isNull);
      });

      test('delete throws for missing task', () async {
        await expectLater(repository.delete('missing'), throwsArgumentError);
      });
    });

    group('artifacts', () {
      test('inserts and gets artifact', () async {
        final task = _task();
        final artifact = _artifact();
        await repository.insert(task);

        await repository.insertArtifact(artifact);

        final loaded = await repository.getArtifactById(artifact.id);
        expect(loaded?.toJson(), artifact.toJson());
      });

      test('lists artifacts ordered by created_at asc', () async {
        final task = _task();
        await repository.insert(task);
        await repository.insertArtifact(_artifact(id: 'artifact-2', createdAt: DateTime.parse('2026-03-10T10:02:00Z')));
        await repository.insertArtifact(_artifact(id: 'artifact-1', createdAt: DateTime.parse('2026-03-10T10:01:00Z')));

        final artifacts = await repository.listArtifactsByTask(task.id);

        expect(artifacts.map((artifact) => artifact.id), ['artifact-1', 'artifact-2']);
      });

      test('returns null for missing artifact', () async {
        expect(await repository.getArtifactById('missing'), isNull);
      });

      test('deletes artifact', () async {
        final task = _task();
        final artifact = _artifact();
        await repository.insert(task);
        await repository.insertArtifact(artifact);

        await repository.deleteArtifact(artifact.id);

        expect(await repository.getArtifactById(artifact.id), isNull);
      });

      test('deleting task cascades to artifacts', () async {
        final task = _task();
        final artifact = _artifact();
        await repository.insert(task);
        await repository.insertArtifact(artifact);

        await repository.delete(task.id);

        expect(await repository.getArtifactById(artifact.id), isNull);
      });
    });
  });
}

Task _task({
  String id = 'task-1',
  DateTime? createdAt,
  TaskStatus status = TaskStatus.draft,
  TaskType type = TaskType.coding,
  String? goalId,
  String? sessionId,
  String? acceptanceCriteria,
  Map<String, dynamic> configJson = const {},
  Map<String, dynamic>? worktreeJson,
  DateTime? startedAt,
  DateTime? completedAt,
}) {
  return Task(
    id: id,
    title: 'Task $id',
    description: 'Description for $id',
    type: type,
    status: status,
    goalId: goalId,
    sessionId: sessionId,
    acceptanceCriteria: acceptanceCriteria,
    configJson: configJson,
    worktreeJson: worktreeJson,
    createdAt: createdAt ?? DateTime.parse('2026-03-10T10:00:00Z'),
    startedAt: startedAt,
    completedAt: completedAt,
  );
}

TaskArtifact _artifact({
  String id = 'artifact-1',
  String taskId = 'task-1',
  DateTime? createdAt,
  ArtifactKind kind = ArtifactKind.diff,
}) {
  return TaskArtifact(
    id: id,
    taskId: taskId,
    name: 'Artifact $id',
    kind: kind,
    path: '/tmp/$id',
    createdAt: createdAt ?? DateTime.parse('2026-03-10T10:01:00Z'),
  );
}
