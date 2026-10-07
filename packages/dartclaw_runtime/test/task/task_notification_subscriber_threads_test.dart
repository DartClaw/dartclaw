import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_google_chat/testing.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_slack/dartclaw_slack.dart';
import 'package:dartclaw_slack/testing.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:logging/logging.dart';
import 'package:test/test.dart';

void main() {
  late TaskService tasks;
  late EventBus eventBus;
  late Directory tempDir;
  late ThreadBindingStore store;
  late List<LogRecord> logs;
  late StreamSubscription<LogRecord> logSubscription;

  setUp(() async {
    tasks = TaskService(InMemoryTaskRepository());
    eventBus = EventBus();
    tempDir = Directory.systemTemp.createTempSync('task_notification_threads_test_');
    store = ThreadBindingStore(File('${tempDir.path}/thread-bindings.json'));
    await store.load();
    logs = [];
    Logger.root.level = Level.ALL;
    logSubscription = Logger.root.onRecord.listen(logs.add);
  });

  tearDown(() async {
    await logSubscription.cancel();
    await eventBus.dispose();
    await tasks.dispose();
    tempDir.deleteSync(recursive: true);
  });

  ChannelManager managerOf(List<Channel> channels, {bool bridge = false}) {
    final manager = ChannelManager(
      queue: RecordingMessageQueue(),
      config: const ChannelConfig.defaults(),
      taskBridge: bridge ? ChannelTaskBridge(threadBindings: store, threadBindingEnabled: true) : null,
    );
    for (final channel in channels) {
      manager.registerChannel(channel);
    }
    return manager;
  }

  TaskNotificationSubscriber subscribeWith(ChannelManager manager, {bool threads = true}) {
    final subscriber = TaskNotificationSubscriber(
      tasks: tasks,
      channelManager: manager,
      threadBindings: store,
      threadBindingEnabled: threads,
    );
    subscriber.subscribe(eventBus);
    addTearDown(subscriber.dispose);
    return subscriber;
  }

  Future<Task> channelTask(ChannelType type, String recipientId) {
    return tasks.create(
      id: 'task-1',
      title: 'Fix login',
      description: 'Fix the login flow',
      autoStart: true,
      configJson: {
        'origin': TaskOrigin(
          channelType: type.name,
          sessionKey: SessionKey.dmPerChannelContact(channelType: type.name, peerId: recipientId),
          recipientId: recipientId,
        ).toJson(),
      },
      now: DateTime.parse('2026-03-13T10:00:00Z'),
    );
  }

  Future<void> fire(Task task, TaskStatus from, TaskStatus to) async {
    final moved = await tasks.transition(task.id, to);
    eventBus.fire(
      TaskStatusChangedEvent(
        taskId: task.id,
        oldStatus: from,
        newStatus: moved.status,
        trigger: 'system',
        timestamp: DateTime.parse('2026-03-13T10:30:00Z'),
      ),
    );
    await flushAsync();
  }

  group('through a fake capability', () {
    late FakeThreadedNotifications declared;
    late FakeChannel channel;

    setUp(() {
      declared = FakeThreadedNotifications();
      channel = FakeChannel(type: ChannelType.slack, ownsAllJids: true, threadedNotifications: declared);
    });

    test('the first notification opens a keyed thread and binds it, later ones reuse the bound thread', () async {
      subscribeWith(managerOf([channel]));
      final task = await channelTask(ChannelType.slack, 'C1');

      await fire(task, TaskStatus.queued, TaskStatus.running);
      await fire(task, TaskStatus.running, TaskStatus.review);

      expect(declared.sends, hasLength(2));
      final opened = declared.sends.first;
      expect((opened.recipientId, opened.threadKey, opened.threadId), ('C1', 'task-task-1', null));
      final binding = store.lookupByTask(task.id).single;
      expect(binding.channelType, 'slack');
      expect(binding.threadId, opened.post!.threadId);
      expect(binding.sessionKey, SessionKey.dmPerChannelContact(channelType: 'slack', peerId: 'C1'));
      final reused = declared.sends.last;
      expect((reused.recipientId, reused.threadKey, reused.threadId), ('C1', null, binding.threadId));
      expect(channel.sentMessages, isEmpty, reason: 'a threaded notification is not also sent plain');
      expect(declared.rendered.map((n) => n.status), ['running', 'review']);
      expect(declared.rendered.last.reviewActions, isTrue);
    });

    test('with thread binding off the rendered notification goes out in no thread and binds nothing', () async {
      subscribeWith(managerOf([channel]), threads: false);
      final task = await channelTask(ChannelType.slack, 'C1');

      await fire(task, TaskStatus.queued, TaskStatus.running);

      expect(declared.sends, isEmpty);
      expect(channel.sentMessages.single.$1, 'C1');
      expect(channel.sentMessages.single.$2.structuredPayload, {'fakeCard': 'Fix login'});
      expect(store.lookupByTask(task.id), isEmpty);
    });

    test('a notification after the thread was never bound goes out in no thread', () async {
      subscribeWith(managerOf([channel]));
      final task = await channelTask(ChannelType.slack, 'C1');
      await tasks.transition(task.id, TaskStatus.running);

      await fire(task, TaskStatus.running, TaskStatus.review);

      expect(declared.sends, isEmpty);
      expect(channel.sentMessages, hasLength(1));
    });

    test('a new-thread send that returns no thread identity falls back to one plain send and warns once', () async {
      declared.newThreadReturnsNull = true;
      subscribeWith(managerOf([channel]));
      final task = await channelTask(ChannelType.slack, 'C1');

      await fire(task, TaskStatus.queued, TaskStatus.running);

      expect(channel.sentMessages.single.$2.text, "Task 'Fix login' is now running.");
      expect(channel.sentMessages.single.$2.structuredPayload, isNull);
      expect(store.lookupByTask(task.id), isEmpty);
      expect(logs.where((r) => r.level == Level.WARNING && r.message.contains('task task-1')), hasLength(1));
    });

    test(
      'a failed send into the bound thread is dropped with a warning and never repeated as a plain message',
      () async {
        subscribeWith(managerOf([channel]));
        final task = await channelTask(ChannelType.slack, 'C1');
        await fire(task, TaskStatus.queued, TaskStatus.running);
        declared.existingThreadReturnsNull = true;

        await fire(task, TaskStatus.running, TaskStatus.review);

        expect(channel.sentMessages, isEmpty);
        expect(logs.where((r) => r.level == Level.WARNING && r.message.contains('task task-1')), hasLength(1));
      },
    );

    test('a throwing channel never fails the handler and leaves the task untouched', () async {
      declared.sendError = StateError('disconnected');
      subscribeWith(managerOf([channel]));
      final task = await channelTask(ChannelType.slack, 'C1');

      await fire(task, TaskStatus.queued, TaskStatus.running);

      expect((await tasks.get(task.id))!.status, TaskStatus.running);
      expect(store.lookupByTask(task.id), isEmpty);
    });
  });

  test('a channel that declares no capability gets one plain send of the text and no thread or binding', () async {
    final whatsapp = FakeChannel(type: ChannelType.whatsapp, ownsAllJids: true);
    subscribeWith(managerOf([whatsapp]));
    final task = await channelTask(ChannelType.whatsapp, 'sender@s.whatsapp.net');

    await fire(task, TaskStatus.queued, TaskStatus.running);

    final (recipient, response) = whatsapp.sentMessages.single;
    expect(recipient, 'sender@s.whatsapp.net');
    expect(response.text, "Task 'Fix login' is now running.");
    expect(response.structuredPayload, isNull);
    expect(store.lookupByTask(task.id), isEmpty);
  });

  test(
    'Google Chat opens a thread keyed task-<id>, binds its server name, and later cards go to that thread',
    () async {
      final sends = <({String? threadKey, String? threadName, bool card})>[];
      final restClient = FakeGoogleChatRestClient(
        onSend:
            ({
              required spaceName,
              text,
              card,
              threadKey,
              threadName,
              quotedMessageName,
              quotedMessageLastUpdateTime,
              textWithoutQuote,
              fallbackOnQuoteFailure = true,
            }) async {
              sends.add((threadKey: threadKey, threadName: threadName, card: card != null));
              return (
                messageName: '$spaceName/messages/m${sends.length}',
                threadName: threadName ?? '$spaceName/threads/server-assigned',
                usedQuotedMessageMetadata: false,
              );
            },
      );
      final channel = GoogleChatChannel(config: const GoogleChatConfig(enabled: true), restClient: restClient);
      subscribeWith(managerOf([channel]));
      final task = await channelTask(ChannelType.googlechat, 'spaces/AAA');

      await fire(task, TaskStatus.queued, TaskStatus.running);
      await fire(task, TaskStatus.running, TaskStatus.review);

      expect(sends, [
        (threadKey: 'task-task-1', threadName: null, card: true),
        (threadKey: null, threadName: 'spaces/AAA/threads/server-assigned', card: true),
      ]);
      final binding = store.lookupByTask(task.id).single;
      expect((binding.channelType, binding.threadId), ('googlechat', 'spaces/AAA/threads/server-assigned'));
    },
  );

  test(
    'a Slack task opens a thread in its conversation and a reply in it routes to the task without a mention',
    () async {
      final api = FakeSlackWebApi();
      final queue = RecordingMessageQueue();
      final manager = ChannelManager(
        queue: queue,
        config: const ChannelConfig.defaults(),
        taskBridge: ChannelTaskBridge(threadBindings: store, threadBindingEnabled: true),
      );
      final slackChannel = SlackChannel(
        config: SlackConfig(
          enabled: true,
          dmAccess: DmAccessMode.allowlist,
          dmAllowlist: [const GroupEntry(id: 'U1')],
          groupAccess: GroupAccessMode.allowlist,
          groupAllowlist: [const GroupEntry(id: 'C1')],
        ),
        api: api,
        dmAccess: DmAccessController(mode: DmAccessMode.allowlist, allowlist: {'U1'}),
        mentionGating: MentionGating(requireMention: true, mentionPatterns: const [], ownJid: ''),
        channelManager: manager,
      );
      manager.registerChannel(slackChannel);
      subscribeWith(manager);
      final task = await channelTask(ChannelType.slack, 'C1');

      await fire(task, TaskStatus.queued, TaskStatus.running);
      await fire(task, TaskStatus.running, TaskStatus.review);

      expect(api.posts, hasLength(2));
      final first = api.posts.first;
      expect((first.channel, first.threadTs), ('C1', null), reason: 'the first notification opens the thread');
      expect(first.blocks, isNotEmpty);
      final threadTs = '1700000000.000000';
      expect(store.lookupByTask(task.id).single.threadId, 'C1:$threadTs');
      expect(api.posts.last.threadTs, threadTs, reason: 'the review notification lands in the same thread');

      await slackChannel.dispatch.dispatch(
        SlackEnvelope(
          kind: SlackEnvelopeKind.event,
          payload: {
            'event': {
              'type': 'message',
              'user': 'U1',
              'channel': 'C1',
              'channel_type': 'channel',
              'ts': '1700000100.000200',
              'thread_ts': threadTs,
              'text': 'looks good, accept it',
            },
          },
        ),
      );
      // Routing a bound message persists the binding's activity before it enqueues, which is file I/O.
      for (var i = 0; i < 100 && queue.enqueued.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(queue.enqueued, hasLength(1), reason: 'a reply with no mention is admitted into the opened thread');
      expect(
        queue.enqueued.single.sessionKey,
        SessionKey.dmPerChannelContact(channelType: 'slack', peerId: 'C1'),
        reason: 'the reply routes to the session of the task, not to a session of its own thread',
      );
    },
  );
}
