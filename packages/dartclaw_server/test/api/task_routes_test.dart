import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'api_test_helpers.dart';

void main() {
  late Database db;
  late TaskService tasks;
  late EventBus eventBus;
  late Handler handler;
  late Directory tempDir;
  late ThreadBindingStore threadBindingStore;

  setUp(() async {
    db = openTaskDbInMemory();
    eventBus = EventBus();
    tasks = TaskService(
      SqliteTaskRepository(db),
      agentExecutionRepository: SqliteAgentExecutionRepository(db, eventBus: eventBus),
      executionTransactor: SqliteExecutionRepositoryTransactor(db),
      eventBus: eventBus,
    );
    tempDir = Directory.systemTemp.createTempSync('task_routes_test_');
    threadBindingStore = ThreadBindingStore(File('${tempDir.path}/thread-bindings.json'));
    await threadBindingStore.load();
    handler = taskRoutes(tasks, dataDir: tempDir.path, threadBindingStore: threadBindingStore).call;
  });

  tearDown(() async {
    await eventBus.dispose();
    await tasks.dispose();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
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

  FakeProjectService makeProjectService() {
    return FakeProjectService(
      projects: [
        Project(
          id: 'my-app',
          name: 'My App',
          remoteUrl: 'git@github.com:acme/my-app.git',
          localPath: '/projects/my-app',
          defaultBranch: 'main',
          status: ProjectStatus.ready,
          createdAt: DateTime.parse('2026-03-10T09:00:00Z'),
        ),
      ],
      includeLocalProjectInGetAll: false,
      defaultProjectId: 'my-app',
    );
  }

  group('POST /api/tasks', () {
    test('creates task in draft', () async {
      final response = await handler(
        jsonRequest('POST', '/api/tasks', {
          'title': 'Draft task',
          'description': 'Describe the work',
          'type': 'coding',
        }),
      );

      expect(response.statusCode, 201);
      final body = decodeObject(await response.readAsString());
      expect(body['title'], 'Draft task');
      expect(body['status'], 'draft');
    });

    test('task payload nests agent execution fields', () async {
      final response = await handler(
        jsonRequest('POST', '/api/tasks', {
          'title': 'Nested task',
          'description': 'Describe the work',
          'type': 'coding',
          'provider': 'codex',
        }),
      );

      expect(response.statusCode, 201);
      final body = decodeObject(await response.readAsString());
      expect(body.containsKey('provider'), isFalse);
      expect(body.containsKey('sessionId'), isFalse);
      expect(body['agentExecution'], isA<Map<String, dynamic>>());
      expect((body['agentExecution'] as Map<String, dynamic>)['provider'], 'codex');
    });

    test('persists model, sessionId, and maxTokens onto agent execution', () async {
      final response = await handler(
        jsonRequest('POST', '/api/tasks', {
          'title': 'Execution-seeded task',
          'description': 'Describe the work',
          'type': 'coding',
          'provider': 'claude',
          'model': 'claude-opus-4-7',
          'sessionId': 'sess-42',
          'maxTokens': 8000,
        }),
      );

      expect(response.statusCode, 201);
      final body = decodeObject(await response.readAsString());
      final ae = body['agentExecution'] as Map<String, dynamic>;
      expect(ae['provider'], 'claude');
      expect(ae['model'], 'claude-opus-4-7');
      expect(ae['sessionId'], 'sess-42');
      expect(ae['budgetTokens'], 8000);
    });

    test('accepts whole-number JSON double for maxTokens', () async {
      final response = await handler(
        jsonRequest('POST', '/api/tasks', {
          'title': 'Double task',
          'description': 'Describe the work',
          'type': 'coding',
          'maxTokens': 8000.0,
        }),
      );

      expect(response.statusCode, 201);
      final body = decodeObject(await response.readAsString());
      expect((body['agentExecution'] as Map<String, dynamic>)['budgetTokens'], 8000);
    });

    test('rejects non-numeric maxTokens', () async {
      final response = await handler(
        jsonRequest('POST', '/api/tasks', {
          'title': 'Bad task',
          'description': 'Describe the work',
          'type': 'coding',
          'maxTokens': 'lots',
        }),
      );

      expect(response.statusCode, 400);
    });

    test('rejects fractional maxTokens', () async {
      final response = await handler(
        jsonRequest('POST', '/api/tasks', {
          'title': 'Fractional task',
          'description': 'Describe the work',
          'type': 'coding',
          'maxTokens': 1.5,
        }),
      );

      expect(response.statusCode, 400);
    });

    test('rejects non-positive maxTokens', () async {
      for (final value in <num>[0, -1, 0.0]) {
        final response = await handler(
          jsonRequest('POST', '/api/tasks', {
            'title': 'Zero task',
            'description': 'Describe the work',
            'type': 'coding',
            'maxTokens': value,
          }),
        );
        expect(response.statusCode, 400, reason: 'maxTokens=$value should be rejected');
      }
    });

    test('rejects non-string model and sessionId', () async {
      final modelResponse = await handler(
        jsonRequest('POST', '/api/tasks', {
          'title': 'Bad task',
          'description': 'Describe the work',
          'type': 'coding',
          'model': 42,
        }),
      );
      expect(modelResponse.statusCode, 400);

      final sessionResponse = await handler(
        jsonRequest('POST', '/api/tasks', {
          'title': 'Bad task',
          'description': 'Describe the work',
          'type': 'coding',
          'sessionId': true,
        }),
      );
      expect(sessionResponse.statusCode, 400);
    });

    test('strips model key from configJson when persisted onto AE', () async {
      final response = await handler(
        jsonRequest('POST', '/api/tasks', {
          'title': 'Model in config',
          'description': 'Describe the work',
          'type': 'coding',
          'configJson': {'model': 'claude-opus-4-7', 'allowedTools': <String>[]},
        }),
      );

      expect(response.statusCode, 201);
      final body = decodeObject(await response.readAsString());
      expect((body['agentExecution'] as Map<String, dynamic>)['model'], 'claude-opus-4-7');
      expect((body['configJson'] as Map<String, dynamic>).containsKey('model'), isFalse);
    });

    test('creates task with autoStart as queued', () async {
      final response = await handler(
        jsonRequest('POST', '/api/tasks', {
          'title': 'Queued task',
          'description': 'Describe the work',
          'type': 'research',
          'autoStart': true,
        }),
      );

      expect(response.statusCode, 201);
      final body = decodeObject(await response.readAsString());
      expect(body['status'], 'queued');
    });

    test('persists projectId when provided', () async {
      final handlerWithProjects = taskRoutes(tasks, projectService: makeProjectService()).call;

      final response = await handlerWithProjects(
        jsonRequest('POST', '/api/tasks', {
          'title': 'Project task',
          'description': 'Describe the work',
          'type': 'coding',
          'projectId': 'my-app',
        }),
      );

      expect(response.statusCode, 201);
      final body = decodeObject(await response.readAsString());
      expect(body['projectId'], 'my-app');
      expect((await tasks.get(body['id'] as String))!.projectId, 'my-app');
    });

    test('returns 400 for unknown projectId', () async {
      final handlerWithProjects = taskRoutes(tasks, projectService: makeProjectService()).call;

      final response = await handlerWithProjects(
        jsonRequest('POST', '/api/tasks', {
          'title': 'Project task',
          'description': 'Describe the work',
          'type': 'coding',
          'projectId': 'missing-project',
        }),
      );

      expect(response.statusCode, 400);
      expect(await errorCode(response), 'INVALID_INPUT');
    });

    test('echoes goalId on create', () async {
      final response = await handler(
        jsonRequest('POST', '/api/tasks', {
          'title': 'Goal-linked task',
          'description': 'Describe the work',
          'type': 'coding',
          'goalId': 'goal-1',
        }),
      );

      expect(response.statusCode, 201);
      final body = decodeObject(await response.readAsString());
      expect(body['goalId'], 'goal-1');
    });

    test('returns 400 for missing title', () async {
      final response = await handler(
        jsonRequest('POST', '/api/tasks', {'description': 'Describe the work', 'type': 'coding'}),
      );

      expect(response.statusCode, 400);
      expect(await errorCode(response), 'INVALID_INPUT');
    });

    test('returns 400 for missing description', () async {
      final response = await handler(jsonRequest('POST', '/api/tasks', {'title': 'Task', 'type': 'coding'}));

      expect(response.statusCode, 400);
      expect(await errorCode(response), 'INVALID_INPUT');
    });

    test('returns 400 for invalid type', () async {
      final response = await handler(
        jsonRequest('POST', '/api/tasks', {'title': 'Task', 'description': 'Describe the work', 'type': 'invalid'}),
      );

      expect(response.statusCode, 400);
      expect(await errorCode(response), 'INVALID_INPUT');
    });

    test('returns 400 for malformed string fields', () async {
      final response = await handler(
        jsonRequest('POST', '/api/tasks', {
          'title': 'Task',
          'description': 'Describe the work',
          'type': 123,
          'goalId': 456,
          'acceptanceCriteria': 789,
        }),
      );

      expect(response.statusCode, 400);
      expect(await errorCode(response), 'INVALID_INPUT');
    });

    test('returns 400 when configJson includes internal underscore-prefixed keys', () async {
      final response = await handler(
        jsonRequest('POST', '/api/tasks', {
          'title': 'Task',
          'description': 'Describe the work',
          'type': 'coding',
          'configJson': {'_workflowWorkspaceDir': '/tmp/override'},
        }),
      );

      expect(response.statusCode, 400);
      expect(await errorCode(response), 'INVALID_INPUT');
    });

    // Note: draft-only creation (autoStart:false) does not fire a TaskStatusChangedEvent.
    // Events are fired by TaskService.transition() on status changes only.
    // See task_service_events_test.dart for event centralization tests.
  });

  group('task bindings API', () {
    test('GET /api/tasks/:id/bindings returns all bindings for the task', () async {
      await createTask('task-bindings');
      final now = DateTime.parse('2026-03-10T10:00:00Z');
      await threadBindingStore.create(
        ThreadBinding(
          channelType: 'googlechat',
          threadId: 'spaces/AAA/threads/BBB',
          taskId: 'task-bindings',
          sessionKey: 'agent:main:task:task-bindings',
          createdAt: now,
          lastActivity: now,
        ),
      );
      await threadBindingStore.create(
        ThreadBinding(
          channelType: 'whatsapp',
          threadId: 'group@g.us',
          taskId: 'task-bindings',
          sessionKey: 'agent:main:task:task-bindings',
          createdAt: now,
          lastActivity: now,
        ),
      );

      final response = await handler(jsonRequest('GET', '/api/tasks/task-bindings/bindings', null));

      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString()) as List<dynamic>;
      expect(body, hasLength(2));
    });

    test('POST /api/tasks/:id/bindings creates binding and returns 201', () async {
      await createTask('task-bind');

      final response = await handler(
        jsonRequest('POST', '/api/tasks/task-bind/bindings', {
          'channelType': 'googlechat',
          'threadId': 'spaces/AAA/threads/BBB',
        }),
      );

      expect(response.statusCode, 201);
      final body = decodeObject(await response.readAsString());
      expect(body['taskId'], 'task-bind');
      expect(body['channelType'], 'googlechat');
      expect(body['threadId'], 'spaces/AAA/threads/BBB');
    });

    test('POST duplicate binding returns 409', () async {
      await createTask('task-bind');
      await handler(
        jsonRequest('POST', '/api/tasks/task-bind/bindings', {
          'channelType': 'googlechat',
          'threadId': 'spaces/AAA/threads/BBB',
        }),
      );

      final response = await handler(
        jsonRequest('POST', '/api/tasks/task-bind/bindings', {
          'channelType': 'googlechat',
          'threadId': 'spaces/AAA/threads/BBB',
        }),
      );

      expect(response.statusCode, 409);
    });

    test('DELETE /api/tasks/:id/bindings/:channelType/:threadId removes binding', () async {
      await createTask('task-bind');
      final now = DateTime.parse('2026-03-10T10:00:00Z');
      await threadBindingStore.create(
        ThreadBinding(
          channelType: 'googlechat',
          threadId: 'spaces/AAA/threads/BBB',
          taskId: 'task-bind',
          sessionKey: 'agent:main:task:task-bind',
          createdAt: now,
          lastActivity: now,
        ),
      );

      final response = await handler(
        jsonRequest('DELETE', '/api/tasks/task-bind/bindings/googlechat/spaces/AAA/threads/BBB', null),
      );

      expect(response.statusCode, 200);
      final body = decodeObject(await response.readAsString());
      expect(body['deleted'], isTrue);
      expect(threadBindingStore.lookupByThread('googlechat', 'spaces/AAA/threads/BBB'), isNull);
    });

    test('POST binding updates the shared runtime store immediately', () async {
      await createTask('task-bind');

      final response = await handler(
        jsonRequest('POST', '/api/tasks/task-bind/bindings', {
          'channelType': 'googlechat',
          'threadId': 'spaces/AAA/threads/BBB',
        }),
      );

      expect(response.statusCode, 201);
      expect(threadBindingStore.lookupByThread('googlechat', 'spaces/AAA/threads/BBB')?.taskId, 'task-bind');
    });
  });

  group('GET /api/tasks', () {
    test('lists all tasks', () async {
      await createTask('task-1');
      await createTask('task-2', type: TaskType.research);

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks')));

      expect(response.statusCode, 200);
      expect(decodeList(await response.readAsString()), hasLength(2));
    });

    test('filters by status and type', () async {
      await createTask('draft-coding', type: TaskType.coding);
      await createTask('queued-coding', type: TaskType.coding, autoStart: true);
      await createTask('queued-research', type: TaskType.research, autoStart: true);

      final response = await handler(
        Request('GET', Uri.parse('http://localhost/api/tasks?status=queued&type=research')),
      );

      expect(response.statusCode, 200);
      final body = decodeList(await response.readAsString());
      expect(body, hasLength(1));
      expect((body.single as Map<String, dynamic>)['id'], 'queued-research');
    });

    test('filters by status', () async {
      await createTask('draft-task');
      await createTask('queued-task', autoStart: true);

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks?status=draft')));

      expect(response.statusCode, 200);
      final body = decodeList(await response.readAsString());
      expect(body, hasLength(1));
      expect((body.single as Map<String, dynamic>)['id'], 'draft-task');
    });

    test('filters by type', () async {
      await createTask('coding-task', type: TaskType.coding);
      await createTask('research-task', type: TaskType.research);

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks?type=research')));

      expect(response.statusCode, 200);
      final body = decodeList(await response.readAsString());
      expect(body, hasLength(1));
      expect((body.single as Map<String, dynamic>)['id'], 'research-task');
    });

    test('returns empty list when no matches', () async {
      await createTask('task-1');

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks?status=queued')));

      expect(response.statusCode, 200);
      expect(decodeList(await response.readAsString()), isEmpty);
    });

    test('ignores invalid filters', () async {
      await createTask('task-1');

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks?status=nope&type=missing')));

      expect(response.statusCode, 200);
      expect(decodeList(await response.readAsString()), hasLength(1));
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
        dataDir: tempDir.path,
      ).call(Request('GET', Uri.parse('http://localhost/api/tasks')));

      expect(response.statusCode, 200);
      final body = decodeList(await response.readAsString());
      final task = body.single as Map<String, dynamic>;
      expect(task['artifactDiskBytes'], 5);
    });
  });

  group('GET /api/tasks/<id>', () {
    test('returns task detail', () async {
      await createTask('task-1', title: 'Detailed task');

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks/task-1')));

      expect(response.statusCode, 200);
      final body = decodeObject(await response.readAsString());
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
        dataDir: tempDir.path,
      ).call(Request('GET', Uri.parse('http://localhost/api/tasks/task-detail')));

      expect(response.statusCode, 200);
      final body = decodeObject(await response.readAsString());
      expect(body['artifactDiskBytes'], 5);
    });

    test('returns 404 for missing task', () async {
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks/missing')));

      expect(response.statusCode, 404);
      expect(await errorCode(response), 'TASK_NOT_FOUND');
    });
  });

  group('POST /api/tasks/<id>/start', () {
    test('transitions draft to queued', () async {
      await createTask('task-1');

      final response = await handler(jsonRequest('POST', '/api/tasks/task-1/start', const {}));

      expect(response.statusCode, 200);
      final body = decodeObject(await response.readAsString());
      expect(body['status'], 'queued');
    });

    test('returns 404 for missing task', () async {
      final response = await handler(jsonRequest('POST', '/api/tasks/missing/start', const {}));

      expect(response.statusCode, 404);
      expect(await errorCode(response), 'TASK_NOT_FOUND');
    });

    test('returns 409 for invalid transition', () async {
      await createTask('task-1', autoStart: true);

      final response = await handler(jsonRequest('POST', '/api/tasks/task-1/start', const {}));

      expect(response.statusCode, 409);
      final body = decodeObject(await response.readAsString());
      expect(body['error']['code'], 'INVALID_TRANSITION');
      expect(body['error']['details']['currentStatus'], 'queued');
    });

    test('fires TaskStatusChangedEvent', () async {
      await createTask('task-1');
      final events = <TaskStatusChangedEvent>[];
      eventBus.on<TaskStatusChangedEvent>().listen(events.add);

      final response = await handler(jsonRequest('POST', '/api/tasks/task-1/start', const {}));
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

      final response = await handler(jsonRequest('POST', '/api/tasks/task-1/checkout', const {}));

      expect(response.statusCode, 200);
      final body = decodeObject(await response.readAsString());
      expect(body['status'], 'running');
    });

    test('returns 409 on concurrent checkout', () async {
      await createTask('task-1', autoStart: true);
      final first = await handler(jsonRequest('POST', '/api/tasks/task-1/checkout', const {}));
      expect(first.statusCode, 200);

      final second = await handler(jsonRequest('POST', '/api/tasks/task-1/checkout', const {}));

      expect(second.statusCode, 409);
      final body = decodeObject(await second.readAsString());
      expect(body['error']['code'], 'CHECKOUT_CONFLICT');
      expect(body['error']['details']['currentStatus'], 'running');
    });

    test('returns 404 for missing task', () async {
      final response = await handler(jsonRequest('POST', '/api/tasks/missing/checkout', const {}));

      expect(response.statusCode, 404);
      expect(await errorCode(response), 'TASK_NOT_FOUND');
    });

    test('fires TaskStatusChangedEvent with system trigger', () async {
      await createTask('task-1', autoStart: true);
      final events = <TaskStatusChangedEvent>[];
      eventBus.on<TaskStatusChangedEvent>().listen(events.add);

      final response = await handler(jsonRequest('POST', '/api/tasks/task-1/checkout', const {}));
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

      final response = await handler(jsonRequest('POST', '/api/tasks/task-1/cancel', const {}));

      expect(response.statusCode, 200);
      final body = decodeObject(await response.readAsString());
      expect(body['status'], 'cancelled');
    });

    test('returns 404 for missing task', () async {
      final response = await handler(jsonRequest('POST', '/api/tasks/missing/cancel', const {}));

      expect(response.statusCode, 404);
      expect(await errorCode(response), 'TASK_NOT_FOUND');
    });

    test('returns 409 for terminal task', () async {
      await createTask('task-1');
      await tasks.transition('task-1', TaskStatus.cancelled);

      final response = await handler(jsonRequest('POST', '/api/tasks/task-1/cancel', const {}));

      expect(response.statusCode, 409);
      expect(await errorCode(response), 'INVALID_TRANSITION');
    });

    test('fires TaskStatusChangedEvent', () async {
      await createTask('task-1', autoStart: true);
      await tasks.transition('task-1', TaskStatus.running);
      final events = <TaskStatusChangedEvent>[];
      eventBus.on<TaskStatusChangedEvent>().listen(events.add);

      final response = await handler(jsonRequest('POST', '/api/tasks/task-1/cancel', const {}));
      expect(response.statusCode, 200);
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.single.oldStatus, TaskStatus.running);
      expect(events.single.newStatus, TaskStatus.cancelled);
      expect(events.single.trigger, 'user');
    });

    test('cancels the active turn for running tasks with sessions', () async {
      final turns = _CancelTrackingTurns();
      handler = taskRoutes(tasks, turns: turns).call;
      await createTask('task-1', autoStart: true);
      await tasks.transition('task-1', TaskStatus.running);
      await tasks.updateFields('task-1', sessionId: 'session-123');

      final response = await handler(jsonRequest('POST', '/api/tasks/task-1/cancel', const {}));

      expect(response.statusCode, 200);
      expect(turns.cancelledSessions, ['session-123']);
    });

    test('cleans project-backed worktree using the selected project context', () async {
      final worktreeManager = _RecordingWorktreeManager();
      final taskFileGuard = TaskFileGuard();
      final handlerWithProjects = taskRoutes(
        tasks,
        worktreeManager: worktreeManager,
        taskFileGuard: taskFileGuard,
        projectService: makeProjectService(),
      ).call;

      await createTask('task-project', autoStart: true);
      await tasks.updateFields(
        'task-project',
        projectId: 'my-app',
        worktreeJson: const {
          'path': '/tmp/worktree-project',
          'branch': 'dartclaw/task-project',
          'createdAt': '2026-03-10T10:00:00.000Z',
        },
      );
      taskFileGuard.register('task-project', '/tmp/worktree-project');
      await tasks.transition('task-project', TaskStatus.running);

      final response = await handlerWithProjects(jsonRequest('POST', '/api/tasks/task-project/cancel', const {}));

      expect(response.statusCode, 200);
      expect(worktreeManager.cleanedTaskIds, ['task-project']);
      expect(worktreeManager.cleanedProjectIds, ['my-app']);
      expect(taskFileGuard.hasRegistration('task-project'), isFalse);
    });
  });

  group('POST /api/tasks/<id>/review', () {
    test('accepts review task', () async {
      await putTaskInReview('task-1');

      final response = await handler(jsonRequest('POST', '/api/tasks/task-1/review', {'action': 'accept'}));

      expect(response.statusCode, 200);
      final body = decodeObject(await response.readAsString());
      expect(body['status'], 'accepted');
    });

    test('rejects review task', () async {
      await putTaskInReview('task-1');

      final response = await handler(jsonRequest('POST', '/api/tasks/task-1/review', {'action': 'reject'}));

      expect(response.statusCode, 200);
      final body = decodeObject(await response.readAsString());
      expect(body['status'], 'rejected');
    });

    test('pushes back review task', () async {
      await putTaskInReview('task-1');

      final response = await handler(
        jsonRequest('POST', '/api/tasks/task-1/review', {'action': 'push_back', 'comment': 'try again'}),
      );

      expect(response.statusCode, 200);
      final body = decodeObject(await response.readAsString());
      expect(body['status'], 'running');
      expect((body['configJson'] as Map<String, dynamic>)['pushBackCount'], 1);
      expect((body['configJson'] as Map<String, dynamic>)['pushBackComment'], 'try again');
    });

    test('returns 400 when push_back comment is missing', () async {
      await putTaskInReview('task-1');

      final response = await handler(jsonRequest('POST', '/api/tasks/task-1/review', {'action': 'push_back'}));

      expect(response.statusCode, 400);
      expect(await errorCode(response), 'INVALID_INPUT');
      expect((await tasks.get('task-1'))!.status, TaskStatus.review);
    });

    test('returns 400 when push_back comment is blank', () async {
      await putTaskInReview('task-1');

      final response = await handler(
        jsonRequest('POST', '/api/tasks/task-1/review', {'action': 'push_back', 'comment': '   '}),
      );

      expect(response.statusCode, 400);
      expect(await errorCode(response), 'INVALID_INPUT');
      expect((await tasks.get('task-1'))!.status, TaskStatus.review);
    });

    test('does not persist pushBackComment when push_back loses a transition race', () async {
      final repo = InMemoryTaskRepository();
      final racingTasks = TaskService(repo);
      addTearDown(racingTasks.dispose);
      final racingHandler = taskRoutes(racingTasks).call;

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
        jsonRequest('POST', '/api/tasks/task-1/review', {'action': 'push_back', 'comment': 'try again'}),
      );

      expect(response.statusCode, 409);
      expect(await errorCode(response), 'INVALID_TRANSITION');
      final task = await racingTasks.get('task-1');
      expect(task!.status, TaskStatus.accepted);
      expect(task.configJson.containsKey('pushBackComment'), isFalse);
      expect(task.configJson.containsKey('pushBackCount'), isFalse);
    });

    test('returns 400 for invalid action', () async {
      await putTaskInReview('task-1');

      final response = await handler(jsonRequest('POST', '/api/tasks/task-1/review', {'action': 'ship_it'}));

      expect(response.statusCode, 400);
      expect(await errorCode(response), 'INVALID_INPUT');
    });

    test('returns 400 for missing action', () async {
      await putTaskInReview('task-1');

      final response = await handler(jsonRequest('POST', '/api/tasks/task-1/review', const {}));

      expect(response.statusCode, 400);
      expect(await errorCode(response), 'INVALID_INPUT');
    });

    test('returns 400 for malformed action field', () async {
      await putTaskInReview('task-1');

      final response = await handler(jsonRequest('POST', '/api/tasks/task-1/review', {'action': 123}));

      expect(response.statusCode, 400);
      expect(await errorCode(response), 'INVALID_INPUT');
    });

    test('returns 404 for missing task', () async {
      final response = await handler(jsonRequest('POST', '/api/tasks/missing/review', {'action': 'accept'}));

      expect(response.statusCode, 404);
      expect(await errorCode(response), 'TASK_NOT_FOUND');
    });

    test('returns 409 for invalid transition', () async {
      await createTask('task-1');

      final response = await handler(jsonRequest('POST', '/api/tasks/task-1/review', {'action': 'accept'}));

      expect(response.statusCode, 409);
      expect(await errorCode(response), 'INVALID_TRANSITION');
    });

    test('returns review-specific failure messages for unexpected errors', () async {
      await putTaskInReview('task-1');
      await tasks.updateFields(
        'task-1',
        worktreeJson: const {
          'path': '/tmp/worktree',
          'branch': 'dartclaw/task-task-1',
          'createdAt': '2026-03-10T10:00:00.000Z',
        },
      );
      final failingHandler = taskRoutes(tasks, mergeExecutor: _ThrowingMergeExecutor(Exception('merge exploded'))).call;

      final response = await failingHandler(jsonRequest('POST', '/api/tasks/task-1/review', {'action': 'accept'}));

      expect(response.statusCode, 500);
      final body = decodeObject(await response.readAsString());
      expect(body['error']['code'], 'INTERNAL_ERROR');
      expect(body['error']['message'], 'Review action failed. Please try again or use the web UI.');
      expect((await tasks.get('task-1'))!.status, TaskStatus.review);
    });

    test('returns a clear failure when merge infrastructure is unavailable', () async {
      await putTaskInReview('task-merge-missing');
      await tasks.updateFields(
        'task-merge-missing',
        worktreeJson: const {
          'path': '/tmp/worktree',
          'branch': 'dartclaw/task-task-merge-missing',
          'createdAt': '2026-03-10T10:00:00.000Z',
        },
      );

      final response = await handler(jsonRequest('POST', '/api/tasks/task-merge-missing/review', {'action': 'accept'}));

      expect(response.statusCode, 500);
      final body = decodeObject(await response.readAsString());
      expect(body['error']['code'], 'INTERNAL_ERROR');
      expect(
        body['error']['message'],
        'Merge infrastructure is not available. Use the web UI or configure merge support.',
      );
      expect((await tasks.get('task-merge-missing'))!.status, TaskStatus.review);
    });

    test('fires TaskStatusChangedEvent on accept', () async {
      await putTaskInReview('task-1');
      final events = <TaskStatusChangedEvent>[];
      eventBus.on<TaskStatusChangedEvent>().listen(events.add);

      final response = await handler(jsonRequest('POST', '/api/tasks/task-1/review', {'action': 'accept'}));
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
          mergeExecutor: mockMerge,
          dataDir: tempDir.path,
          mergeStrategy: 'squash',
          baseRef: 'main',
        ).call;

        final response = await mergeHandler(jsonRequest('POST', '/api/tasks/merge-1/review', {'action': 'accept'}));

        expect(response.statusCode, 200);
        final body = decodeObject(await response.readAsString());
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
          mergeExecutor: mockMerge,
          dataDir: tempDir.path,
          mergeStrategy: 'squash',
          baseRef: 'main',
        ).call;

        final response = await mergeHandler(jsonRequest('POST', '/api/tasks/merge-2/review', {'action': 'accept'}));

        expect(response.statusCode, 409);
        final body = decodeObject(await response.readAsString());
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
          mergeExecutor: mockMerge,
          dataDir: tempDir.path,
          mergeStrategy: 'squash',
          baseRef: 'main',
        ).call;

        await mergeHandler(jsonRequest('POST', '/api/tasks/merge-3/review', {'action': 'accept'}));

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
          mergeExecutor: mockMerge,
          dataDir: tempDir.path,
          mergeStrategy: 'squash',
          baseRef: 'main',
        ).call;

        final response = await mergeHandler(jsonRequest('POST', '/api/tasks/merge-4/review', {'action': 'reject'}));

        expect(response.statusCode, 200);
        final body = decodeObject(await response.readAsString());
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
          mergeExecutor: mockMerge,
          dataDir: tempDir.path,
          mergeStrategy: 'squash',
          baseRef: 'main',
        ).call;

        final response = await mergeHandler(jsonRequest('POST', '/api/tasks/merge-5/review', {'action': 'accept'}));

        expect(response.statusCode, 200);
        final body = decodeObject(await response.readAsString());
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
      expect(await errorCode(response), 'TASK_NOT_FOUND');
    });

    test('returns 409 for non-terminal task', () async {
      await createTask('task-1');

      final response = await handler(Request('DELETE', Uri.parse('http://localhost/api/tasks/task-1')));

      expect(response.statusCode, 409);
      expect(await errorCode(response), 'INVALID_STATE');
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
      final body = decodeList(await response.readAsString());
      expect(body, hasLength(1));
      expect((body.single as Map<String, dynamic>)['id'], 'artifact-1');
    });

    test('returns 404 for missing task', () async {
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks/missing/artifacts')));

      expect(response.statusCode, 404);
      expect(await errorCode(response), 'TASK_NOT_FOUND');
    });

    test('returns empty list when no artifacts', () async {
      await createTask('task-1');

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks/task-1/artifacts')));

      expect(response.statusCode, 200);
      expect(decodeList(await response.readAsString()), isEmpty);
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
      final body = decodeObject(await response.readAsString());
      expect(body['kind'], 'document');
    });

    test('returns 404 for missing artifact', () async {
      await createTask('task-1');

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks/task-1/artifacts/missing')));

      expect(response.statusCode, 404);
      expect(await errorCode(response), 'ARTIFACT_NOT_FOUND');
    });
  });
}

class _CancelTrackingTurns extends TurnManager {
  _CancelTrackingTurns()
    : super(
        messages: _ThrowingMessageService(),
        worker: FakeAgentHarness(),
        behavior: BehaviorFileService(workspaceDir: Directory.systemTemp.path),
      );

  final List<String> cancelledSessions = [];

  @override
  Future<void> cancelTurn(String sessionId) async {
    cancelledSessions.add(sessionId);
  }
}

class _ThrowingMessageService implements MessageService {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
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

class _ThrowingMergeExecutor extends MergeExecutor {
  final Object error;

  _ThrowingMergeExecutor(this.error) : super(projectDir: '/mock');

  @override
  Future<MergeResult> merge({
    required String branch,
    required String baseRef,
    required String taskId,
    required String taskTitle,
    MergeStrategy? strategy,
  }) async {
    throw error;
  }
}

class _RecordingWorktreeManager extends WorktreeManager {
  _RecordingWorktreeManager() : super(dataDir: '/tmp', projectDir: '/tmp');

  final List<String> cleanedTaskIds = [];
  final List<String?> cleanedProjectIds = [];

  @override
  Future<void> cleanup(String taskId, {Project? project}) async {
    cleanedTaskIds.add(taskId);
    cleanedProjectIds.add(project?.id);
  }
}
