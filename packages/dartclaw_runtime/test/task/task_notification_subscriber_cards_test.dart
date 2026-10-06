import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_google_chat/testing.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:test/test.dart';

/// Task notifications on Google Chat, driven through a real `GoogleChatChannel` over its REST fake: what the
/// subscriber hands the channel's declared capability is what reaches the API.
void main() {
  late TaskService tasks;
  late EventBus eventBus;
  late FakeGoogleChatRestClient restClient;
  late ChannelManager manager;
  late TaskNotificationSubscriber subscriber;

  setUp(() async {
    tasks = TaskService(InMemoryTaskRepository());
    eventBus = EventBus();
    restClient = FakeGoogleChatRestClient();
    manager = ChannelManager(queue: RecordingMessageQueue(), config: const ChannelConfig.defaults())
      ..registerChannel(GoogleChatChannel(config: const GoogleChatConfig(enabled: true), restClient: restClient));
    subscriber = TaskNotificationSubscriber(tasks: tasks, channelManager: manager);
    subscriber.subscribe(eventBus);
  });

  tearDown(() async {
    await subscriber.dispose();
    await manager.dispose();
    await eventBus.dispose();
    await tasks.dispose();
  });

  Map<String, dynamic> sentCard() {
    final card = restClient.sentCards.single.$2;
    return ((card['cardsV2'] as List).single as Map<String, dynamic>)['card'] as Map<String, dynamic>;
  }

  test('sends Google Chat review notifications as cards with review buttons', () async {
    final task = await _createChannelTask(tasks, recipientId: 'spaces/AAA', title: 'Fix login');
    await tasks.transition(task.id, TaskStatus.running);
    final review = await tasks.transition(task.id, TaskStatus.review);

    eventBus.fire(
      TaskStatusChangedEvent(
        taskId: task.id,
        oldStatus: TaskStatus.running,
        newStatus: review.status,
        trigger: 'system',
        timestamp: DateTime.parse('2026-03-13T11:00:00Z'),
      ),
    );
    await flushAsync();

    expect(restClient.sentCards.single.$1, 'spaces/AAA');
    final cardEntry = sentCard();
    final sections = cardEntry['sections'] as List;
    expect(sections, hasLength(4));
    final statusWidget =
        ((((sections.first as Map<String, dynamic>)['widgets'] as List).single
                as Map<String, dynamic>)['decoratedText'])
            as Map<String, dynamic>;
    expect(statusWidget['text'], '<font color="#f9ab00"><b>Needs Review</b></font>');
    final buttons =
        (((sections.last as Map<String, dynamic>)['widgets'] as List).single as Map<String, dynamic>)['buttonList']
            as Map<String, dynamic>;
    expect(buttons['buttons'], [
      {
        'text': 'Accept',
        'onClick': {
          'action': {
            'function': 'task_accept',
            'parameters': [
              {'key': 'taskId', 'value': task.id},
            ],
          },
        },
        'color': {'red': 0.13, 'green': 0.59, 'blue': 0.33, 'alpha': 1.0},
      },
      {
        'text': 'Reject',
        'onClick': {
          'action': {
            'function': 'task_reject',
            'parameters': [
              {'key': 'taskId', 'value': task.id},
            ],
          },
        },
        'color': {'red': 0.84, 'green': 0.18, 'blue': 0.18, 'alpha': 1.0},
      },
    ]);
  });

  test('the review fallback text still names a route for a channel without the buttons', () async {
    restClient = FakeGoogleChatRestClient(failCard: true);
    await subscriber.dispose();
    manager = ChannelManager(queue: RecordingMessageQueue(), config: const ChannelConfig.defaults())
      ..registerChannel(GoogleChatChannel(config: const GoogleChatConfig(enabled: true), restClient: restClient));
    subscriber = TaskNotificationSubscriber(tasks: tasks, channelManager: manager)..subscribe(eventBus);
    final task = await _createChannelTask(tasks, recipientId: 'spaces/AAA', title: 'Fix login');
    await tasks.transition(task.id, TaskStatus.running);
    final review = await tasks.transition(task.id, TaskStatus.review);

    eventBus.fire(
      TaskStatusChangedEvent(
        taskId: task.id,
        oldStatus: TaskStatus.running,
        newStatus: review.status,
        trigger: 'system',
        timestamp: DateTime.parse('2026-03-13T11:00:00Z'),
      ),
    );
    await flushAsync();

    expect(
      restClient.sentMessages.single.$2,
      "Task 'Fix login' needs review. Review it in the web UI, or tell me here to accept or reject it.",
    );
  });

  test('every Google Chat task card is the one ChatCardBuilder.taskNotification builds for the same task', () async {
    final task = await _createChannelTask(tasks, recipientId: 'spaces/AAA', title: 'Fix login');
    final running = await tasks.transition(task.id, TaskStatus.running);
    final timestamp = DateTime.parse('2026-03-13T10:30:00Z');

    eventBus.fire(
      TaskStatusChangedEvent(
        taskId: task.id,
        oldStatus: TaskStatus.queued,
        newStatus: running.status,
        trigger: 'system',
        timestamp: timestamp,
      ),
    );
    await flushAsync();

    expect(
      restClient.sentCards.single.$2,
      const ChatCardBuilder().taskNotification(
        taskId: task.id,
        title: 'Fix login',
        status: 'running',
        description: 'Fix login description',
        requestedBy: task.createdBy,
        createdAt: task.createdAt,
        updatedAt: timestamp,
      ),
    );
  });

  test('sends Google Chat running notifications as cards without review buttons', () async {
    final task = await _createChannelTask(tasks, recipientId: 'spaces/AAA');
    final running = await tasks.transition(task.id, TaskStatus.running);

    eventBus.fire(
      TaskStatusChangedEvent(
        taskId: task.id,
        oldStatus: TaskStatus.queued,
        newStatus: running.status,
        trigger: 'system',
        timestamp: DateTime.parse('2026-03-13T10:30:00Z'),
      ),
    );
    await flushAsync();

    expect(sentCard()['sections'] as List, hasLength(3));
  });

  test('sends Google Chat accepted notifications as cards without review buttons', () async {
    final task = await _createChannelTask(tasks, recipientId: 'spaces/AAA', title: 'Fix login');
    await tasks.transition(task.id, TaskStatus.running);
    await tasks.transition(task.id, TaskStatus.review);
    final accepted = await tasks.transition(task.id, TaskStatus.accepted);

    eventBus.fire(
      TaskStatusChangedEvent(
        taskId: task.id,
        oldStatus: TaskStatus.review,
        newStatus: accepted.status,
        trigger: 'channel',
        timestamp: DateTime.parse('2026-03-13T11:15:00Z'),
      ),
    );
    await flushAsync();

    final cardEntry = sentCard();
    expect(cardEntry['header'], {'title': 'Fix login', 'subtitle': 'Accepted'});
    final sections = cardEntry['sections'] as List;
    expect(sections, hasLength(3));
    final flattenedWidgets = sections
        .cast<Map<String, dynamic>>()
        .expand((section) => (section['widgets'] as List).cast<Map<String, dynamic>>())
        .toList();
    expect(flattenedWidgets.any((widget) => widget.containsKey('buttonList')), isFalse);
  });

  test('includes error summary in Google Chat failure cards when present', () async {
    final task = await tasks.create(
      id: 'task-1',
      title: 'Fix login',
      description: 'Fix the failing login flow',
      autoStart: true,
      configJson: {
        'origin': TaskOrigin(
          channelType: ChannelType.googlechat.name,
          sessionKey: SessionKey.dmPerChannelContact(channelType: ChannelType.googlechat.name, peerId: 'spaces/AAA'),
          recipientId: 'spaces/AAA',
        ).toJson(),
        'errorSummary': 'Token budget exceeded',
      },
      now: DateTime.parse('2026-03-13T10:00:00Z'),
    );
    final running = await tasks.transition(task.id, TaskStatus.running);
    await tasks.transition(task.id, TaskStatus.failed);

    eventBus.fire(
      TaskStatusChangedEvent(
        taskId: task.id,
        oldStatus: running.status,
        newStatus: TaskStatus.failed,
        trigger: 'system',
        timestamp: DateTime.parse('2026-03-13T11:15:00Z'),
      ),
    );
    await flushAsync();

    final cardEntry = sentCard();
    expect(cardEntry['header'], {'title': 'Fix login', 'subtitle': 'Failed'});
    final sections = cardEntry['sections'] as List;
    expect(sections, hasLength(4));
    final errorText =
        ((((sections[2] as Map<String, dynamic>)['widgets'] as List).single as Map<String, dynamic>)['textParagraph']
                as Map<String, dynamic>)['text']
            as String;
    expect(errorText, 'Token budget exceeded');
  });

  test('keeps non-Google Chat notifications as plain text responses', () async {
    final whatsapp = FakeChannel(type: ChannelType.whatsapp, ownsAllJids: true);
    final whatsappManager = ChannelManager(queue: RecordingMessageQueue(), config: const ChannelConfig.defaults())
      ..registerChannel(whatsapp);
    final whatsappSubscriber = TaskNotificationSubscriber(tasks: tasks, channelManager: whatsappManager)
      ..subscribe(eventBus);
    addTearDown(() async {
      await whatsappSubscriber.dispose();
      await whatsappManager.dispose();
    });
    // The Google Chat subscriber from setUp must not answer a WhatsApp task.
    final task = await tasks.create(
      id: 'task-1',
      title: 'Task',
      description: 'Task description',
      autoStart: true,
      configJson: {
        'origin': TaskOrigin(
          channelType: ChannelType.whatsapp.name,
          sessionKey: SessionKey.dmPerChannelContact(
            channelType: ChannelType.whatsapp.name,
            peerId: 'sender@s.whatsapp.net',
          ),
          recipientId: 'sender@s.whatsapp.net',
        ).toJson(),
      },
      now: DateTime.parse('2026-03-13T10:00:00Z'),
    );
    final running = await tasks.transition(task.id, TaskStatus.running);

    eventBus.fire(
      TaskStatusChangedEvent(
        taskId: task.id,
        oldStatus: TaskStatus.queued,
        newStatus: running.status,
        trigger: 'system',
        timestamp: DateTime.parse('2026-03-13T10:30:00Z'),
      ),
    );
    await flushAsync();

    final response = whatsapp.sentMessages.single.$2;
    expect(response.structuredPayload, isNull);
    expect(response.text, "Task 'Task' is now running.");
    expect(restClient.sentCards, isEmpty);
    expect(restClient.sentMessages, isEmpty);
  });
}

Future<Task> _createChannelTask(TaskService tasks, {required String recipientId, String title = 'Task'}) {
  return tasks.create(
    id: 'task-1',
    title: title,
    description: '$title description',
    autoStart: true,
    configJson: {
      'origin': TaskOrigin(
        channelType: ChannelType.googlechat.name,
        sessionKey: SessionKey.dmPerChannelContact(channelType: ChannelType.googlechat.name, peerId: recipientId),
        recipientId: recipientId,
      ).toJson(),
    },
    now: DateTime.parse('2026-03-13T10:00:00Z'),
  );
}
