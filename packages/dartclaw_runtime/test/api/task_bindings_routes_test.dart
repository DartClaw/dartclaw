import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager;
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
  late ThreadBindingStore bindings;

  setUp(() async {
    db = openTaskDbInMemory();
    eventBus = EventBus();
    tasks = TaskService(
      SqliteTaskRepository(db),
      agentExecutionRepository: SqliteAgentExecutionRepository(db, eventBus: eventBus),
      executionTransactor: SqliteExecutionRepositoryTransactor(db),
      eventBus: eventBus,
    );
    tempDir = Directory.systemTemp.createTempSync('task_bindings_routes_test_');
    bindings = ThreadBindingStore(File('${tempDir.path}/thread-bindings.json'));
    await bindings.load();
    handler = taskRoutes(tasks, dataDir: tempDir.path, threadBindingStore: bindings).call;
  });

  tearDown(() async {
    await eventBus.dispose();
    await tasks.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<void> createTask(String id) => tasks.create(
    id: id,
    title: 'Task $id',
    description: 'Description for $id',
    configJson: const {'needsWorktree': true},
    now: DateTime.parse('2026-03-10T10:00:00Z'),
  );

  test('GET /api/tasks/:id/bindings returns all bindings for the task', () async {
    await createTask('task-bindings');
    final now = DateTime.parse('2026-03-10T10:00:00Z');
    for (final binding in [('googlechat', 'spaces/AAA/threads/BBB'), ('googlechat', 'spaces/AAA/threads/CCC')]) {
      await bindings.create(
        ThreadBinding(
          channelType: binding.$1,
          threadId: binding.$2,
          taskId: 'task-bindings',
          sessionKey: 'agent:main:task:task-bindings',
          createdAt: now,
          lastActivity: now,
        ),
      );
    }
    final response = await handler(jsonRequest('GET', '/api/tasks/task-bindings/bindings', null));
    expect(response.statusCode, 200);
    expect(jsonDecode(await response.readAsString()) as List<dynamic>, hasLength(2));
  });

  test('POST /api/tasks/:id/bindings creates binding and returns 201', () async {
    await createTask('task-bind');
    final response = await _postBinding(handler);
    expect(response.statusCode, 201);
    final body = decodeObject(await response.readAsString());
    expect(body['taskId'], 'task-bind');
    expect(body['channelType'], 'googlechat');
    expect(body['threadId'], 'spaces/AAA/threads/BBB');
  });

  test('POST a channel with no thread identity returns 400', () async {
    await createTask('task-bind');
    final response = await handler(
      jsonRequest('POST', '/api/tasks/task-bind/bindings', const {
        'channelType': 'whatsapp',
        'threadId': '120363000@g.us',
      }),
    );
    expect(response.statusCode, 400);
    expect(decodeObject(await response.readAsString())['error']['details']['field'], 'channelType');
    expect(bindings.lookupByThread('whatsapp', '120363000@g.us'), isNull);
  });

  test('POST duplicate binding returns 409', () async {
    await createTask('task-bind');
    await _postBinding(handler);
    expect((await _postBinding(handler)).statusCode, 409);
  });

  test('DELETE /api/tasks/:id/bindings/:channelType/:threadId removes binding', () async {
    await createTask('task-bind');
    await _postBinding(handler);
    final response = await handler(
      jsonRequest('DELETE', '/api/tasks/task-bind/bindings/googlechat/spaces/AAA/threads/BBB', null),
    );
    expect(response.statusCode, 200);
    expect(decodeObject(await response.readAsString())['deleted'], isTrue);
    expect(bindings.lookupByThread('googlechat', 'spaces/AAA/threads/BBB'), isNull);
  });

  test('POST binding updates the shared runtime store immediately', () async {
    await createTask('task-bind');
    expect((await _postBinding(handler)).statusCode, 201);
    expect(bindings.lookupByThread('googlechat', 'spaces/AAA/threads/BBB')?.taskId, 'task-bind');
  });
}

Future<Response> _postBinding(Handler handler) async => await handler(
  jsonRequest('POST', '/api/tasks/task-bind/bindings', const {
    'channelType': 'googlechat',
    'threadId': 'spaces/AAA/threads/BBB',
  }),
);
