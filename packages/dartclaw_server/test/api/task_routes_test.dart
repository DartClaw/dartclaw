import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

Future<String> _errorCode(Response res) async {
  final body = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
  return (body['error'] as Map<String, dynamic>)['code'] as String;
}

Map<String, dynamic> _decodeObject(String body) => jsonDecode(body) as Map<String, dynamic>;

List<dynamic> _decodeList(String body) => jsonDecode(body) as List<dynamic>;

Request _jsonRequest(String method, String path, [Map<String, dynamic>? body]) {
  return Request(
    method,
    Uri.parse('http://localhost$path'),
    body: body == null ? null : jsonEncode(body),
    headers: {'content-type': 'application/json'},
  );
}

void main() {
  late Database db;
  late TaskService tasks;
  late EventBus eventBus;
  late Handler handler;

  setUp(() {
    db = openTaskDbInMemory();
    tasks = TaskService(SqliteTaskRepository(db));
    eventBus = EventBus();
    handler = taskRoutes(tasks, eventBus).call;
  });

  tearDown(() async {
    await eventBus.dispose();
    await tasks.dispose();
  });

  Future<Task> createTask(String id, {String? title, TaskType type = TaskType.coding, bool autoStart = false}) {
    return tasks.create(
      id: id,
      title: title ?? 'Task $id',
      description: 'Description for $id',
      type: type,
      autoStart: autoStart,
      now: DateTime.parse('2026-03-10T10:00:00Z'),
    );
  }

  Future<void> putTaskInReview(String id) async {
    await createTask(id, autoStart: true);
    await tasks.transition(id, TaskStatus.running, now: DateTime.parse('2026-03-10T10:05:00Z'));
    await tasks.transition(id, TaskStatus.review, now: DateTime.parse('2026-03-10T10:10:00Z'));
  }

  group('POST /api/tasks', () {
    test('creates task in draft', () async {
      final response = await handler(
        _jsonRequest('POST', '/api/tasks', {
          'title': 'Draft task',
          'description': 'Describe the work',
          'type': 'coding',
        }),
      );

      expect(response.statusCode, 201);
      final body = _decodeObject(await response.readAsString());
      expect(body['title'], 'Draft task');
      expect(body['status'], 'draft');
    });

    test('creates task with autoStart as queued', () async {
      final response = await handler(
        _jsonRequest('POST', '/api/tasks', {
          'title': 'Queued task',
          'description': 'Describe the work',
          'type': 'research',
          'autoStart': true,
        }),
      );

      expect(response.statusCode, 201);
      final body = _decodeObject(await response.readAsString());
      expect(body['status'], 'queued');
    });

    test('echoes goalId on create', () async {
      final response = await handler(
        _jsonRequest('POST', '/api/tasks', {
          'title': 'Goal-linked task',
          'description': 'Describe the work',
          'type': 'coding',
          'goalId': 'goal-1',
        }),
      );

      expect(response.statusCode, 201);
      final body = _decodeObject(await response.readAsString());
      expect(body['goalId'], 'goal-1');
    });

    test('returns 400 for missing title', () async {
      final response = await handler(
        _jsonRequest('POST', '/api/tasks', {'description': 'Describe the work', 'type': 'coding'}),
      );

      expect(response.statusCode, 400);
      expect(await _errorCode(response), 'INVALID_INPUT');
    });

    test('returns 400 for missing description', () async {
      final response = await handler(_jsonRequest('POST', '/api/tasks', {'title': 'Task', 'type': 'coding'}));

      expect(response.statusCode, 400);
      expect(await _errorCode(response), 'INVALID_INPUT');
    });

    test('returns 400 for invalid type', () async {
      final response = await handler(
        _jsonRequest('POST', '/api/tasks', {'title': 'Task', 'description': 'Describe the work', 'type': 'invalid'}),
      );

      expect(response.statusCode, 400);
      expect(await _errorCode(response), 'INVALID_INPUT');
    });

    test('returns 400 for malformed string fields', () async {
      final response = await handler(
        _jsonRequest('POST', '/api/tasks', {
          'title': 'Task',
          'description': 'Describe the work',
          'type': 123,
          'goalId': 456,
          'acceptanceCriteria': 789,
        }),
      );

      expect(response.statusCode, 400);
      expect(await _errorCode(response), 'INVALID_INPUT');
    });

    test('fires TaskStatusChangedEvent on create', () async {
      final events = <TaskStatusChangedEvent>[];
      eventBus.on<TaskStatusChangedEvent>().listen(events.add);

      final response = await handler(
        _jsonRequest('POST', '/api/tasks', {'title': 'Task', 'description': 'Describe the work', 'type': 'coding'}),
      );
      expect(response.statusCode, 201);
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.single.oldStatus, TaskStatus.draft);
      expect(events.single.newStatus, TaskStatus.draft);
      expect(events.single.trigger, 'user');
    });
  });

  group('GET /api/tasks', () {
    test('lists all tasks', () async {
      await createTask('task-1');
      await createTask('task-2', type: TaskType.research);

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks')));

      expect(response.statusCode, 200);
      expect(_decodeList(await response.readAsString()), hasLength(2));
    });

    test('filters by status and type', () async {
      await createTask('draft-coding', type: TaskType.coding);
      await createTask('queued-coding', type: TaskType.coding, autoStart: true);
      await createTask('queued-research', type: TaskType.research, autoStart: true);

      final response = await handler(
        Request('GET', Uri.parse('http://localhost/api/tasks?status=queued&type=research')),
      );

      expect(response.statusCode, 200);
      final body = _decodeList(await response.readAsString());
      expect(body, hasLength(1));
      expect((body.single as Map<String, dynamic>)['id'], 'queued-research');
    });

    test('filters by status', () async {
      await createTask('draft-task');
      await createTask('queued-task', autoStart: true);

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks?status=draft')));

      expect(response.statusCode, 200);
      final body = _decodeList(await response.readAsString());
      expect(body, hasLength(1));
      expect((body.single as Map<String, dynamic>)['id'], 'draft-task');
    });

    test('filters by type', () async {
      await createTask('coding-task', type: TaskType.coding);
      await createTask('research-task', type: TaskType.research);

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks?type=research')));

      expect(response.statusCode, 200);
      final body = _decodeList(await response.readAsString());
      expect(body, hasLength(1));
      expect((body.single as Map<String, dynamic>)['id'], 'research-task');
    });

    test('returns empty list when no matches', () async {
      await createTask('task-1');

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks?status=queued')));

      expect(response.statusCode, 200);
      expect(_decodeList(await response.readAsString()), isEmpty);
    });

    test('ignores invalid filters', () async {
      await createTask('task-1');

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks?status=nope&type=missing')));

      expect(response.statusCode, 200);
      expect(_decodeList(await response.readAsString()), hasLength(1));
    });

    test('includes artifactDiskBytes in list response', () async {
      final tempDir = Directory.systemTemp.createTempSync('dartclaw_task_artifacts_');
      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      await createTask('task-artifacts');
      final artifactsDir = Directory('${tempDir.path}/tasks/task-artifacts/artifacts')..createSync(recursive: true);
      File('${artifactsDir.path}/output.txt').writeAsStringSync('hello');

      final response = await taskRoutes(
        tasks,
        eventBus,
        dataDir: tempDir.path,
      ).call(Request('GET', Uri.parse('http://localhost/api/tasks')));

      expect(response.statusCode, 200);
      final body = _decodeList(await response.readAsString());
      final task = body.single as Map<String, dynamic>;
      expect(task['artifactDiskBytes'], 5);
    });
  });

  group('GET /api/tasks/<id>', () {
    test('returns task detail', () async {
      await createTask('task-1', title: 'Detailed task');

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks/task-1')));

      expect(response.statusCode, 200);
      final body = _decodeObject(await response.readAsString());
      expect(body['title'], 'Detailed task');
    });

    test('includes artifactDiskBytes in detail response', () async {
      final tempDir = Directory.systemTemp.createTempSync('dartclaw_task_detail_artifacts_');
      addTearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      await createTask('task-detail');
      final artifactsDir = Directory('${tempDir.path}/tasks/task-detail/artifacts')..createSync(recursive: true);
      File('${artifactsDir.path}/output.txt').writeAsStringSync('hello');

      final response = await taskRoutes(
        tasks,
        eventBus,
        dataDir: tempDir.path,
      ).call(Request('GET', Uri.parse('http://localhost/api/tasks/task-detail')));

      expect(response.statusCode, 200);
      final body = _decodeObject(await response.readAsString());
      expect(body['artifactDiskBytes'], 5);
    });

    test('returns 404 for missing task', () async {
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks/missing')));

      expect(response.statusCode, 404);
      expect(await _errorCode(response), 'TASK_NOT_FOUND');
    });
  });

  group('POST /api/tasks/<id>/start', () {
    test('transitions draft to queued', () async {
      await createTask('task-1');

      final response = await handler(_jsonRequest('POST', '/api/tasks/task-1/start', const {}));

      expect(response.statusCode, 200);
      final body = _decodeObject(await response.readAsString());
      expect(body['status'], 'queued');
    });

    test('returns 404 for missing task', () async {
      final response = await handler(_jsonRequest('POST', '/api/tasks/missing/start', const {}));

      expect(response.statusCode, 404);
      expect(await _errorCode(response), 'TASK_NOT_FOUND');
    });

    test('returns 409 for invalid transition', () async {
      await createTask('task-1', autoStart: true);

      final response = await handler(_jsonRequest('POST', '/api/tasks/task-1/start', const {}));

      expect(response.statusCode, 409);
      final body = _decodeObject(await response.readAsString());
      expect(body['error']['code'], 'INVALID_TRANSITION');
      expect(body['error']['details']['currentStatus'], 'queued');
    });

    test('fires TaskStatusChangedEvent', () async {
      await createTask('task-1');
      final events = <TaskStatusChangedEvent>[];
      eventBus.on<TaskStatusChangedEvent>().listen(events.add);

      final response = await handler(_jsonRequest('POST', '/api/tasks/task-1/start', const {}));
      expect(response.statusCode, 200);
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.single.oldStatus, TaskStatus.draft);
      expect(events.single.newStatus, TaskStatus.queued);
      expect(events.single.trigger, 'user');
    });
  });

  group('POST /api/tasks/<id>/checkout', () {
    test('transitions queued to running', () async {
      await createTask('task-1', autoStart: true);

      final response = await handler(_jsonRequest('POST', '/api/tasks/task-1/checkout', const {}));

      expect(response.statusCode, 200);
      final body = _decodeObject(await response.readAsString());
      expect(body['status'], 'running');
    });

    test('returns 409 on concurrent checkout', () async {
      await createTask('task-1', autoStart: true);
      final first = await handler(_jsonRequest('POST', '/api/tasks/task-1/checkout', const {}));
      expect(first.statusCode, 200);

      final second = await handler(_jsonRequest('POST', '/api/tasks/task-1/checkout', const {}));

      expect(second.statusCode, 409);
      final body = _decodeObject(await second.readAsString());
      expect(body['error']['code'], 'CHECKOUT_CONFLICT');
      expect(body['error']['details']['currentStatus'], 'running');
    });

    test('returns 404 for missing task', () async {
      final response = await handler(_jsonRequest('POST', '/api/tasks/missing/checkout', const {}));

      expect(response.statusCode, 404);
      expect(await _errorCode(response), 'TASK_NOT_FOUND');
    });

    test('fires TaskStatusChangedEvent with system trigger', () async {
      await createTask('task-1', autoStart: true);
      final events = <TaskStatusChangedEvent>[];
      eventBus.on<TaskStatusChangedEvent>().listen(events.add);

      final response = await handler(_jsonRequest('POST', '/api/tasks/task-1/checkout', const {}));
      expect(response.statusCode, 200);
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.single.oldStatus, TaskStatus.queued);
      expect(events.single.newStatus, TaskStatus.running);
      expect(events.single.trigger, 'system');
    });
  });

  group('POST /api/tasks/<id>/cancel', () {
    test('cancels running task', () async {
      await createTask('task-1', autoStart: true);
      await tasks.transition('task-1', TaskStatus.running);

      final response = await handler(_jsonRequest('POST', '/api/tasks/task-1/cancel', const {}));

      expect(response.statusCode, 200);
      final body = _decodeObject(await response.readAsString());
      expect(body['status'], 'cancelled');
    });

    test('returns 404 for missing task', () async {
      final response = await handler(_jsonRequest('POST', '/api/tasks/missing/cancel', const {}));

      expect(response.statusCode, 404);
      expect(await _errorCode(response), 'TASK_NOT_FOUND');
    });

    test('returns 409 for terminal task', () async {
      await createTask('task-1');
      await tasks.transition('task-1', TaskStatus.cancelled);

      final response = await handler(_jsonRequest('POST', '/api/tasks/task-1/cancel', const {}));

      expect(response.statusCode, 409);
      expect(await _errorCode(response), 'INVALID_TRANSITION');
    });

    test('fires TaskStatusChangedEvent', () async {
      await createTask('task-1', autoStart: true);
      await tasks.transition('task-1', TaskStatus.running);
      final events = <TaskStatusChangedEvent>[];
      eventBus.on<TaskStatusChangedEvent>().listen(events.add);

      final response = await handler(_jsonRequest('POST', '/api/tasks/task-1/cancel', const {}));
      expect(response.statusCode, 200);
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.single.oldStatus, TaskStatus.running);
      expect(events.single.newStatus, TaskStatus.cancelled);
      expect(events.single.trigger, 'user');
    });

    test('cancels the active turn for running tasks with sessions', () async {
      final turns = _CancelTrackingTurns();
      handler = taskRoutes(tasks, eventBus, turns: turns).call;
      await createTask('task-1', autoStart: true);
      await tasks.transition('task-1', TaskStatus.running);
      await tasks.updateFields('task-1', sessionId: 'session-123');

      final response = await handler(_jsonRequest('POST', '/api/tasks/task-1/cancel', const {}));

      expect(response.statusCode, 200);
      expect(turns.cancelledSessions, ['session-123']);
    });
  });

  group('POST /api/tasks/<id>/review', () {
    test('accepts review task', () async {
      await putTaskInReview('task-1');

      final response = await handler(_jsonRequest('POST', '/api/tasks/task-1/review', {'action': 'accept'}));

      expect(response.statusCode, 200);
      final body = _decodeObject(await response.readAsString());
      expect(body['status'], 'accepted');
    });

    test('rejects review task', () async {
      await putTaskInReview('task-1');

      final response = await handler(_jsonRequest('POST', '/api/tasks/task-1/review', {'action': 'reject'}));

      expect(response.statusCode, 200);
      final body = _decodeObject(await response.readAsString());
      expect(body['status'], 'rejected');
    });

    test('pushes back review task', () async {
      await putTaskInReview('task-1');

      final response = await handler(
        _jsonRequest('POST', '/api/tasks/task-1/review', {'action': 'push_back', 'comment': 'try again'}),
      );

      expect(response.statusCode, 200);
      final body = _decodeObject(await response.readAsString());
      expect(body['status'], 'queued');
      expect((body['configJson'] as Map<String, dynamic>)['pushBackCount'], 1);
      expect((body['configJson'] as Map<String, dynamic>)['pushBackComment'], 'try again');
    });

    test('returns 400 when push_back comment is missing', () async {
      await putTaskInReview('task-1');

      final response = await handler(_jsonRequest('POST', '/api/tasks/task-1/review', {'action': 'push_back'}));

      expect(response.statusCode, 400);
      expect(await _errorCode(response), 'INVALID_INPUT');
      expect((await tasks.get('task-1'))!.status, TaskStatus.review);
    });

    test('returns 400 when push_back comment is blank', () async {
      await putTaskInReview('task-1');

      final response = await handler(
        _jsonRequest('POST', '/api/tasks/task-1/review', {'action': 'push_back', 'comment': '   '}),
      );

      expect(response.statusCode, 400);
      expect(await _errorCode(response), 'INVALID_INPUT');
      expect((await tasks.get('task-1'))!.status, TaskStatus.review);
    });

    test('does not persist pushBackComment when push_back loses a transition race', () async {
      final repo = _InMemoryTaskRepository();
      final racingTasks = TaskService(repo);
      addTearDown(racingTasks.dispose);
      final racingHandler = taskRoutes(racingTasks, eventBus).call;

      await racingTasks.create(
        id: 'task-1',
        title: 'Task task-1',
        description: 'Description for task-1',
        type: TaskType.coding,
        autoStart: true,
        now: DateTime.parse('2026-03-10T10:00:00Z'),
      );
      await racingTasks.transition('task-1', TaskStatus.running, now: DateTime.parse('2026-03-10T10:05:00Z'));
      await racingTasks.transition('task-1', TaskStatus.review, now: DateTime.parse('2026-03-10T10:10:00Z'));
      repo.concurrentStatusOnNextTransition = TaskStatus.accepted;

      final response = await racingHandler(
        _jsonRequest('POST', '/api/tasks/task-1/review', {'action': 'push_back', 'comment': 'try again'}),
      );

      expect(response.statusCode, 409);
      expect(await _errorCode(response), 'INVALID_TRANSITION');
      final task = await racingTasks.get('task-1');
      expect(task!.status, TaskStatus.accepted);
      expect(task.configJson.containsKey('pushBackComment'), isFalse);
      expect(task.configJson.containsKey('pushBackCount'), isFalse);
    });

    test('returns 400 for invalid action', () async {
      await putTaskInReview('task-1');

      final response = await handler(_jsonRequest('POST', '/api/tasks/task-1/review', {'action': 'ship_it'}));

      expect(response.statusCode, 400);
      expect(await _errorCode(response), 'INVALID_INPUT');
    });

    test('returns 400 for missing action', () async {
      await putTaskInReview('task-1');

      final response = await handler(_jsonRequest('POST', '/api/tasks/task-1/review', const {}));

      expect(response.statusCode, 400);
      expect(await _errorCode(response), 'INVALID_INPUT');
    });

    test('returns 400 for malformed action field', () async {
      await putTaskInReview('task-1');

      final response = await handler(_jsonRequest('POST', '/api/tasks/task-1/review', {'action': 123}));

      expect(response.statusCode, 400);
      expect(await _errorCode(response), 'INVALID_INPUT');
    });

    test('returns 404 for missing task', () async {
      final response = await handler(_jsonRequest('POST', '/api/tasks/missing/review', {'action': 'accept'}));

      expect(response.statusCode, 404);
      expect(await _errorCode(response), 'TASK_NOT_FOUND');
    });

    test('returns 409 for invalid transition', () async {
      await createTask('task-1');

      final response = await handler(_jsonRequest('POST', '/api/tasks/task-1/review', {'action': 'accept'}));

      expect(response.statusCode, 409);
      expect(await _errorCode(response), 'INVALID_TRANSITION');
    });

    test('fires TaskStatusChangedEvent on accept', () async {
      await putTaskInReview('task-1');
      final events = <TaskStatusChangedEvent>[];
      eventBus.on<TaskStatusChangedEvent>().listen(events.add);

      final response = await handler(_jsonRequest('POST', '/api/tasks/task-1/review', {'action': 'accept'}));
      expect(response.statusCode, 200);
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.single.oldStatus, TaskStatus.review);
      expect(events.single.newStatus, TaskStatus.accepted);
      expect(events.single.trigger, 'user');
    });

    group('merge integration', () {
      late Directory tempDir;

      setUp(() {
        tempDir = Directory.systemTemp.createTempSync('dartclaw_merge_test_');
      });

      tearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      test('accept with successful merge transitions to accepted', () async {
        await putTaskInReview('merge-1');
        await tasks.updateFields(
          'merge-1',
          worktreeJson: const {
            'path': '/tmp/worktree',
            'branch': 'dartclaw/task-merge-1',
            'createdAt': '2026-03-10T10:00:00.000Z',
          },
        );

        final mockMerge = _MockMergeExecutor(
          result: const MergeSuccess(commitSha: 'abc123', commitMessage: 'task(merge-1): Task merge-1'),
        );
        final mergeHandler = taskRoutes(
          tasks,
          eventBus,
          mergeExecutor: mockMerge,
          dataDir: tempDir.path,
          mergeStrategy: 'squash',
          baseRef: 'main',
        ).call;

        final response = await mergeHandler(_jsonRequest('POST', '/api/tasks/merge-1/review', {'action': 'accept'}));

        expect(response.statusCode, 200);
        final body = _decodeObject(await response.readAsString());
        expect(body['status'], 'accepted');
      });

      test('accept with merge conflict returns 409 and stays in review', () async {
        await putTaskInReview('merge-2');
        await tasks.updateFields(
          'merge-2',
          worktreeJson: const {
            'path': '/tmp/worktree',
            'branch': 'dartclaw/task-merge-2',
            'createdAt': '2026-03-10T10:00:00.000Z',
          },
        );

        final mockMerge = _MockMergeExecutor(
          result: const MergeConflict(
            conflictingFiles: ['lib/main.dart', 'lib/utils.dart'],
            details: 'Automatic merge failed',
          ),
        );
        final mergeHandler = taskRoutes(
          tasks,
          eventBus,
          mergeExecutor: mockMerge,
          dataDir: tempDir.path,
          mergeStrategy: 'squash',
          baseRef: 'main',
        ).call;

        final response = await mergeHandler(_jsonRequest('POST', '/api/tasks/merge-2/review', {'action': 'accept'}));

        expect(response.statusCode, 409);
        final body = _decodeObject(await response.readAsString());
        expect(body['error']['code'], 'MERGE_CONFLICT');
        expect(body['error']['details']['conflictingFiles'], ['lib/main.dart', 'lib/utils.dart']);

        // Task should remain in review
        final task = await tasks.get('merge-2');
        expect(task!.status, TaskStatus.review);
      });

      test('conflict persists conflict.json artifact', () async {
        await putTaskInReview('merge-3');
        await tasks.updateFields(
          'merge-3',
          worktreeJson: const {
            'path': '/tmp/worktree',
            'branch': 'dartclaw/task-merge-3',
            'createdAt': '2026-03-10T10:00:00.000Z',
          },
        );

        final mockMerge = _MockMergeExecutor(
          result: const MergeConflict(conflictingFiles: ['lib/a.dart'], details: 'conflict details'),
        );
        final mergeHandler = taskRoutes(
          tasks,
          eventBus,
          mergeExecutor: mockMerge,
          dataDir: tempDir.path,
          mergeStrategy: 'squash',
          baseRef: 'main',
        ).call;

        await mergeHandler(_jsonRequest('POST', '/api/tasks/merge-3/review', {'action': 'accept'}));

        final artifacts = await tasks.listArtifacts('merge-3');
        expect(artifacts, hasLength(1));
        expect(artifacts.single.name, 'conflict.json');
        expect(artifacts.single.kind, ArtifactKind.data);

        // Verify file content
        final content = File(artifacts.single.path).readAsStringSync();
        final json = jsonDecode(content) as Map<String, dynamic>;
        expect(json['conflictingFiles'], ['lib/a.dart']);
      });

      test('reject skips merge and transitions to rejected', () async {
        await putTaskInReview('merge-4');
        await tasks.updateFields(
          'merge-4',
          worktreeJson: const {
            'path': '/tmp/worktree',
            'branch': 'dartclaw/task-merge-4',
            'createdAt': '2026-03-10T10:00:00.000Z',
          },
        );

        final mockMerge = _MockMergeExecutor(
          result: const MergeSuccess(commitSha: 'should-not-be-called', commitMessage: 'nope'),
        );
        final mergeHandler = taskRoutes(
          tasks,
          eventBus,
          mergeExecutor: mockMerge,
          dataDir: tempDir.path,
          mergeStrategy: 'squash',
          baseRef: 'main',
        ).call;

        final response = await mergeHandler(_jsonRequest('POST', '/api/tasks/merge-4/review', {'action': 'reject'}));

        expect(response.statusCode, 200);
        final body = _decodeObject(await response.readAsString());
        expect(body['status'], 'rejected');
        // Merge should not have been called
        expect(mockMerge.callCount, 0);
      });

      test('accept without worktreeJson skips merge', () async {
        await putTaskInReview('merge-5');
        // No worktreeJson set

        final mockMerge = _MockMergeExecutor(
          result: const MergeSuccess(commitSha: 'should-not-be-called', commitMessage: 'nope'),
        );
        final mergeHandler = taskRoutes(
          tasks,
          eventBus,
          mergeExecutor: mockMerge,
          dataDir: tempDir.path,
          mergeStrategy: 'squash',
          baseRef: 'main',
        ).call;

        final response = await mergeHandler(_jsonRequest('POST', '/api/tasks/merge-5/review', {'action': 'accept'}));

        expect(response.statusCode, 200);
        final body = _decodeObject(await response.readAsString());
        expect(body['status'], 'accepted');
        expect(mockMerge.callCount, 0);
      });
    });
  });

  group('DELETE /api/tasks/<id>', () {
    test('deletes terminal task', () async {
      await createTask('task-1');
      await tasks.transition('task-1', TaskStatus.cancelled);

      final response = await handler(Request('DELETE', Uri.parse('http://localhost/api/tasks/task-1')));

      expect(response.statusCode, 204);
      expect(await tasks.get('task-1'), isNull);
    });

    test('returns 404 for missing task', () async {
      final response = await handler(Request('DELETE', Uri.parse('http://localhost/api/tasks/missing')));

      expect(response.statusCode, 404);
      expect(await _errorCode(response), 'TASK_NOT_FOUND');
    });

    test('returns 409 for non-terminal task', () async {
      await createTask('task-1');

      final response = await handler(Request('DELETE', Uri.parse('http://localhost/api/tasks/task-1')));

      expect(response.statusCode, 409);
      expect(await _errorCode(response), 'INVALID_STATE');
    });
  });

  group('GET /api/tasks/<id>/artifacts', () {
    test('lists artifacts for task', () async {
      await createTask('task-1');
      await tasks.addArtifact(
        id: 'artifact-1',
        taskId: 'task-1',
        name: 'Patch',
        kind: ArtifactKind.diff,
        path: '/tmp/patch.diff',
      );

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks/task-1/artifacts')));

      expect(response.statusCode, 200);
      final body = _decodeList(await response.readAsString());
      expect(body, hasLength(1));
      expect((body.single as Map<String, dynamic>)['id'], 'artifact-1');
    });

    test('returns 404 for missing task', () async {
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks/missing/artifacts')));

      expect(response.statusCode, 404);
      expect(await _errorCode(response), 'TASK_NOT_FOUND');
    });

    test('returns empty list when no artifacts', () async {
      await createTask('task-1');

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks/task-1/artifacts')));

      expect(response.statusCode, 200);
      expect(_decodeList(await response.readAsString()), isEmpty);
    });
  });

  group('GET /api/tasks/<id>/artifacts/<artifactId>', () {
    test('returns artifact metadata', () async {
      await createTask('task-1');
      await tasks.addArtifact(
        id: 'artifact-1',
        taskId: 'task-1',
        name: 'Doc',
        kind: ArtifactKind.document,
        path: '/tmp/doc.md',
      );

      final response = await handler(
        Request('GET', Uri.parse('http://localhost/api/tasks/task-1/artifacts/artifact-1')),
      );

      expect(response.statusCode, 200);
      final body = _decodeObject(await response.readAsString());
      expect(body['kind'], 'document');
    });

    test('returns 404 for missing artifact', () async {
      await createTask('task-1');

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks/task-1/artifacts/missing')));

      expect(response.statusCode, 404);
      expect(await _errorCode(response), 'ARTIFACT_NOT_FOUND');
    });
  });
}

class _CancelTrackingTurns extends TurnManager {
  _CancelTrackingTurns()
    : super(
        messages: _ThrowingMessageService(),
        worker: _NoOpHarness(),
        behavior: BehaviorFileService(workspaceDir: Directory.systemTemp.path),
      );

  final List<String> cancelledSessions = [];

  @override
  Future<void> cancelTurn(String sessionId) async {
    cancelledSessions.add(sessionId);
  }
}

class _NoOpHarness implements AgentHarness {
  @override
  Stream<BridgeEvent> get events => const Stream.empty();

  @override
  PromptStrategy get promptStrategy => PromptStrategy.replace;

  @override
  WorkerState get state => WorkerState.idle;

  @override
  Future<void> cancel() async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<Map<String, dynamic>> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    Map<String, dynamic>? mcpServers,
    bool resume = false,
    String? directory,
    String? model,
  }) async => const <String, dynamic>{};
}

class _ThrowingMessageService implements MessageService {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _InMemoryTaskRepository implements TaskRepository {
  final Map<String, Task> _tasks = <String, Task>{};
  final Map<String, TaskArtifact> _artifacts = <String, TaskArtifact>{};
  TaskStatus? concurrentStatusOnNextTransition;

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
  Future<void> dispose() async {}

  @override
  Future<Task?> getById(String id) async => _tasks[id];

  @override
  Future<TaskArtifact?> getArtifactById(String id) async => _artifacts[id];

  @override
  Future<void> insert(Task task) async {
    _tasks[task.id] = task;
  }

  @override
  Future<void> insertArtifact(TaskArtifact artifact) async {
    _artifacts[artifact.id] = artifact;
  }

  @override
  Future<List<Task>> list({TaskStatus? status, TaskType? type}) async {
    final tasks = _tasks.values.where((task) {
      if (status != null && task.status != status) return false;
      if (type != null && task.type != type) return false;
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
    if (current == null) return false;

    final concurrentStatus = concurrentStatusOnNextTransition;
    if (concurrentStatus != null) {
      concurrentStatusOnNextTransition = null;
      _tasks[task.id] = current.copyWith(status: concurrentStatus);
      return false;
    }

    if (current.status != expectedStatus) return false;

    _tasks[task.id] = current.copyWith(
      status: task.status,
      configJson: task.configJson,
      startedAt: task.startedAt,
      completedAt: task.completedAt,
    );
    return true;
  }

  @override
  Future<bool> updateMutableFieldsIfStatus(Task task, {required TaskStatus expectedStatus}) async {
    final current = _tasks[task.id];
    if (current == null || current.status != expectedStatus) {
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
    _tasks[task.id] = task;
  }
}

class _MockMergeExecutor extends MergeExecutor {
  final MergeResult result;
  int callCount = 0;

  _MockMergeExecutor({required this.result}) : super(projectDir: '/mock');

  @override
  Future<MergeResult> merge({
    required String branch,
    required String baseRef,
    required String taskId,
    required String taskTitle,
    MergeStrategy? strategy,
  }) async {
    callCount++;
    return result;
  }
}
