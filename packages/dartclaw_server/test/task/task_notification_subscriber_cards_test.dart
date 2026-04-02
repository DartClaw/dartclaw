import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  late TaskService tasks;
  late EventBus eventBus;

  setUp(() {
    tasks = TaskService(SqliteTaskRepository(openTaskDbInMemory()));
    eventBus = EventBus();
  });

  tearDown(() async {
    await eventBus.dispose();
    await tasks.dispose();
  });

  test('sends Google Chat review notifications as cards with review buttons', () async {
    final channel = FakeChannel(type: ChannelType.googlechat, ownsAllJids: true);
    final manager = _buildChannelManager(channel);
    final subscriber = TaskNotificationSubscriber(tasks: tasks, channelManager: manager);
    addTearDown(() async {
      await subscriber.dispose();
      await manager.dispose();
    });
    subscriber.subscribe(eventBus);

    final task = await _createChannelTask(
      tasks,
      channelType: ChannelType.googlechat,
      recipientId: 'spaces/AAA',
      title: 'Fix login',
    );
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

    final response = channel.sentMessages.single.$2;
    expect(response.text, "Task 'Fix login' needs review. Reply 'accept' or 'reject'.");
    expect(response.structuredPayload, isNotNull);
    final cardEntry =
        (((response.structuredPayload!['cardsV2'] as List).single as Map<String, dynamic>)['card'])
            as Map<String, dynamic>;
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

  test('sends Google Chat running notifications as cards without review buttons', () async {
    final channel = FakeChannel(type: ChannelType.googlechat, ownsAllJids: true);
    final manager = _buildChannelManager(channel);
    final subscriber = TaskNotificationSubscriber(tasks: tasks, channelManager: manager);
    addTearDown(() async {
      await subscriber.dispose();
      await manager.dispose();
    });
    subscriber.subscribe(eventBus);

    final task = await _createChannelTask(tasks, channelType: ChannelType.googlechat, recipientId: 'spaces/AAA');
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

    final response = channel.sentMessages.single.$2;
    final cardEntry =
        (((response.structuredPayload!['cardsV2'] as List).single as Map<String, dynamic>)['card'])
            as Map<String, dynamic>;
    final sections = cardEntry['sections'] as List;
    expect(sections, hasLength(3));
  });

  test('sends Google Chat accepted notifications as cards without review buttons', () async {
    final channel = FakeChannel(type: ChannelType.googlechat, ownsAllJids: true);
    final manager = _buildChannelManager(channel);
    final subscriber = TaskNotificationSubscriber(tasks: tasks, channelManager: manager);
    addTearDown(() async {
      await subscriber.dispose();
      await manager.dispose();
    });
    subscriber.subscribe(eventBus);

    final task = await _createChannelTask(
      tasks,
      channelType: ChannelType.googlechat,
      recipientId: 'spaces/AAA',
      title: 'Fix login',
    );
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

    final response = channel.sentMessages.single.$2;
    expect(response.text, "Task 'Fix login' accepted.");
    expect(response.structuredPayload, isNotNull);
    final cardEntry =
        (((response.structuredPayload!['cardsV2'] as List).single as Map<String, dynamic>)['card'])
            as Map<String, dynamic>;
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
    final channel = FakeChannel(type: ChannelType.googlechat, ownsAllJids: true);
    final manager = _buildChannelManager(channel);
    final subscriber = TaskNotificationSubscriber(tasks: tasks, channelManager: manager);
    addTearDown(() async {
      await subscriber.dispose();
      await manager.dispose();
    });
    subscriber.subscribe(eventBus);

    final task = await tasks.create(
      id: 'task-1',
      title: 'Fix login',
      description: 'Fix the failing login flow',
      type: TaskType.research,
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

    final response = channel.sentMessages.single.$2;
    expect(response.text, "Task 'Fix login' failed: Token budget exceeded.");
    expect(response.structuredPayload, isNotNull);
    final cardEntry =
        (((response.structuredPayload!['cardsV2'] as List).single as Map<String, dynamic>)['card'])
            as Map<String, dynamic>;
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
    final channel = FakeChannel(type: ChannelType.whatsapp, ownsAllJids: true);
    final manager = _buildChannelManager(channel);
    final subscriber = TaskNotificationSubscriber(tasks: tasks, channelManager: manager);
    addTearDown(() async {
      await subscriber.dispose();
      await manager.dispose();
    });
    subscriber.subscribe(eventBus);

    final task = await _createChannelTask(
      tasks,
      channelType: ChannelType.whatsapp,
      recipientId: 'sender@s.whatsapp.net',
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

    final response = channel.sentMessages.single.$2;
    expect(response.structuredPayload, isNull);
    expect(response.text, "Task 'Task' is now running.");
  });

  test('falls back to plain text when card construction fails', () async {
    final channel = FakeChannel(type: ChannelType.googlechat, ownsAllJids: true);
    final manager = _buildChannelManager(channel);
    final subscriber = TaskNotificationSubscriber(
      tasks: tasks,
      channelManager: manager,
      googleChatCardBuilder: _ThrowingChatCardBuilder(),
    );
    addTearDown(() async {
      await subscriber.dispose();
      await manager.dispose();
    });
    subscriber.subscribe(eventBus);

    final task = await _createChannelTask(tasks, channelType: ChannelType.googlechat, recipientId: 'spaces/AAA');
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

    final response = channel.sentMessages.single.$2;
    expect(response.structuredPayload, isNull);
    expect(response.text, "Task 'Task' is now running.");
  });
}

ChannelManager _buildChannelManager(FakeChannel channel) {
  final manager = ChannelManager(queue: RecordingMessageQueue(), config: const ChannelConfig.defaults());
  manager.registerChannel(channel);
  return manager;
}

Future<Task> _createChannelTask(
  TaskService tasks, {
  required ChannelType channelType,
  required String recipientId,
  String title = 'Task',
}) {
  return tasks.create(
    id: 'task-1',
    title: title,
    description: '$title description',
    type: TaskType.research,
    autoStart: true,
    configJson: {
      'origin': TaskOrigin(
        channelType: channelType.name,
        sessionKey: SessionKey.dmPerChannelContact(channelType: channelType.name, peerId: recipientId),
        recipientId: recipientId,
      ).toJson(),
    },
    now: DateTime.parse('2026-03-13T10:00:00Z'),
  );
}

class _ThrowingChatCardBuilder extends ChatCardBuilder {
  @override
  Map<String, dynamic> taskNotification({
    required String taskId,
    required String title,
    required String status,
    String? description,
    String? errorSummary,
    String? requestedBy,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool includeReviewButtons = false,
  }) {
    throw StateError('boom');
  }
}
