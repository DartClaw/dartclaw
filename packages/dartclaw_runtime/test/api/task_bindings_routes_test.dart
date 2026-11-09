import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show ChannelConfig, ChannelType;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager;
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'api_test_helpers.dart';

void main() {
  late TaskService tasks;
  late EventBus eventBus;
  late Handler handler;
  late Directory tempDir;
  late ThreadBindingStore bindings;
  late ChannelManager channels;

  setUp(() async {
    eventBus = EventBus();
    tasks = TaskService(
      InMemoryTaskRepository(),
      agentExecutionRepository: InMemoryAgentExecutionRepository(),
      executionTransactor: const InMemoryExecutionRepositoryTransactor(),
      eventBus: eventBus,
    );
    tempDir = Directory.systemTemp.createTempSync('task_bindings_routes_test_');
    bindings = ThreadBindingStore(File('${tempDir.path}/thread-bindings.json'));
    await bindings.load();
    channels = ChannelManager(queue: RecordingMessageQueue(), config: const ChannelConfig.defaults())
      ..registerChannel(
        FakeChannel(name: 'gchat', type: ChannelType.googlechat, threadedNotifications: FakeThreadedNotifications()),
      )
      ..registerChannel(FakeChannel(name: 'wa', type: ChannelType.whatsapp));
    handler = taskRoutes(tasks, dataDir: tempDir.path, threadBindingStore: bindings, channelManager: channels).call;
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
        ThreadBinding.task(
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

  test('POST a channel type that is not registered returns 400 as carrying no thread identity', () async {
    await createTask('task-bind');
    final response = await handler(
      jsonRequest('POST', '/api/tasks/task-bind/bindings', const {'channelType': 'slack', 'threadId': 'C1:1.5'}),
    );
    expect(response.statusCode, 400);
    expect(bindings.lookupByThread('slack', 'C1:1.5'), isNull);
  });

  test('POST on a thread a workflow run holds returns 409 naming the run, and DELETE never removes it', () async {
    await createTask('task-bind');
    final now = DateTime.parse('2026-03-10T10:00:00Z');
    await bindings.create(
      ThreadBinding.run(
        channelType: 'googlechat',
        threadId: 'spaces/AAA/threads/BBB',
        runId: 'run-3',
        createdAt: now,
        lastActivity: now,
      ),
    );

    final conflict = await _postBinding(handler);
    final deleted = await handler(
      jsonRequest('DELETE', '/api/tasks/run-3/bindings/googlechat/spaces/AAA/threads/BBB', null),
    );

    expect(conflict.statusCode, 409);
    expect(await conflict.readAsString(), contains('run-3'));
    expect(deleted.statusCode, 404);
    expect(bindings.lookupByRun('run-3'), hasLength(1));
    expect(bindings.lookupByTask('task-bind'), isEmpty);
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
    expect(bindings.lookupByThread('googlechat', 'spaces/AAA/threads/BBB')?.targetId, 'task-bind');
  });
}

Future<Response> _postBinding(Handler handler) async => await handler(
  jsonRequest('POST', '/api/tasks/task-bind/bindings', const {
    'channelType': 'googlechat',
    'threadId': 'spaces/AAA/threads/BBB',
  }),
);
