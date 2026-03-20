import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:test/test.dart';

void main() {
  late TaskService tasks;
  late EventBus eventBus;
  late _FakeChannel channel;
  late _RecordingMessageQueue queue;
  late ChannelManager channelManager;
  late TaskNotificationSubscriber subscriber;

  setUp(() {
    tasks = TaskService(SqliteTaskRepository(openTaskDbInMemory()));
    eventBus = EventBus();
    queue = _RecordingMessageQueue();
    channel = _FakeChannel(ownedJids: {'sender@s.whatsapp.net'});
    channelManager = ChannelManager(
      queue: queue,
      config: const ChannelConfig.defaults(),
      taskCreator: tasks.create,
      taskLister: tasks.list,
      triggerParser: const TaskTriggerParser(),
      eventBus: eventBus,
      taskTriggerConfigs: const {ChannelType.whatsapp: TaskTriggerConfig(enabled: true)},
    );
    channelManager.registerChannel(channel);
    subscriber = TaskNotificationSubscriber(tasks: tasks, channelManager: channelManager);
    subscriber.subscribe(eventBus);
  });

  tearDown(() async {
    await subscriber.dispose();
    await channelManager.dispose();
    await eventBus.dispose();
    await tasks.dispose();
  });

  test('integration: channel message creates task and later notifies the originating channel', () async {
    channelManager.handleInboundMessage(
      ChannelMessage(
        channelType: ChannelType.whatsapp,
        senderJid: 'sender@s.whatsapp.net',
        text: 'task: fix the login bug',
      ),
    );
    await _flushAsync();

    final task = (await tasks.list()).single;
    expect(queue.enqueued, isEmpty);
    expect(channel.sentMessages, hasLength(1));
    expect(
      channel.sentMessages.first.$2.text,
      'Task created: fix the login bug [research] -- ID: ${_shortTaskId(task.id)}',
    );

    final running = await tasks.transition(task.id, TaskStatus.running);
    eventBus.fire(
      TaskStatusChangedEvent(
        taskId: task.id,
        oldStatus: TaskStatus.queued,
        newStatus: running.status,
        trigger: 'system',
        timestamp: DateTime.now(),
      ),
    );
    await _flushAsync();

    expect(channel.sentMessages, hasLength(2));
    expect(channel.sentMessages.last.$1, 'sender@s.whatsapp.net');
    expect(channel.sentMessages.last.$2.text, "Task 'fix the login bug' is now running.");
  });

  test('sends review notification for channel-originated tasks', () async {
    final task = await _createChannelTask(tasks);
    await tasks.transition(task.id, TaskStatus.running);
    final review = await tasks.transition(task.id, TaskStatus.review);

    eventBus.fire(
      TaskStatusChangedEvent(
        taskId: task.id,
        oldStatus: TaskStatus.running,
        newStatus: review.status,
        trigger: 'system',
        timestamp: DateTime.now(),
      ),
    );
    await _flushAsync();

    expect(channel.sentMessages.single.$2.text, "Task '${task.title}' needs review. Reply 'accept' or 'reject'.");
  });

  test('sends accepted and rejected notifications for review outcomes', () async {
    final cases = <(String, TaskStatus, String)>[
      ('task-accepted', TaskStatus.accepted, "Task 'Task' accepted."),
      ('task-rejected', TaskStatus.rejected, "Task 'Task' rejected. Changes discarded."),
    ];

    for (final (taskId, terminalStatus, expectedText) in cases) {
      channel.sentMessages.clear();
      final task = await tasks.create(
        id: taskId,
        title: 'Task',
        description: 'Task',
        type: TaskType.research,
        autoStart: true,
        configJson: {'origin': _originJson()},
      );
      await tasks.transition(task.id, TaskStatus.running);
      final review = await tasks.transition(task.id, TaskStatus.review);
      final terminal = await tasks.transition(task.id, terminalStatus);

      eventBus.fire(
        TaskStatusChangedEvent(
          taskId: task.id,
          oldStatus: review.status,
          newStatus: terminal.status,
          trigger: 'system',
          timestamp: DateTime.now(),
        ),
      );
      await _flushAsync();

      expect(channel.sentMessages, hasLength(1));
      expect(channel.sentMessages.single.$1, 'sender@s.whatsapp.net');
      expect(channel.sentMessages.single.$2.text, expectedText);
    }
  });

  test('keeps merge wording for accepted worktree-backed tasks', () async {
    final task = await tasks.create(
      id: 'task-accepted-worktree',
      title: 'Task',
      description: 'Task',
      type: TaskType.coding,
      autoStart: true,
      configJson: {'origin': _originJson()},
    );
    await tasks.updateFields(
      task.id,
      worktreeJson: const {
        'path': '/tmp/worktree',
        'branch': 'dartclaw/task-task-accepted-worktree',
        'createdAt': '2026-03-13T10:00:00.000Z',
      },
    );
    await tasks.transition(task.id, TaskStatus.running);
    final review = await tasks.transition(task.id, TaskStatus.review);
    final accepted = await tasks.transition(task.id, TaskStatus.accepted);

    eventBus.fire(
      TaskStatusChangedEvent(
        taskId: task.id,
        oldStatus: review.status,
        newStatus: accepted.status,
        trigger: 'system',
        timestamp: DateTime.now(),
      ),
    );
    await _flushAsync();

    expect(channel.sentMessages.single.$2.text, "Task 'Task' accepted. Changes merged.");
  });

  test('does not notify for non-channel tasks', () async {
    final task = await tasks.create(
      id: 'task-1',
      title: 'Task',
      description: 'Description',
      type: TaskType.coding,
      autoStart: true,
    );
    final running = await tasks.transition(task.id, TaskStatus.running);

    eventBus.fire(
      TaskStatusChangedEvent(
        taskId: task.id,
        oldStatus: TaskStatus.queued,
        newStatus: running.status,
        trigger: 'system',
        timestamp: DateTime.now(),
      ),
    );
    await _flushAsync();

    expect(channel.sentMessages, isEmpty);
  });

  test('ignores non-notifiable transitions', () async {
    final task = await _createChannelTask(tasks, autoStart: false);

    eventBus.fire(
      TaskStatusChangedEvent(
        taskId: task.id,
        oldStatus: TaskStatus.draft,
        newStatus: TaskStatus.draft,
        trigger: 'channel',
        timestamp: DateTime.now(),
      ),
    );
    await _flushAsync();

    expect(channel.sentMessages, isEmpty);
  });

  test('handles channel delivery failures without throwing', () async {
    channel.throwOnSend = true;
    final task = await _createChannelTask(tasks);
    await tasks.transition(task.id, TaskStatus.running);
    final review = await tasks.transition(task.id, TaskStatus.review);

    eventBus.fire(
      TaskStatusChangedEvent(
        taskId: task.id,
        oldStatus: TaskStatus.running,
        newStatus: review.status,
        trigger: 'system',
        timestamp: DateTime.now(),
      ),
    );
    await _flushAsync();

    expect((await tasks.get(task.id))!.status, TaskStatus.review);
  });

  test('ignores unknown channel types in task origin', () async {
    final task = await tasks.create(
      id: 'task-1',
      title: 'Task',
      description: 'Description',
      type: TaskType.research,
      autoStart: true,
      configJson: const {
        'origin': {'channelType': 'bogus', 'sessionKey': 'agent:main:dm:contact:alice', 'recipientId': 'alice'},
      },
    );
    final running = await tasks.transition(task.id, TaskStatus.running);

    eventBus.fire(
      TaskStatusChangedEvent(
        taskId: task.id,
        oldStatus: TaskStatus.queued,
        newStatus: running.status,
        trigger: 'system',
        timestamp: DateTime.now(),
      ),
    );
    await _flushAsync();

    expect(channel.sentMessages, isEmpty);
  });

  test('formats failure notifications with error summaries when present', () async {
    final task = await tasks.create(
      id: 'task-1',
      title: 'Task',
      description: 'Description',
      type: TaskType.research,
      autoStart: true,
      configJson: {'origin': _originJson(), 'errorSummary': 'token budget exceeded'},
    );
    final running = await tasks.transition(task.id, TaskStatus.running);
    await tasks.transition(task.id, TaskStatus.failed);

    eventBus.fire(
      TaskStatusChangedEvent(
        taskId: task.id,
        oldStatus: running.status,
        newStatus: TaskStatus.failed,
        trigger: 'system',
        timestamp: DateTime.now(),
      ),
    );
    await _flushAsync();

    expect(channel.sentMessages.single.$2.text, "Task 'Task' failed: token budget exceeded.");
  });
}

Future<void> _flushAsync() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

String _shortTaskId(String taskId) => taskId.replaceAll('-', '').substring(0, 6);

Map<String, dynamic> _originJson({String recipientId = 'sender@s.whatsapp.net'}) => {
  'channelType': 'whatsapp',
  'sessionKey': 'agent:main:dm:contact:${Uri.encodeComponent(recipientId)}',
  'recipientId': recipientId,
  'contactId': recipientId,
};

class _FakeChannel extends Channel {
  @override
  final String name = 'fake';
  @override
  final ChannelType type = ChannelType.whatsapp;
  final Set<String> ownedJids;
  bool throwOnSend = false;
  final List<(String, ChannelResponse)> sentMessages = [];

  _FakeChannel({this.ownedJids = const {}});

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  bool ownsJid(String jid) => ownedJids.contains(jid);

  @override
  Future<void> sendMessage(String recipientJid, ChannelResponse response) async {
    if (throwOnSend) {
      throw StateError('send failed');
    }
    sentMessages.add((recipientJid, response));
  }
}

class _RecordingMessageQueue extends MessageQueue {
  final List<(ChannelMessage, Channel, String)> enqueued = [];

  _RecordingMessageQueue() : super(dispatcher: (sessionKey, message, {senderJid}) async => 'ok');

  @override
  void enqueue(ChannelMessage message, Channel sourceChannel, String sessionKey) {
    enqueued.add((message, sourceChannel, sessionKey));
  }

  @override
  void dispose() {}
}

Future<Task> _createChannelTask(TaskService tasks, {bool autoStart = true}) {
  return tasks.create(
    id: 'task-1',
    title: 'Task',
    description: 'Task',
    type: TaskType.research,
    autoStart: autoStart,
    configJson: {'origin': _originJson()},
  );
}
