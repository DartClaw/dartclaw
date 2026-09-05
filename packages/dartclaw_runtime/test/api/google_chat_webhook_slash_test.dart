import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_google_chat/testing.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

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
        'argumentText': 'investigate slow webhook',
        'text': '/new investigate slow webhook',
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
        'argumentText': 'inspect annotation payload',
        'text': '/new inspect annotation payload',
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

  test('APP_COMMAND status reads the live task and token budget services through the executor seam', () async {
    await tasks.create(
      id: 'task-live',
      title: 'Investigate webhook',
      description: 'Trace the signed ingress path',
      autoStart: true,
    );
    final kvService = KvService(filePath: '${tempDir.path}/budget-kv.json');
    await kvService.set(
      BudgetEnforcer.dateKeyForTime(DateTime.now().toUtc()),
      jsonEncode({'total_input_tokens': 300, 'total_output_tokens': 200, 'by_agent': <String, dynamic>{}}),
    );
    final budgetEnforcer = BudgetEnforcer(
      usageTracker: UsageTracker(dataDir: tempDir.path, kv: kvService),
      config: const BudgetConfig(dailyTokens: 1000, action: BudgetAction.warn, timezone: 'UTC'),
    );
    handler = _buildHandler(
      taskService: tasks,
      sessionService: sessions,
      eventBus: eventBus,
      channelManager: channelManager,
      budgetEnforcer: budgetEnforcer,
      dispatchMessage: (message) async => 'Agent reply',
    );

    final response = await _post(handler, {
      'type': 'APP_COMMAND',
      'space': {'name': 'spaces/AAAA', 'type': 'ROOM'},
      'appCommandMetadata': {'appCommandId': 3},
      'message': {'argumentText': ''},
      'user': {'name': 'users/123', 'displayName': 'Alice', 'type': 'HUMAN'},
    });
    final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
    final encodedBody = jsonEncode(body);

    expect(encodedBody, contains('Active Tasks (1)'));
    expect(encodedBody, contains('Investigate webhook'));
    expect(encodedBody, contains('Token Budget'));
    expect(encodedBody, contains('50% used — 500/1000 tokens'));
  });

  test('an APP_COMMAND in a spaceType-only DM derives the same session key as the message path', () async {
    // Both webhook events must resolve one conversation to one session, or a
    // slash command acts on a session that does not exist.
    final dmKey = channelManager.deriveSessionKey(
      ChannelMessage(
        channelType: ChannelType.googlechat,
        senderJid: 'users/123',
        text: '',
        metadata: const {'spaceName': 'spaces/AAAA'},
      ),
    );
    await sessions.getOrCreateByKey(dmKey, type: SessionType.channel);

    final response = await _post(handler, {
      'type': 'APP_COMMAND',
      'space': {'name': 'spaces/AAAA', 'spaceType': 'DIRECT_MESSAGE'},
      'appCommandMetadata': {'appCommandId': 2},
      'message': {'argumentText': ''},
      'user': {'name': 'users/123', 'displayName': 'Alice', 'type': 'HUMAN'},
    });

    final body = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
    expect(_cardHeader(body), {'title': 'Session Reset', 'subtitle': 'Confirmation'});
    // "No active session to reset." is what a group session key would answer.
    expect(jsonEncode(body), contains('Session archived'));
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

  test('APP_COMMAND reports unavailable when slash handling is not configured', () async {
    handler = _buildHandler(
      taskService: tasks,
      sessionService: sessions,
      eventBus: eventBus,
      channelManager: channelManager,
      includeSlashHandling: false,
      dispatchMessage: (message) async => 'Agent reply',
    );

    final response = await _post(handler, {
      'type': 'APP_COMMAND',
      'space': {'name': 'spaces/AAAA', 'type': 'ROOM'},
      'appCommandMetadata': {'appCommandId': 3},
      'message': {'argumentText': ''},
      'user': {'name': 'users/123', 'displayName': 'Alice', 'type': 'HUMAN'},
    });

    expect(await response.readAsString(), '{"text":"Slash commands are not available."}');
    expect(dispatchedMessage, isNull);
  });

  test('slash commands are refused by DM access control checks', () async {
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

    // A denied sender gets the same empty acknowledgement an ordinary refused
    // message gets — no card, and no session archived.
    expect(await response.readAsString(), '{}');
    expect(dispatchedMessage, isNull);
  });
}

GoogleChatWebhookHandler _buildHandler({
  required TaskService taskService,
  required SessionService sessionService,
  required EventBus eventBus,
  required ChannelManager channelManager,
  required Future<String> Function(ChannelMessage message) dispatchMessage,
  DmAccessController? dmAccess,
  BudgetEnforcer? budgetEnforcer,
  bool includeSlashHandling = true,
}) {
  final resolvedDmAccess = dmAccess ?? DmAccessController(mode: DmAccessMode.open, allowlist: const {});
  return GoogleChatWebhookHandler(
    channel: GoogleChatChannel(
      config: const GoogleChatConfig(dmAccess: DmAccessMode.open, groupAccess: GroupAccessMode.open),
      restClient: FakeGoogleChatRestClient(),
    ),
    jwtVerifier: FakeGoogleJwtVerifier(),
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
            channelManager: channelManager,
            budgetEnforcer: budgetEnforcer,
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
  new()
    : super(
        dispatcher: (sessionKey, message, {required channelType, senderJid, senderDisplayName, groupJid}) async => '',
      );

  @override
  void enqueue(ChannelMessage message, Channel channel, String sessionKey) {}
}
