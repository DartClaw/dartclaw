import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeChannel, InMemoryTaskRepository;
import 'package:test/test.dart';

void main() {
  group('ChannelManager task trigger bridge', () {
    late _RecordingMessageQueue queue;
    late FakeChannel channel;
    late InMemoryTaskRepository repo;
    late TaskService tasks;
    late EventBus eventBus;
    late ChannelManager manager;

    setUp(() {
      queue = _RecordingMessageQueue();
      channel = FakeChannel(ownedJids: {'sender@s.whatsapp.net'});
      repo = InMemoryTaskRepository();
      tasks = TaskService(repo);
      eventBus = EventBus();
      manager = ChannelManager(
        queue: queue,
        config: const ChannelConfig.defaults(),
        taskService: tasks,
        triggerParser: const TaskTriggerParser(),
        eventBus: eventBus,
        taskTriggerConfigs: const {ChannelType.whatsapp: TaskTriggerConfig(enabled: true)},
      );
      manager.registerChannel(channel);
    });

    tearDown(() async {
      await manager.dispose();
      await eventBus.dispose();
      await tasks.dispose();
    });

    test('creates task, bypasses queue, stores origin, and sends acknowledgement', () async {
      final events = <TaskStatusChangedEvent>[];
      final sub = eventBus.on<TaskStatusChangedEvent>().listen(events.add);
      addTearDown(sub.cancel);

      manager.handleInboundMessage(
        ChannelMessage(
          channelType: ChannelType.whatsapp,
          senderJid: 'sender@s.whatsapp.net',
          text: 'task: fix login redirect',
          metadata: const {sourceMessageIdMetadataKey: 'wamid-123'},
        ),
      );
      await _flushAsync();

      final created = (await tasks.list()).single;
      final origin = TaskOrigin.fromConfigJson(created.configJson);

      expect(queue.enqueued, isEmpty);
      expect(created.title, 'fix login redirect');
      expect(created.description, 'fix login redirect');
      expect(created.type, TaskType.research);
      expect(created.status, TaskStatus.queued);
      expect(origin, isNotNull);
      expect(origin!.channelType, 'whatsapp');
      expect(origin.recipientId, 'sender@s.whatsapp.net');
      expect(origin.contactId, 'sender@s.whatsapp.net');
      expect(origin.sourceMessageId, 'wamid-123');
      expect(channel.sentMessages, hasLength(1));
      expect(channel.sentMessages.single.$1, 'sender@s.whatsapp.net');
      expect(
        channel.sentMessages.single.$2.text,
        'Task created: fix login redirect [research] -- ID: ${_shortTaskId(created.id)}',
      );
      expect(channel.sentMessages.single.$2.metadata, containsPair(sourceMessageIdMetadataKey, 'wamid-123'));
      expect(events, hasLength(1));
      expect(events.single.oldStatus, TaskStatus.draft);
      expect(events.single.newStatus, TaskStatus.queued);
      expect(events.single.trigger, 'channel');
    });

    test('does not intercept when trigger is disabled', () async {
      manager = ChannelManager(
        queue: queue,
        config: const ChannelConfig.defaults(),
        taskService: tasks,
        triggerParser: const TaskTriggerParser(),
        taskTriggerConfigs: const {ChannelType.whatsapp: TaskTriggerConfig(enabled: false)},
      );
      manager.registerChannel(channel);

      manager.handleInboundMessage(
        ChannelMessage(
          channelType: ChannelType.whatsapp,
          senderJid: 'sender@s.whatsapp.net',
          text: 'task: fix login redirect',
        ),
      );

      expect(queue.enqueued, hasLength(1));
      expect((await tasks.list()), isEmpty);
      expect(channel.sentMessages, isEmpty);
    });

    test('does not intercept non-trigger messages', () async {
      manager.handleInboundMessage(
        ChannelMessage(
          channelType: ChannelType.whatsapp,
          senderJid: 'sender@s.whatsapp.net',
          text: 'just a normal message',
        ),
      );

      expect(queue.enqueued, hasLength(1));
      expect((await tasks.list()), isEmpty);
      expect(channel.sentMessages, isEmpty);
    });

    test('rejects empty description without enqueueing', () async {
      manager.handleInboundMessage(
        ChannelMessage(
          channelType: ChannelType.whatsapp,
          senderJid: 'sender@s.whatsapp.net',
          text: 'task:   ',
          metadata: const {sourceMessageIdMetadataKey: 'wamid-empty'},
        ),
      );
      await _flushAsync();

      expect(queue.enqueued, isEmpty);
      expect((await tasks.list()), isEmpty);
      expect(channel.sentMessages, hasLength(1));
      expect(channel.sentMessages.single.$2.text, 'Could not create task -- description required.');
      expect(channel.sentMessages.single.$2.metadata, containsPair(sourceMessageIdMetadataKey, 'wamid-empty'));
    });

    test('rejects explicit typed triggers without a description without enqueueing', () async {
      manager.handleInboundMessage(
        ChannelMessage(
          channelType: ChannelType.whatsapp,
          senderJid: 'sender@s.whatsapp.net',
          text: 'task: coding:',
          metadata: const {sourceMessageIdMetadataKey: 'wamid-typed-empty'},
        ),
      );
      await _flushAsync();

      expect(queue.enqueued, isEmpty);
      expect((await tasks.list()), isEmpty);
      expect(channel.sentMessages, hasLength(1));
      expect(channel.sentMessages.single.$2.text, 'Could not create task -- description required.');
      expect(channel.sentMessages.single.$2.metadata, containsPair(sourceMessageIdMetadataKey, 'wamid-typed-empty'));
    });

    test('replies service unavailable when task service is missing', () async {
      manager = ChannelManager(
        queue: queue,
        config: const ChannelConfig.defaults(),
        triggerParser: const TaskTriggerParser(),
        taskTriggerConfigs: const {ChannelType.whatsapp: TaskTriggerConfig(enabled: true)},
      );
      manager.registerChannel(channel);

      manager.handleInboundMessage(
        ChannelMessage(
          channelType: ChannelType.whatsapp,
          senderJid: 'sender@s.whatsapp.net',
          text: 'task: fix login redirect',
        ),
      );
      await _flushAsync();

      expect(queue.enqueued, isEmpty);
      expect(channel.sentMessages, hasLength(1));
      expect(channel.sentMessages.single.$2.text, 'Could not create task -- service unavailable.');
    });

    test('replies service unavailable when task creation throws', () async {
      final failingService = _FailingTaskService();
      addTearDown(failingService.dispose);

      manager = ChannelManager(
        queue: queue,
        config: const ChannelConfig.defaults(),
        taskService: failingService,
        triggerParser: const TaskTriggerParser(),
        taskTriggerConfigs: const {ChannelType.whatsapp: TaskTriggerConfig(enabled: true)},
      );
      manager.registerChannel(channel);

      manager.handleInboundMessage(
        ChannelMessage(
          channelType: ChannelType.whatsapp,
          senderJid: 'sender@s.whatsapp.net',
          text: 'task: fix login redirect',
        ),
      );
      await _flushAsync();

      expect(queue.enqueued, isEmpty);
      expect(channel.sentMessages, hasLength(1));
      expect(channel.sentMessages.single.$2.text, 'Could not create task -- service unavailable.');
    });

    test('respects autoStart false and creates draft task', () async {
      manager = ChannelManager(
        queue: queue,
        config: const ChannelConfig.defaults(),
        taskService: tasks,
        triggerParser: const TaskTriggerParser(),
        eventBus: eventBus,
        taskTriggerConfigs: const {ChannelType.whatsapp: TaskTriggerConfig(enabled: true, autoStart: false)},
      );
      manager.registerChannel(channel);

      manager.handleInboundMessage(
        ChannelMessage(
          channelType: ChannelType.whatsapp,
          senderJid: 'sender@s.whatsapp.net',
          text: 'task: writing: draft release notes',
        ),
      );
      await _flushAsync();

      final created = (await tasks.list()).single;
      expect(created.status, TaskStatus.draft);
      expect(created.type, TaskType.writing);
      expect(
        channel.sentMessages.single.$2.text,
        'Task drafted: draft release notes [writing] -- ID: ${_shortTaskId(created.id)}',
      );
    });

    test('uses group recipient ids for group messages', () async {
      channel = FakeChannel(ownedJids: {'group@g.us'});
      manager = ChannelManager(
        queue: queue,
        config: const ChannelConfig.defaults(),
        taskService: tasks,
        triggerParser: const TaskTriggerParser(),
        taskTriggerConfigs: const {ChannelType.whatsapp: TaskTriggerConfig(enabled: true)},
      );
      manager.registerChannel(channel);

      manager.handleInboundMessage(
        ChannelMessage(
          channelType: ChannelType.whatsapp,
          senderJid: 'sender@s.whatsapp.net',
          groupJid: 'group@g.us',
          text: 'task: triage the incident',
        ),
      );
      await _flushAsync();

      final created = (await tasks.list()).single;
      final origin = TaskOrigin.fromConfigJson(created.configJson)!;
      expect(origin.recipientId, 'group@g.us');
      expect(origin.contactId, 'sender@s.whatsapp.net');
      expect(channel.sentMessages.single.$1, 'group@g.us');
    });

    test('uses spaceName recipient ids for google chat messages', () async {
      final googleChatQueue = _RecordingMessageQueue();
      final googleChatTasks = TaskService(InMemoryTaskRepository());
      addTearDown(googleChatTasks.dispose);
      final googleChatChannel = FakeChannel(type: ChannelType.googlechat, ownedJids: {'spaces/AAAA'});
      final googleChatManager = ChannelManager(
        queue: googleChatQueue,
        config: const ChannelConfig.defaults(),
        taskService: googleChatTasks,
        triggerParser: const TaskTriggerParser(),
        taskTriggerConfigs: const {ChannelType.googlechat: TaskTriggerConfig(enabled: true)},
      );
      addTearDown(() => googleChatManager.dispose());
      googleChatManager.registerChannel(googleChatChannel);

      googleChatManager.handleInboundMessage(
        ChannelMessage(
          id: 'spaces/AAAA/messages/BBBB',
          channelType: ChannelType.googlechat,
          senderJid: 'users/123',
          text: 'task: investigate the outage',
          metadata: const {'spaceName': 'spaces/AAAA'},
        ),
      );
      await _flushAsync();

      final created = (await googleChatTasks.list()).single;
      final origin = TaskOrigin.fromConfigJson(created.configJson)!;
      expect(origin.recipientId, 'spaces/AAAA');
      expect(origin.contactId, 'users/123');
      expect(origin.sourceMessageId, 'spaces/AAAA/messages/BBBB');
      expect(googleChatChannel.sentMessages.single.$1, 'spaces/AAAA');
      expect(
        googleChatChannel.sentMessages.single.$2.metadata,
        containsPair(sourceMessageIdMetadataKey, 'spaces/AAAA/messages/BBBB'),
      );
      expect(googleChatQueue.enqueued, isEmpty);
    });
  });
}

Future<void> _flushAsync() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

String _shortTaskId(String taskId) => taskId.replaceAll('-', '').substring(0, 6);

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

class _FailingTaskService extends TaskService {
  _FailingTaskService() : super(InMemoryTaskRepository());

  @override
  Future<Task> create({
    required String id,
    required String title,
    required String description,
    required TaskType type,
    bool autoStart = false,
    String? goalId,
    String? acceptanceCriteria,
    Map<String, dynamic> configJson = const {},
    DateTime? now,
  }) {
    throw StateError('service unavailable');
  }
}
