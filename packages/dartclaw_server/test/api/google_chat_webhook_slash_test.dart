import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:http/testing.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

class _FakeGoogleChatRestClient extends GoogleChatRestClient {
  _FakeGoogleChatRestClient() : super(authClient: MockClient((request) async => throw UnimplementedError()));

  @override
  Future<void> testConnection() async {}
}

class _FakeGoogleJwtVerifier extends GoogleJwtVerifier {
  _FakeGoogleJwtVerifier()
    : super(
        audience: const GoogleChatAudienceConfig(
          mode: GoogleChatAudienceMode.appUrl,
          value: 'https://example.com/integrations/googlechat',
        ),
      );

  @override
  Future<bool> verify(String? authHeader) async => true;
}

void main() {
  late Directory tempDir;
  late EventBus eventBus;
  late TaskService tasks;
  late SessionService sessions;
  late ChannelManager channelManager;
  late GoogleChatWebhookHandler handler;
  late ChannelMessage? dispatchedMessage;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('google_chat_webhook_slash_test_');
    eventBus = EventBus();
    tasks = TaskService(SqliteTaskRepository(openTaskDbInMemory()));
    sessions = SessionService(baseDir: tempDir.path, eventBus: eventBus);
    channelManager = ChannelManager(queue: _NoopMessageQueue(), config: const ChannelConfig.defaults());
    dispatchedMessage = null;
    handler = _buildHandler(
      taskService: tasks,
      sessionService: sessions,
      eventBus: eventBus,
      channelManager: channelManager,
      dispatchMessage: (message) async {
        dispatchedMessage = message;
        return 'Agent reply';
      },
    );
  });

  tearDown(() async {
    await channelManager.dispose();
    await tasks.dispose();
    await eventBus.dispose();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('MESSAGE slash commands are routed to the handler and return cards', () async {
    final response = await _post(handler, {
      'type': 'MESSAGE',
      'space': {'name': 'spaces/AAAA', 'type': 'DM'},
      'message': {
        'name': 'spaces/AAAA/messages/BBBB',
        'sender': {'name': 'users/123', 'type': 'HUMAN'},
        'slashCommand': {'commandId': 1},
        'argumentText': 'analysis: investigate slow webhook',
        'text': '/new analysis: investigate slow webhook',
      },
      'user': {'name': 'users/123', 'displayName': 'Alice', 'type': 'HUMAN'},
    });

    final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;

    expect(dispatchedMessage, isNull);
    expect((await tasks.list()), hasLength(1));
    expect(body['cardsV2'], isA<List<dynamic>>());
    expect(_cardHeader(body), {
      'title': 'Task created: investigate slow webhook -- Queued (will start when a slot opens)',
      'subtitle': 'queued',
    });
  });

  test('MESSAGE slash commands are routed from annotations when message.slashCommand is absent', () async {
    final response = await _post(handler, {
      'type': 'MESSAGE',
      'space': {'name': 'spaces/AAAA', 'type': 'DM'},
      'message': {
        'name': 'spaces/AAAA/messages/BBBB',
        'sender': {'name': 'users/123', 'type': 'HUMAN'},
        'annotations': [
          {
            'type': 'SLASH_COMMAND',
            'slashCommand': {'commandId': 1},
          },
        ],
        'argumentText': 'analysis: inspect annotation payload',
        'text': '/new analysis: inspect annotation payload',
      },
      'user': {'name': 'users/123', 'displayName': 'Alice', 'type': 'HUMAN'},
    });

    final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;

    expect(dispatchedMessage, isNull);
    expect((await tasks.list()), hasLength(1));
    expect(body['cardsV2'], isA<List<dynamic>>());
    expect(_cardHeader(body), {
      'title': 'Task created: inspect annotation payload -- Queued (will start when a slot opens)',
      'subtitle': 'queued',
    });
  });

  test('APP_COMMAND slash commands are routed to the handler and return cards', () async {
    final response = await _post(handler, {
      'type': 'APP_COMMAND',
      'space': {'name': 'spaces/AAAA', 'type': 'ROOM'},
      'appCommandMetadata': {'appCommandId': 3},
      'message': {'argumentText': ''},
      'user': {'name': 'users/123', 'displayName': 'Alice', 'type': 'HUMAN'},
    });

    final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;

    expect(body['cardsV2'], isA<List<dynamic>>());
    expect(_cardHeader(body), {'title': 'DartClaw Status', 'subtitle': 'Current overview'});
  });

  test('MESSAGE /stop slash commands are routed to emergency stop handling', () async {
    final response = await _post(handler, {
      'type': 'MESSAGE',
      'space': {'name': 'spaces/AAAA', 'type': 'ROOM'},
      'message': {
        'name': 'spaces/AAAA/messages/BBBB',
        'sender': {'name': 'users/123', 'type': 'HUMAN'},
        'slashCommand': {'commandId': 4},
        'text': '/stop',
      },
      'user': {'name': 'users/123', 'displayName': 'Alice', 'type': 'HUMAN'},
    });

    final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;

    expect(dispatchedMessage, isNull);
    expect(body['cardsV2'], isA<List<dynamic>>());
    expect(_cardHeader(body), {'title': 'Emergency Stop', 'subtitle': 'Confirmation'});
  });

  test('unknown numeric MESSAGE slash commands are routed to unknown command handling', () async {
    final response = await _post(handler, {
      'type': 'MESSAGE',
      'space': {'name': 'spaces/AAAA', 'type': 'DM'},
      'message': {
        'name': 'spaces/AAAA/messages/BBBB',
        'sender': {'name': 'users/123', 'type': 'HUMAN'},
        'slashCommand': {'commandId': 99},
        'text': '/mystery',
      },
      'user': {'name': 'users/123', 'displayName': 'Alice', 'type': 'HUMAN'},
    });

    final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;

    expect(dispatchedMessage, isNull);
    expect((await tasks.list()), isEmpty);
    expect(body['cardsV2'], isA<List<dynamic>>());
    expect(_cardHeader(body), {'title': 'Unknown Command', 'subtitle': 'Error'});
  });

  test('unknown numeric APP_COMMAND slash commands are routed to unknown command handling', () async {
    final response = await _post(handler, {
      'type': 'APP_COMMAND',
      'space': {'name': 'spaces/AAAA', 'type': 'ROOM'},
      'appCommandMetadata': {'appCommandId': 99},
      'message': {'argumentText': ''},
      'user': {'name': 'users/123', 'displayName': 'Alice', 'type': 'HUMAN'},
    });

    final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;

    expect(dispatchedMessage, isNull);
    expect((await tasks.list()), isEmpty);
    expect(body['cardsV2'], isA<List<dynamic>>());
    expect(_cardHeader(body), {'title': 'Unknown Command', 'subtitle': 'Error'});
  });

  test('MESSAGE without slash metadata uses normal message flow', () async {
    final response = await _post(handler, {
      'type': 'MESSAGE',
      'space': {'name': 'spaces/AAAA', 'type': 'DM'},
      'message': {
        'name': 'spaces/AAAA/messages/BBBB',
        'sender': {'name': 'users/123', 'type': 'HUMAN'},
        'text': 'hello there',
      },
      'user': {'name': 'users/123', 'displayName': 'Alice', 'type': 'HUMAN'},
    });

    expect(await response.readAsString(), '{"text":"Agent reply"}');
    expect(dispatchedMessage, isNotNull);
    expect((await tasks.list()), isEmpty);
  });

  test('MESSAGE slash commands fall back to normal flow when slash handling is not configured', () async {
    handler = _buildHandler(
      taskService: tasks,
      sessionService: sessions,
      eventBus: eventBus,
      channelManager: channelManager,
      includeSlashHandling: false,
      dispatchMessage: (message) async {
        dispatchedMessage = message;
        return 'Agent reply';
      },
    );

    final response = await _post(handler, {
      'type': 'MESSAGE',
      'space': {'name': 'spaces/AAAA', 'type': 'DM'},
      'message': {
        'name': 'spaces/AAAA/messages/BBBB',
        'sender': {'name': 'users/123', 'type': 'HUMAN'},
        'slashCommand': {'commandId': 1},
        'argumentText': 'research: inspect auth logs',
        'text': '/new research: inspect auth logs',
      },
      'user': {'name': 'users/123', 'displayName': 'Alice', 'type': 'HUMAN'},
    });

    expect(await response.readAsString(), '{"text":"Agent reply"}');
    expect(dispatchedMessage, isNotNull);
    expect((await tasks.list()), isEmpty);
  });

  test('slash commands bypass DM access control checks', () async {
    handler = _buildHandler(
      taskService: tasks,
      sessionService: sessions,
      eventBus: eventBus,
      channelManager: channelManager,
      dmAccess: DmAccessController(mode: DmAccessMode.allowlist, allowlist: const {}),
      dispatchMessage: (message) async {
        dispatchedMessage = message;
        return 'Agent reply';
      },
    );

    final response = await _post(handler, {
      'type': 'MESSAGE',
      'space': {'name': 'spaces/AAAA', 'type': 'DM'},
      'message': {
        'name': 'spaces/AAAA/messages/BBBB',
        'sender': {'name': 'users/999', 'type': 'HUMAN'},
        'slashCommand': {'commandId': 2},
        'text': '/reset',
      },
      'user': {'name': 'users/999', 'displayName': 'Mallory', 'type': 'HUMAN'},
    });

    final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;

    expect(dispatchedMessage, isNull);
    expect(body['cardsV2'], isA<List<dynamic>>());
    expect(_cardHeader(body), {'title': 'Session Reset', 'subtitle': 'Confirmation'});
  });
}

GoogleChatWebhookHandler _buildHandler({
  required TaskService taskService,
  required SessionService sessionService,
  required EventBus eventBus,
  required ChannelManager channelManager,
  required Future<String> Function(ChannelMessage message) dispatchMessage,
  DmAccessController? dmAccess,
  bool includeSlashHandling = true,
}) {
  final resolvedDmAccess = dmAccess ?? DmAccessController(mode: DmAccessMode.open, allowlist: const {});
  return GoogleChatWebhookHandler(
    channel: GoogleChatChannel(
      config: const GoogleChatConfig(dmAccess: DmAccessMode.open, groupAccess: GroupAccessMode.open),
      restClient: _FakeGoogleChatRestClient(),
    ),
    jwtVerifier: _FakeGoogleJwtVerifier(),
    config: const GoogleChatConfig(dmAccess: DmAccessMode.open, groupAccess: GroupAccessMode.open),
    channelManager: null,
    dispatchMessage: dispatchMessage,
    dmAccess: resolvedDmAccess,
    eventBus: eventBus,
    slashCommandParser: includeSlashHandling ? const SlashCommandParser() : null,
    slashCommandHandler: includeSlashHandling
        ? SlashCommandHandler(
            taskService: taskService,
            sessionService: sessionService,
            eventBus: eventBus,
            channelManager: channelManager,
            onEmergencyStop: (stoppedBy) async => const EmergencyStopResult(turnsCancelled: 1, tasksCancelled: 2),
          )
        : null,
  );
}

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

Map<String, dynamic> _cardHeader(Map<String, dynamic> responseBody) {
  return (((responseBody['cardsV2'] as List).single as Map<String, dynamic>)['card'] as Map<String, dynamic>)['header']
      as Map<String, dynamic>;
}

class _NoopMessageQueue extends MessageQueue {
  _NoopMessageQueue() : super(dispatcher: (sessionKey, message, {senderJid, senderDisplayName}) async => '');

  @override
  void enqueue(ChannelMessage message, Channel channel, String sessionKey) {}
}
