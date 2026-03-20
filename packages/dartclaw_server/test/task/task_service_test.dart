import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/task/task_service.dart';
import 'package:test/test.dart';

void main() {
  late _InMemoryTaskRepository repo;
  late TaskService service;

  setUp(() {
    repo = _InMemoryTaskRepository();
    service = TaskService(repo);
  });

  group('create', () {
    test('creates task in draft status', () async {
      final task = await service.create(
        id: 'task-1',
        title: 'Draft task',
        description: 'Describe the work',
        type: TaskType.analysis,
        now: DateTime.parse('2026-03-10T10:00:00Z'),
      );

      expect(task.status, TaskStatus.draft);
      expect((await repo.getById(task.id))?.status, TaskStatus.draft);
    });

    test('creates task with autoStart as queued', () async {
      final task = await service.create(
        id: 'task-1',
        title: 'Queued task',
        description: 'Describe the work',
        type: TaskType.coding,
        autoStart: true,
        now: DateTime.parse('2026-03-10T10:00:00Z'),
      );

      expect(task.status, TaskStatus.queued);
      expect(task.createdAt, DateTime.parse('2026-03-10T10:00:00Z'));
    });

    test('creates with all fields', () async {
      final task = await service.create(
        id: 'task-1',
        title: 'Task',
        description: 'Describe the work',
        type: TaskType.research,
        goalId: 'goal-1',
        acceptanceCriteria: 'Done',
        configJson: const {'model': 'sonnet'},
        now: DateTime.parse('2026-03-10T10:00:00Z'),
      );

      expect(task.goalId, 'goal-1');
      expect(task.acceptanceCriteria, 'Done');
      expect(task.configJson, {'model': 'sonnet'});
    });

    test('creates with empty configJson by default', () async {
      final task = await service.create(
        id: 'task-1',
        title: 'Task',
        description: 'Describe the work',
        type: TaskType.writing,
      );

      expect(task.configJson, isEmpty);
    });
  });

  group('transition', () {
    test('transitions draft to queued', () async {
      await repo.insert(_task());

      final updated = await service.transition('task-1', TaskStatus.queued);

      expect(updated.status, TaskStatus.queued);
    });

    test('transitions queued to running sets startedAt', () async {
      await repo.insert(_task(status: TaskStatus.queued));
      final now = DateTime.parse('2026-03-10T10:05:00Z');

      final updated = await service.transition('task-1', TaskStatus.running, now: now);

      expect(updated.startedAt, now);
      expect(updated.completedAt, isNull);
    });

    test('transitions running to review', () async {
      await repo.insert(_task(status: TaskStatus.running, startedAt: DateTime.parse('2026-03-10T10:05:00Z')));

      final updated = await service.transition('task-1', TaskStatus.review);

      expect(updated.status, TaskStatus.review);
      expect(updated.completedAt, isNull);
    });

    test('transitions review to accepted sets completedAt', () async {
      final now = DateTime.parse('2026-03-10T10:10:00Z');
      await repo.insert(_task(status: TaskStatus.review, startedAt: DateTime.parse('2026-03-10T10:05:00Z')));

      final updated = await service.transition('task-1', TaskStatus.accepted, now: now);

      expect(updated.completedAt, now);
    });

    test('transitions review to queued and persists transition-managed config fields', () async {
      await repo.insert(
        _task(
          status: TaskStatus.review,
          sessionId: 'session-1',
          configJson: const {'pushBackCount': 1, 'budget': 1000},
          startedAt: DateTime.parse('2026-03-10T10:05:00Z'),
          completedAt: DateTime.parse('2026-03-10T10:09:00Z'),
        ),
      );

      final updated = await service.transition('task-1', TaskStatus.queued);
      final persisted = await repo.getById('task-1');

      expect(updated.configJson, {'pushBackCount': 2, 'budget': 1000});
      expect(updated.sessionId, 'session-1');
      expect(updated.completedAt, isNull);
      expect(persisted?.configJson, {'pushBackCount': 2, 'budget': 1000});
      expect(persisted?.sessionId, 'session-1');
      expect(persisted?.completedAt, isNull);
    });

    test('transitions can persist config overrides atomically with the status update', () async {
      await repo.insert(
        _task(
          status: TaskStatus.running,
          configJson: const {'origin': 'channel'},
          startedAt: DateTime.parse('2026-03-10T10:05:00Z'),
        ),
      );

      final updated = await service.transition(
        'task-1',
        TaskStatus.failed,
        configJson: const {'origin': 'channel', 'errorSummary': 'Turn execution failed'},
      );

      expect(updated.status, TaskStatus.failed);
      expect(updated.configJson, {'origin': 'channel', 'errorSummary': 'Turn execution failed'});
      expect((await repo.getById('task-1'))!.configJson, {
        'origin': 'channel',
        'errorSummary': 'Turn execution failed',
      });
    });

    test('invalid transition throws StateError', () async {
      await repo.insert(_task());

      expect(() => service.transition('task-1', TaskStatus.running), throwsA(isA<StateError>()));
    });

    test('transition on missing task throws ArgumentError', () {
      expect(() => service.transition('missing', TaskStatus.queued), throwsA(isA<ArgumentError>()));
    });

    test('uses provided timestamp', () async {
      final now = DateTime.parse('2026-03-10T10:05:00Z');
      await repo.insert(_task(status: TaskStatus.queued));

      final updated = await service.transition('task-1', TaskStatus.running, now: now);

      expect(updated.startedAt, now);
    });

    test('returns the committed transition snapshot without rereading', () async {
      final now = DateTime.parse('2026-03-10T10:05:00Z');
      await repo.insert(_task(status: TaskStatus.queued));
      repo.taskReturnedOnNextReadAfterSuccessfulTransition = _task(
        status: TaskStatus.review,
        startedAt: DateTime.parse('2026-03-10T10:04:00Z'),
      );

      final updated = await service.transition('task-1', TaskStatus.running, now: now);

      expect(updated.status, TaskStatus.running);
      expect(updated.startedAt, now);
    });

    test('throws when task status changed before atomic write', () async {
      await repo.insert(_task(status: TaskStatus.queued));
      repo.concurrentStatusOnNextTransition = TaskStatus.review;

      expect(() => service.transition('task-1', TaskStatus.running), throwsA(isA<StateError>()));
    });
  });

  group('updateFields', () {
    test('updates title', () async {
      await repo.insert(_task());

      final updated = await service.updateFields('task-1', title: 'Updated');

      expect(updated.title, 'Updated');
      expect(updated.description, 'Describe the work');
    });

    test('updates multiple fields', () async {
      await repo.insert(_task());

      final updated = await service.updateFields(
        'task-1',
        title: 'Updated',
        description: 'New description',
        acceptanceCriteria: 'Tests pass',
        configJson: const {'model': 'opus'},
      );

      expect(updated.title, 'Updated');
      expect(updated.description, 'New description');
      expect(updated.acceptanceCriteria, 'Tests pass');
      expect(updated.configJson, {'model': 'opus'});
    });

    test('throws on terminal task', () async {
      await repo.insert(_task(status: TaskStatus.accepted));

      expect(() => service.updateFields('task-1', title: 'Updated'), throwsA(isA<StateError>()));
    });

    test('throws on missing task', () {
      expect(() => service.updateFields('missing', title: 'Updated'), throwsA(isA<ArgumentError>()));
    });

    test('updates sessionId', () async {
      await repo.insert(_task(configJson: const {'model': 'sonnet'}));

      final updated = await service.updateFields('task-1', sessionId: 'session-9');

      expect(updated.sessionId, 'session-9');
      expect(updated.configJson, {'model': 'sonnet'});
    });

    test('updates worktreeJson', () async {
      await repo.insert(_task());

      final updated = await service.updateFields('task-1', worktreeJson: const {'branch': 'task-1'});

      expect(updated.worktreeJson, {'branch': 'task-1'});
    });

    test('throws when status changes before mutable update is written', () async {
      await repo.insert(_task());
      repo.concurrentStatusOnNextMutableUpdate = TaskStatus.running;

      await expectLater(
        service.updateFields('task-1', title: 'Updated'),
        throwsA(
          isA<StateError>().having((error) => error.message, 'message', contains('expected draft, found running')),
        ),
      );

      final current = await repo.getById('task-1');
      expect(current?.title, 'Task title');
      expect(current?.status, TaskStatus.running);
    });
  });

  group('delete', () {
    test('deletes terminal task', () async {
      await repo.insert(_task(status: TaskStatus.accepted));

      await service.delete('task-1');

      expect(await repo.getById('task-1'), isNull);
    });

    test('throws on non-terminal task', () async {
      await repo.insert(_task());

      expect(() => service.delete('task-1'), throwsA(isA<StateError>()));
    });

    test('throws on missing task', () {
      expect(() => service.delete('missing'), throwsA(isA<ArgumentError>()));
    });
  });

  group('artifacts', () {
    test('adds artifact', () async {
      final now = DateTime.parse('2026-03-10T10:00:00Z');
      await repo.insert(_task());

      final artifact = await service.addArtifact(
        id: 'artifact-1',
        taskId: 'task-1',
        name: 'Patch',
        kind: ArtifactKind.diff,
        path: '/tmp/patch.diff',
        now: now,
      );

      expect(artifact.createdAt, now);
      expect(await service.getArtifact('artifact-1'), isNotNull);
    });

    test('lists artifacts by task', () async {
      await repo.insert(_task());
      await service.addArtifact(
        id: 'artifact-1',
        taskId: 'task-1',
        name: 'Patch',
        kind: ArtifactKind.diff,
        path: '/tmp/patch.diff',
      );
      await service.addArtifact(
        id: 'artifact-2',
        taskId: 'task-1',
        name: 'Doc',
        kind: ArtifactKind.document,
        path: '/tmp/doc.md',
      );

      final artifacts = await service.listArtifacts('task-1');

      expect(artifacts, hasLength(2));
    });

    test('gets artifact by id', () async {
      await repo.insert(_task());
      await service.addArtifact(
        id: 'artifact-1',
        taskId: 'task-1',
        name: 'Patch',
        kind: ArtifactKind.diff,
        path: '/tmp/patch.diff',
      );

      final artifact = await service.getArtifact('artifact-1');

      expect(artifact?.name, 'Patch');
    });

    test('deletes artifact', () async {
      await repo.insert(_task());
      await service.addArtifact(
        id: 'artifact-1',
        taskId: 'task-1',
        name: 'Patch',
        kind: ArtifactKind.diff,
        path: '/tmp/patch.diff',
      );

      await service.deleteArtifact('artifact-1');

      expect(await service.getArtifact('artifact-1'), isNull);
    });

    test('throws when parent task is missing', () {
      expect(
        () => service.addArtifact(
          id: 'artifact-1',
          taskId: 'missing',
          name: 'Patch',
          kind: ArtifactKind.diff,
          path: '/tmp/patch.diff',
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('dispose', () {
    test('disposes repository', () async {
      await service.dispose();

      expect(repo.disposed, isTrue);
    });
  });
}

Task _task({
  String id = 'task-1',
  TaskStatus status = TaskStatus.draft,
  TaskType type = TaskType.coding,
  String? goalId,
  String? acceptanceCriteria,
  String? sessionId,
  Map<String, dynamic> configJson = const {},
  Map<String, dynamic>? worktreeJson,
  DateTime? startedAt,
  DateTime? completedAt,
}) {
  return Task(
    id: id,
    title: 'Task title',
    description: 'Describe the work',
    type: type,
    status: status,
    goalId: goalId,
    acceptanceCriteria: acceptanceCriteria,
    sessionId: sessionId,
    configJson: configJson,
    worktreeJson: worktreeJson,
    createdAt: DateTime.parse('2026-03-10T10:00:00Z'),
    startedAt: startedAt,
    completedAt: completedAt,
  );
}

class _InMemoryTaskRepository implements TaskRepository {
  final Map<String, Task> _tasks = <String, Task>{};
  final Map<String, TaskArtifact> _artifacts = <String, TaskArtifact>{};
  bool disposed = false;
  TaskStatus? concurrentStatusOnNextTransition;
  TaskStatus? concurrentStatusOnNextMutableUpdate;
  Task? taskReturnedOnNextReadAfterSuccessfulTransition;
  bool _spoofNextReadAfterSuccessfulTransition = false;

  @override
  Future<void> delete(String id) async {
    if (_tasks.remove(id) == null) {
      throw ArgumentError('Task not found: $id');
    }
    _artifacts.removeWhere((_, artifact) => artifact.taskId == id);
  }

  @override
  Future<void> deleteArtifact(String id) async {
    _artifacts.remove(id);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }

  @override
  Future<Task?> getById(String id) async {
    if (_spoofNextReadAfterSuccessfulTransition) {
      _spoofNextReadAfterSuccessfulTransition = false;
      final overriddenTask = taskReturnedOnNextReadAfterSuccessfulTransition;
      taskReturnedOnNextReadAfterSuccessfulTransition = null;
      return overriddenTask;
    }
    return _tasks[id];
  }

  @override
  Future<TaskArtifact?> getArtifactById(String id) async => _artifacts[id];

  @override
  Future<void> insert(Task task) async {
    if (_tasks.containsKey(task.id)) {
      throw ArgumentError('Task already exists: ${task.id}');
    }
    _tasks[task.id] = task;
  }

  @override
  Future<void> insertArtifact(TaskArtifact artifact) async {
    _artifacts[artifact.id] = artifact;
  }

  @override
  Future<List<Task>> list({TaskStatus? status, TaskType? type}) async {
    final tasks = _tasks.values.where((task) {
      if (status != null && task.status != status) {
        return false;
      }
      if (type != null && task.type != type) {
        return false;
      }
      return true;
    }).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return tasks;
  }

  @override
  Future<List<TaskArtifact>> listArtifactsByTask(String taskId) async {
    final artifacts = _artifacts.values.where((artifact) => artifact.taskId == taskId).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return artifacts;
  }

  @override
  Future<bool> updateIfStatus(Task task, {required TaskStatus expectedStatus}) async {
    final current = _tasks[task.id];
    if (current == null) {
      return false;
    }

    final concurrentStatus = concurrentStatusOnNextTransition;
    if (concurrentStatus != null) {
      concurrentStatusOnNextTransition = null;
      _tasks[task.id] = current.copyWith(status: concurrentStatus);
      return false;
    }

    if (current.status != expectedStatus) {
      return false;
    }

    _tasks[task.id] = current.copyWith(
      status: task.status,
      configJson: task.configJson,
      startedAt: task.startedAt,
      completedAt: task.completedAt,
    );
    if (taskReturnedOnNextReadAfterSuccessfulTransition != null) {
      _spoofNextReadAfterSuccessfulTransition = true;
    }
    return true;
  }

  @override
  Future<bool> updateMutableFieldsIfStatus(Task task, {required TaskStatus expectedStatus}) async {
    final current = _tasks[task.id];
    if (current == null) {
      return false;
    }

    final concurrentStatus = concurrentStatusOnNextMutableUpdate;
    if (concurrentStatus != null) {
      concurrentStatusOnNextMutableUpdate = null;
      _tasks[task.id] = current.copyWith(status: concurrentStatus);
      return false;
    }

    if (current.status != expectedStatus) {
      return false;
    }

    _tasks[task.id] = current.copyWith(
      title: task.title,
      description: task.description,
      acceptanceCriteria: task.acceptanceCriteria,
      sessionId: task.sessionId,
      configJson: task.configJson,
      worktreeJson: task.worktreeJson,
    );
    return true;
  }

  @override
  Future<void> update(Task task) async {
    if (!_tasks.containsKey(task.id)) {
      throw ArgumentError('Task not found: ${task.id}');
    }
    _tasks[task.id] = task;
  }
}
