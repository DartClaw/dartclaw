import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/alerts/alert_delivery_adapter.dart';
import 'package:dartclaw_server/src/alerts/alert_router.dart';
import 'package:dartclaw_server/src/api/task_sse_routes.dart';
import 'package:dartclaw_server/src/task/task_service.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

class _FakeAdapter extends AlertDeliveryAdapter {
  final List<(AlertTarget, ChannelResponse)> delivered = [];

  _FakeAdapter() : super((_) => null);

  @override
  Future<void> deliver(AlertTarget target, ChannelResponse response) async {
    delivered.add((target, response));
  }
}

void main() {
  late Database db;
  late EventBus eventBus;
  late TaskService tasks;
  late ThreadBindingStore threadBindingStore;
  late ThreadBindingLifecycleManager lifecycleManager;
  late AlertRouter alertRouter;
  late _FakeAdapter adapter;
  late Handler handler;
  late Directory tempDir;

  setUp(() async {
    db = openTaskDbInMemory();
    eventBus = EventBus();
    tasks = TaskService(SqliteTaskRepository(db), eventBus: eventBus);
    tempDir = Directory.systemTemp.createTempSync('agent_execution_boundary_replay_test_');
    threadBindingStore = ThreadBindingStore(File('${tempDir.path}/thread-bindings.json'));
    await threadBindingStore.load();
    lifecycleManager = ThreadBindingLifecycleManager(store: threadBindingStore, eventBus: eventBus);
    lifecycleManager.start();
    adapter = _FakeAdapter();
    alertRouter = AlertRouter(
      bus: eventBus,
      adapter: adapter,
      config: const AlertsConfig(
        enabled: true,
        targets: [AlertTarget(channel: 'signal', recipient: '+2000')],
        routes: {
          'task_failure': ['0'],
        },
        cooldownSeconds: 300,
        burstThreshold: 5,
      ),
      taskLookup: tasks.get,
    );
    handler = taskSseRoutes(tasks, eventBus).call;
  });

  tearDown(() async {
    await alertRouter.cancel();
    lifecycleManager.dispose();
    await eventBus.dispose();
    await tasks.dispose();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  Future<Map<String, dynamic>> nextFrame(StreamIterator<String> iterator) async {
    final hasFrame = await iterator.moveNext().timeout(const Duration(seconds: 1));
    expect(hasFrame, isTrue);
    final dataLine = iterator.current.trim().split('\n').first;
    return jsonDecode(dataLine.substring('data: '.length)) as Map<String, dynamic>;
  }

  test('replay across AlertRouter, ThreadBindingLifecycleManager, and TaskSseRoutes stays stable', () async {
    final task = await tasks.create(
      id: 'task-1',
      title: 'Replay task',
      description: 'Fail deterministically',
      type: TaskType.coding,
      autoStart: true,
      createdBy: 'operator',
      now: DateTime.parse('2026-03-10T10:00:00Z'),
    );
    await tasks.transition(task.id, TaskStatus.running, now: DateTime.parse('2026-03-10T10:01:00Z'));
    await threadBindingStore.create(
      ThreadBinding(
        channelType: 'googlechat',
        threadId: 'spaces/AAA/threads/BBB',
        taskId: task.id,
        sessionKey: 'agent:main:task:${task.id}',
        createdAt: DateTime.parse('2026-03-10T10:00:00Z'),
        lastActivity: DateTime.parse('2026-03-10T10:01:00Z'),
      ),
    );

    final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks/events')));
    final iterator = StreamIterator(response.read().transform(utf8.decoder));
    addTearDown(iterator.cancel);
    await nextFrame(iterator);

    await tasks.transition(task.id, TaskStatus.failed, now: DateTime.parse('2026-03-10T10:02:00Z'));
    final ssePayload = await nextFrame(iterator);
    await Future<void>.delayed(Duration.zero);

    final replay = <String, dynamic>{
      'alerts': adapter.delivered
          .map(
            (entry) => {
              'channel': entry.$1.channel,
              'recipient': entry.$1.recipient,
              'text': entry.$2.text,
            },
          )
          .toList(growable: false),
      'bindingRemoved': threadBindingStore.lookupByThread('googlechat', 'spaces/AAA/threads/BBB') == null,
      'taskSsePayload': ssePayload,
    };

    expect(
      jsonEncode(replay),
      equals(
        '{"alerts":[{"channel":"signal","recipient":"+2000","text":"[WARNING] Task Failure: Task task-1 failed (trigger: system)"}],'
        '"bindingRemoved":true,'
        '"taskSsePayload":{"type":"task_status_changed","taskId":"task-1","oldStatus":"running","newStatus":"failed","trigger":"system","timestamp":"2026-03-10T10:02:00.000Z","reviewCount":0,"activeTasks":[]}}',
      ),
    );
  });
}
