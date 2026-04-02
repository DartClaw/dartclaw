import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

Future<Response> _post(GoogleChatWebhookHandler handler, Object payload) {
  return handler.handle(
    Request(
      'POST',
      Uri.parse('http://localhost/integrations/googlechat'),
      headers: const {'authorization': 'Bearer token'},
      body: jsonEncode(payload),
    ),
  );
}

void main() {
  late TaskService tasks;
  late EventBus eventBus;
  late FakeGoogleChatRestClient restClient;
  late GoogleChatChannel channel;
  late ChannelManager manager;
  late TaskReviewService reviewService;
  late TaskNotificationSubscriber notificationSubscriber;
  late GoogleChatWebhookHandler webhookHandler;

  setUp(() {
    eventBus = EventBus();
    tasks = TaskService(SqliteTaskRepository(openTaskDbInMemory()), eventBus: eventBus);
    restClient = FakeGoogleChatRestClient();
    channel = GoogleChatChannel(
      config: const GoogleChatConfig(dmAccess: DmAccessMode.open, groupAccess: GroupAccessMode.open),
      restClient: restClient,
    );
    manager = ChannelManager(queue: RecordingMessageQueue(), config: const ChannelConfig.defaults());
    manager.registerChannel(channel);
    reviewService = TaskReviewService(tasks: tasks);
    notificationSubscriber = TaskNotificationSubscriber(tasks: tasks, channelManager: manager);
    notificationSubscriber.subscribe(eventBus);
    webhookHandler = GoogleChatWebhookHandler(
      channel: channel,
      jwtVerifier: FakeGoogleJwtVerifier(),
      config: const GoogleChatConfig(dmAccess: DmAccessMode.open, groupAccess: GroupAccessMode.open),
      reviewHandler: reviewService.channelReviewHandler(trigger: 'channel'),
    );
  });

  tearDown(() async {
    await notificationSubscriber.dispose();
    await manager.dispose();
    await eventBus.dispose();
    await tasks.dispose();
  });

  test('review transition sends a card and card click accepts the task', () async {
    final task = await tasks.create(
      id: 'task-1',
      title: 'Fix login',
      description: 'Review the final patch.',
      type: TaskType.coding,
      autoStart: true,
      configJson: {
        'origin': TaskOrigin(
          channelType: ChannelType.googlechat.name,
          sessionKey: SessionKey.dmPerChannelContact(channelType: ChannelType.googlechat.name, peerId: 'spaces/AAA'),
          recipientId: 'spaces/AAA',
        ).toJson(),
      },
      now: DateTime.parse('2026-03-13T10:00:00Z'),
    );
    await tasks.transition(task.id, TaskStatus.running);
    await tasks.transition(task.id, TaskStatus.review);
    // TaskService.transition() now fires TaskStatusChangedEvent automatically.
    // Allow async review-ready event to complete.
    await flushAsync();

    // At least one notification card was sent for the running→review transition.
    // (There may also be a card for queued→running.)
    final reviewCards = restClient.sentCards.where((c) {
      final card = ((c.$2['cardsV2'] as List).single as Map<String, dynamic>)['card'] as Map<String, dynamic>;
      final header = card['header'] as Map<String, dynamic>;
      return header['subtitle'] == 'Needs Review';
    }).toList();
    expect(reviewCards, hasLength(1));
    final notificationPayload = reviewCards.single.$2;
    final reviewCard =
        ((notificationPayload['cardsV2'] as List).single as Map<String, dynamic>)['card'] as Map<String, dynamic>;
    final sections = reviewCard['sections'] as List;
    expect(sections, hasLength(4));
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

    final response = await _post(webhookHandler, {
      'type': 'CARD_CLICKED',
      'space': {'name': 'spaces/AAA'},
      'common': {
        'invokedFunction': 'task_accept',
        'parameters': [
          {'key': 'taskId', 'value': task.id},
        ],
      },
      'user': {'name': 'users/123', 'displayName': 'Alice'},
    });
    final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
    await flushAsync();

    expect((await tasks.get(task.id))!.status, TaskStatus.accepted);
    expect(body['cardsV2'], isA<List<dynamic>>());
    // 3 cards total: queued→running, running→review, review→accepted.
    // TaskService.transition() fires events for all status changes.
    expect(restClient.sentCards, hasLength(3));
    final acceptedNotification =
        ((restClient.sentCards.last.$2['cardsV2'] as List).single as Map<String, dynamic>)['card']
            as Map<String, dynamic>;
    expect(acceptedNotification['header'], {'title': 'Fix login', 'subtitle': 'Accepted'});
    final acceptedSections = acceptedNotification['sections'] as List;
    expect(acceptedSections, hasLength(3));
    expect(
      acceptedSections
          .cast<Map<String, dynamic>>()
          .expand((section) => (section['widgets'] as List).cast<Map<String, dynamic>>())
          .any((widget) => widget.containsKey('buttonList')),
      isFalse,
    );
  });
}
