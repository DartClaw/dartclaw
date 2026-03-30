import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

class _FakeGoogleChatRestClient extends GoogleChatRestClient {
  final List<(String, String)> sentMessages = [];
  final List<(String, String)> editedMessages = [];
  final List<(String, String)> addedReactions = [];
  int _counter = 0;

  _FakeGoogleChatRestClient() : super(authClient: MockClient((request) async => throw UnimplementedError()));

  @override
  Future<String?> sendMessage(
    String spaceName,
    String text, {
    String? quotedMessageName,
    String? quotedMessageLastUpdateTime,
  }) async {
    sentMessages.add((spaceName, text));
    _counter++;
    return '$spaceName/messages/$_counter';
  }

  @override
  Future<bool> editMessage(String messageName, String newText) async {
    editedMessages.add((messageName, newText));
    return true;
  }

  @override
  Future<String?> addReaction(String messageName, String emoji) async {
    addedReactions.add((messageName, emoji));
    return '$messageName/reactions/${addedReactions.length}';
  }

  @override
  Future<void> testConnection() async {}
}

class _FakeGoogleJwtVerifier extends GoogleJwtVerifier {
  bool shouldVerify = true;

  _FakeGoogleJwtVerifier()
    : super(
        audience: const GoogleChatAudienceConfig(
          mode: GoogleChatAudienceMode.appUrl,
          value: 'https://example.com/integrations/googlechat',
        ),
      );

  @override
  Future<bool> verify(String? authHeader) async => shouldVerify;
}

Map<String, dynamic> _payload({
  String type = 'MESSAGE',
  String? text = 'Hello agent',
  String? argumentText,
  String senderType = 'HUMAN',
  String senderName = 'users/123',
  String userName = 'users/123',
  String spaceType = 'DM',
  String? senderAvatarUrl,
  String? threadName,
  List<Map<String, dynamic>> annotations = const [],
}) {
  final message = <String, dynamic>{
    'name': 'spaces/AAAA/messages/BBBB',
    'sender': {'name': senderName, 'type': senderType, 'avatarUrl': ?senderAvatarUrl},
    'text': text,
    'annotations': annotations,
  };
  if (argumentText != null) {
    message['argumentText'] = argumentText;
  }
  if (threadName != null) {
    message['thread'] = {'name': threadName};
  }

  return {
    'type': type,
    'space': {'name': 'spaces/AAAA', 'type': spaceType, 'displayName': 'Primary'},
    'message': message,
    'user': {'name': userName, 'displayName': 'Alice', 'type': 'HUMAN'},
  };
}

Future<Response> _post(GoogleChatWebhookHandler handler, {required Object body, Map<String, String>? headers}) {
  return handler.handle(
    Request(
      'POST',
      Uri.parse('http://localhost/integrations/googlechat'),
      headers: headers ?? {'authorization': 'Bearer token'},
      body: body is String ? body : jsonEncode(body),
    ),
  );
}

ChannelManager _buildChannelManager({
  required GoogleChatChannel channel,
  required Future<String> Function(ChannelMessage message) onDispatch,
}) {
  final queue = MessageQueue(
    debounceWindow: Duration.zero,
    maxConcurrentTurns: 1,
    dispatcher: (sessionKey, message, {senderJid, senderDisplayName}) async {
      final dispatched = ChannelMessage(
        id: sessionKey,
        channelType: ChannelType.googlechat,
        senderJid: senderJid ?? '',
        text: message,
      );
      return onDispatch(dispatched);
    },
  );
  final manager = ChannelManager(queue: queue, config: const ChannelConfig.defaults());
  manager.registerChannel(channel);
  return manager;
}

void main() {
  late _FakeGoogleChatRestClient restClient;
  late GoogleChatChannel channel;
  late _FakeGoogleJwtVerifier jwtVerifier;
  late ChannelMessage? dispatchedMessage;
  late EventBus eventBus;
  late GoogleChatWebhookHandler handler;

  setUp(() {
    restClient = _FakeGoogleChatRestClient();
    channel = GoogleChatChannel(
      config: const GoogleChatConfig(
        webhookPath: '/integrations/googlechat',
        typingIndicatorMode: TypingIndicatorMode.disabled,
        dmAccess: DmAccessMode.open,
        groupAccess: GroupAccessMode.open,
      ),
      restClient: restClient,
    );
    jwtVerifier = _FakeGoogleJwtVerifier();
    eventBus = EventBus();
    dispatchedMessage = null;
    handler = GoogleChatWebhookHandler(
      channel: channel,
      jwtVerifier: jwtVerifier,
      config: const GoogleChatConfig(
        webhookPath: '/integrations/googlechat',
        typingIndicatorMode: TypingIndicatorMode.disabled,
        dmAccess: DmAccessMode.open,
        groupAccess: GroupAccessMode.open,
      ),
      eventBus: eventBus,
      dispatchMessage: (message) async {
        dispatchedMessage = message;
        return 'Agent reply';
      },
      responseTimeout: const Duration(milliseconds: 50),
    );
  });

  tearDown(() async {
    await eventBus.dispose();
  });

  group('JWT verification', () {
    test('rejects request with invalid JWT', () async {
      jwtVerifier.shouldVerify = false;
      final events = <FailedAuthEvent>[];
      final sub = eventBus.on<FailedAuthEvent>().listen(events.add);
      addTearDown(sub.cancel);

      final response = await _post(handler, body: _payload(), headers: {});

      expect(response.statusCode, 401);
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));
      expect(events.single.source, 'webhook');
      expect(events.single.reason, 'invalid_google_chat_jwt');
      expect(events.single.limited, isFalse);
    });

    test('accepts valid JWT', () async {
      final response = await _post(handler, body: _payload());

      expect(response.statusCode, 200);
      expect(await response.readAsString(), '{"text":"Agent reply"}');
    });
  });

  group('MESSAGE events', () {
    test('processes valid MESSAGE event', () async {
      await _post(handler, body: _payload());

      expect(dispatchedMessage, isNotNull);
      expect(dispatchedMessage!.senderJid, 'users/123');
      expect(dispatchedMessage!.metadata['spaceName'], 'spaces/AAAA');
    });

    test('captures thread and avatar metadata from webhook ingress', () async {
      await _post(
        handler,
        body: _payload(
          spaceType: 'ROOM',
          senderAvatarUrl: 'https://example.com/avatar.png',
          threadName: 'spaces/AAAA/threads/CCCC',
        ),
      );

      expect(dispatchedMessage, isNotNull);
      expect(dispatchedMessage!.metadata['senderAvatarUrl'], 'https://example.com/avatar.png');
      expect(dispatchedMessage!.metadata['threadName'], 'spaces/AAAA/threads/CCCC');
    });

    test('captures space display name from webhook ingress', () async {
      await _post(handler, body: _payload(spaceType: 'ROOM'));

      expect(dispatchedMessage, isNotNull);
      expect(dispatchedMessage!.metadata['spaceDisplayName'], 'Primary');
    });

    test('prefers argumentText over raw text when present', () async {
      await _post(
        handler,
        body: _payload(text: '<users/app> accept', argumentText: 'accept'),
      );

      expect(dispatchedMessage, isNotNull);
      expect(dispatchedMessage!.text, 'accept');
    });

    test('extracts group JID for ROOM spaces', () async {
      await _post(handler, body: _payload(spaceType: 'ROOM'));

      expect(dispatchedMessage!.groupJid, 'spaces/AAAA');
    });

    test('keeps DM messages without group JID', () async {
      await _post(handler, body: _payload(spaceType: 'DM'));

      expect(dispatchedMessage!.groupJid, isNull);
    });

    test('extracts mentions from annotations', () async {
      await _post(
        handler,
        body: _payload(
          annotations: [
            {
              'type': 'USER_MENTION',
              'userMention': {
                'user': {'name': 'users/999'},
              },
            },
          ],
        ),
      );

      expect(dispatchedMessage!.mentionedJids, ['users/999']);
    });

    test('filters bot messages by sender.type', () async {
      await _post(handler, body: _payload(senderType: 'BOT'));

      expect(dispatchedMessage, isNull);
    });

    test('filters bot messages by configured bot user fallback', () async {
      handler = GoogleChatWebhookHandler(
        channel: channel,
        jwtVerifier: jwtVerifier,
        config: const GoogleChatConfig(botUser: 'users/bot', typingIndicatorMode: TypingIndicatorMode.disabled),
        dispatchMessage: (message) async {
          dispatchedMessage = message;
          return 'Agent reply';
        },
      );

      await _post(handler, body: _payload(senderName: 'users/bot'));

      expect(dispatchedMessage, isNull);
    });

    test('drops empty text messages', () async {
      await _post(handler, body: _payload(text: '   '));

      expect(dispatchedMessage, isNull);
    });

    test('routes through ChannelManager when one is provided', () async {
      ChannelMessage? queuedMessage;
      var directDispatchCalls = 0;
      final disabledChannel = GoogleChatChannel(
        config: const GoogleChatConfig(
          webhookPath: '/integrations/googlechat',
          typingIndicatorMode: TypingIndicatorMode.disabled,
          dmAccess: DmAccessMode.open,
          groupAccess: GroupAccessMode.open,
        ),
        restClient: restClient,
      );
      final manager = _buildChannelManager(
        channel: disabledChannel,
        onDispatch: (message) async {
          queuedMessage = message;
          return 'Queued reply';
        },
      );
      handler = GoogleChatWebhookHandler(
        channel: disabledChannel,
        jwtVerifier: jwtVerifier,
        config: const GoogleChatConfig(
          webhookPath: '/integrations/googlechat',
          typingIndicatorMode: TypingIndicatorMode.disabled,
        ),
        channelManager: manager,
        dispatchMessage: (message) async {
          directDispatchCalls++;
          dispatchedMessage = message;
          return 'Direct reply';
        },
      );

      final response = await _post(handler, body: _payload());
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(response.statusCode, 200);
      expect(await response.readAsString(), '{}');
      expect(directDispatchCalls, 0);
      expect(dispatchedMessage, isNull);
      expect(queuedMessage, isNotNull);
      expect(queuedMessage!.senderJid, 'users/123');
      expect(restClient.sentMessages, [('spaces/AAAA', 'Queued reply')]);
    });
  });

  group('ADDED_TO_SPACE', () {
    test('sends welcome message', () async {
      final response = await _post(handler, body: _payload(type: 'ADDED_TO_SPACE'));

      expect(response.statusCode, 200);
      expect(restClient.sentMessages, [('spaces/AAAA', 'Hello! I am DartClaw. Send me a message to get started.')]);
    });
  });

  group('unknown events', () {
    test('drops other event types silently', () async {
      final response = await _post(handler, body: _payload(type: 'REMOVED_FROM_SPACE'));

      expect(response.statusCode, 200);
      expect(dispatchedMessage, isNull);
      expect(restClient.sentMessages, isEmpty);
    });
  });

  group('typing indicator', () {
    test('sends placeholder then patches on timeout when enabled', () async {
      final completer = Completer<String>();
      handler = GoogleChatWebhookHandler(
        channel: channel,
        jwtVerifier: jwtVerifier,
        config: const GoogleChatConfig(
          typingIndicatorMode: TypingIndicatorMode.message,
          dmAccess: DmAccessMode.open,
          groupAccess: GroupAccessMode.open,
        ),
        dispatchMessage: (message) {
          dispatchedMessage = message;
          return completer.future;
        },
        responseTimeout: const Duration(milliseconds: 50),
      );

      final response = await _post(handler, body: _payload());

      expect(response.statusCode, 200);
      expect(await response.readAsString(), '{}');
      expect(dispatchedMessage, isNotNull);
      expect(restClient.sentMessages, [('spaces/AAAA', '_DartClaw is typing..._')]);

      completer.complete('Final answer');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(restClient.editedMessages, [('spaces/AAAA/messages/1', 'Final answer')]);
    });

    test('keeps placeholders separate for overlapping turns in the same space', () async {
      final first = Completer<String>();
      final second = Completer<String>();
      var callCount = 0;
      handler = GoogleChatWebhookHandler(
        channel: channel,
        jwtVerifier: jwtVerifier,
        config: const GoogleChatConfig(
          typingIndicatorMode: TypingIndicatorMode.message,
          dmAccess: DmAccessMode.open,
          groupAccess: GroupAccessMode.open,
        ),
        dispatchMessage: (message) {
          dispatchedMessage = message;
          callCount++;
          return callCount == 1 ? first.future : second.future;
        },
        responseTimeout: const Duration(milliseconds: 50),
      );

      await _post(
        handler,
        body: _payload(text: 'first', senderName: 'users/123', userName: 'users/123'),
      );
      await _post(
        handler,
        body: {
          ..._payload(text: 'second', senderName: 'users/456', userName: 'users/456'),
          'message': {
            'name': 'spaces/AAAA/messages/CCCC',
            'sender': {'name': 'users/456', 'type': 'HUMAN'},
            'text': 'second',
            'annotations': const [],
          },
          'user': {'name': 'users/456', 'displayName': 'Bob', 'type': 'HUMAN'},
        },
      );

      expect(dispatchedMessage, isNotNull);
      expect(restClient.sentMessages, [
        ('spaces/AAAA', '_DartClaw is typing..._'),
        ('spaces/AAAA', '_DartClaw is typing..._'),
      ]);

      second.complete('Second answer');
      first.complete('First answer');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(restClient.editedMessages, [
        ('spaces/AAAA/messages/2', 'Second answer'),
        ('spaces/AAAA/messages/1', 'First answer'),
      ]);
    });

    test('patches placeholder for ChannelManager task-trigger acknowledgements', () async {
      final tasks = TaskService(InMemoryTaskRepository());
      addTearDown(tasks.dispose);
      final manager = ChannelManager(
        queue: MessageQueue(
          debounceWindow: Duration.zero,
          maxConcurrentTurns: 1,
          dispatcher: (sessionKey, message, {senderJid, senderDisplayName}) async => 'Queued reply',
        ),
        config: const ChannelConfig.defaults(),
        taskBridge: ChannelTaskBridge(
          taskCreator: tasks.create,
          triggerParser: const TaskTriggerParser(),
          taskTriggerConfigs: const {ChannelType.googlechat: TaskTriggerConfig(enabled: true)},
        ),
      );
      addTearDown(() => manager.dispose());
      manager.registerChannel(channel);
      handler = GoogleChatWebhookHandler(
        channel: channel,
        jwtVerifier: jwtVerifier,
        config: const GoogleChatConfig(
          webhookPath: '/integrations/googlechat',
          typingIndicatorMode: TypingIndicatorMode.message,
          dmAccess: DmAccessMode.open,
          groupAccess: GroupAccessMode.open,
        ),
        channelManager: manager,
      );

      final response = await _post(handler, body: _payload(text: 'task: investigate the outage'));

      expect(response.statusCode, 200);
      expect(await response.readAsString(), '{}');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(restClient.sentMessages, [('spaces/AAAA', '_DartClaw is typing..._')]);
      expect(restClient.editedMessages, hasLength(1));
      expect(restClient.editedMessages.single.$1, 'spaces/AAAA/messages/1');
      expect(
        restClient.editedMessages.single.$2,
        matches(
          RegExp(
            r'^Task created: investigate the outage \[research\] -- ID: [0-9a-f]{6}( -- Queued \(will start when a slot opens\))?$',
          ),
        ),
      );
    });

    test('does not send placeholder when disabled', () async {
      final completer = Completer<String>();
      final disabledChannel = GoogleChatChannel(
        config: const GoogleChatConfig(
          typingIndicatorMode: TypingIndicatorMode.disabled,
          dmAccess: DmAccessMode.open,
          groupAccess: GroupAccessMode.open,
        ),
        restClient: restClient,
      );
      handler = GoogleChatWebhookHandler(
        channel: disabledChannel,
        jwtVerifier: jwtVerifier,
        config: const GoogleChatConfig(typingIndicatorMode: TypingIndicatorMode.disabled),
        dispatchMessage: (message) => completer.future,
        responseTimeout: const Duration(milliseconds: 1),
      );

      await _post(handler, body: _payload());
      completer.complete('Final answer');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(restClient.sentMessages, [('spaces/AAAA', 'Final answer')]);
      expect(restClient.editedMessages, isEmpty);
    });

    test('uses metadata messageName for emoji typing when present', () async {
      final completer = Completer<String>();
      final emojiChannel = GoogleChatChannel(
        config: const GoogleChatConfig(
          typingIndicatorMode: TypingIndicatorMode.emoji,
          dmAccess: DmAccessMode.open,
          groupAccess: GroupAccessMode.open,
        ),
        restClient: restClient,
      );
      handler = GoogleChatWebhookHandler(
        channel: emojiChannel,
        jwtVerifier: jwtVerifier,
        config: const GoogleChatConfig(typingIndicatorMode: TypingIndicatorMode.emoji),
        channelManager: _buildChannelManager(
          channel: emojiChannel,
          onDispatch: (message) async {
            dispatchedMessage = message;
            return completer.future;
          },
        ),
      );

      final response = await _post(
        handler,
        body: _payload(text: 'Hello agent', senderName: 'users/123', userName: 'users/123'),
      );

      expect(response.statusCode, 200);
      expect(await response.readAsString(), '{}');
      expect(restClient.addedReactions, [('spaces/AAAA/messages/BBBB', '\u{1F440}')]);
    });
  });

  group('Workspace Add-on format', () {
    test('normalizes messagePayload into legacy MESSAGE event', () async {
      final addOnPayload = {
        'commonEventObject': {'hostApp': 'CHAT', 'platform': 'WEB'},
        'authorizationEventObject': {'systemIdToken': 'token'},
        'chat': {
          'user': {'name': 'users/123', 'displayName': 'Alice', 'type': 'HUMAN'},
          'eventTime': '2026-03-24T12:00:00Z',
          'messagePayload': {
            'space': {'name': 'spaces/AAAA', 'type': 'DM'},
            'message': {
              'name': 'spaces/AAAA/messages/BBBB',
              'sender': {'name': 'users/123', 'type': 'HUMAN'},
              'text': 'Hello from add-on',
              'annotations': <dynamic>[],
            },
          },
        },
      };

      await _post(handler, body: addOnPayload);

      expect(dispatchedMessage, isNotNull);
      expect(dispatchedMessage!.text, 'Hello from add-on');
      expect(dispatchedMessage!.senderJid, 'users/123');
      expect(dispatchedMessage!.metadata['spaceName'], 'spaces/AAAA');
    });

    test('normalizes addedToSpacePayload into legacy ADDED_TO_SPACE event', () async {
      final addOnPayload = {
        'commonEventObject': {'hostApp': 'CHAT'},
        'authorizationEventObject': {},
        'chat': {
          'user': {'name': 'users/123', 'displayName': 'Alice'},
          'addedToSpacePayload': {
            'space': {'name': 'spaces/AAAA', 'type': 'ROOM'},
          },
        },
      };

      final response = await _post(handler, body: addOnPayload);

      expect(response.statusCode, 200);
      expect(restClient.sentMessages, [('spaces/AAAA', 'Hello! I am DartClaw. Send me a message to get started.')]);
    });

    test('ignores add-on payload with unrecognized chat event key', () async {
      final addOnPayload = {
        'commonEventObject': {'hostApp': 'CHAT'},
        'authorizationEventObject': {},
        'chat': {
          'user': {'name': 'users/123'},
          'widgetUpdatedPayload': {
            'space': {'name': 'spaces/AAAA'},
          },
        },
      };

      final response = await _post(handler, body: addOnPayload);

      expect(response.statusCode, 200);
      expect(dispatchedMessage, isNull);
    });
  });

  group('payload edge cases', () {
    test('returns 413 for oversized payloads', () async {
      final response = await handler.handle(
        Request(
          'POST',
          Uri.parse('http://localhost/integrations/googlechat'),
          headers: {'authorization': 'Bearer token', 'content-length': '${(1024 * 1024) + 1}'},
          body: '',
        ),
      );

      expect(response.statusCode, 413);
    });

    test('handles malformed JSON gracefully', () async {
      final response = await _post(handler, body: '{not-json');

      expect(response.statusCode, 200);
      expect(await response.readAsString(), '{}');
    });
  });
}
