import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:http/testing.dart';
import 'package:test/test.dart';

class _FakePubSubClient extends PubSubClient {
  _FakePubSubClient()
    : super(
        authClient: MockClient((request) async => throw UnimplementedError()),
        projectId: 'project',
        subscription: 'subscription',
        onMessage: (_) async => true,
      );
}

class _FakeWorkspaceEventsManager extends WorkspaceEventsManager {
  _FakeWorkspaceEventsManager(String dataDir)
    : super(
        authClient: MockClient((request) async => throw UnimplementedError()),
        config: const SpaceEventsConfig(enabled: true),
        dataDir: dataDir,
      );

  @override
  Future<void> reconcile() async {}

  @override
  void dispose() {}
}

class _FakeAdapter extends CloudEventAdapter {
  _FakeAdapter(this.result);

  final AdapterResult result;

  @override
  AdapterResult processMessage(ReceivedMessage message) => result;
}

class _FakeGoogleChatRestClient extends GoogleChatRestClient {
  _FakeGoogleChatRestClient() : super(authClient: MockClient((request) async => throw UnimplementedError()));

  final List<(String, String, String?)> sentMessages = [];
  final List<(String, String)> reactions = [];
  int _counter = 0;

  @override
  Future<String?> sendMessage(String spaceName, String text, {String? quotedMessageName}) async {
    sentMessages.add((spaceName, text, quotedMessageName));
    _counter += 1;
    return '$spaceName/messages/$_counter';
  }

  @override
  Future<String?> addReaction(String messageName, String emoji) async {
    reactions.add((messageName, emoji));
    return '$messageName/reactions/${reactions.length}';
  }
}

class _FakeChannelManager extends ChannelManager {
  _FakeChannelManager()
    : super(
        queue: MessageQueue(dispatcher: (_, _, {senderJid, senderDisplayName}) async => ''),
        config: const ChannelConfig.defaults(),
      );

  final List<ChannelMessage> handled = [];

  @override
  void handleInboundMessage(ChannelMessage message) {
    handled.add(message);
  }
}

void main() {
  late Directory tempDir;
  late _FakeGoogleChatRestClient restClient;
  late GoogleChatChannel channel;
  late _FakeChannelManager channelManager;
  late MessageDeduplicator deduplicator;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('space_events_wiring_test_');
    restClient = _FakeGoogleChatRestClient();
    channel = GoogleChatChannel(
      config: const GoogleChatConfig(typingIndicatorMode: TypingIndicatorMode.message),
      restClient: restClient,
    );
    channelManager = _FakeChannelManager();
    deduplicator = MessageDeduplicator();
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  GoogleChatSpaceEventsWiring buildWiring({
    required AdapterResult result,
    GoogleChatChannel? typingChannel,
    GoogleChatConfig? config,
  }) {
    return GoogleChatSpaceEventsWiring(
      pubSubClient: _FakePubSubClient(),
      subscriptionManager: _FakeWorkspaceEventsManager(tempDir.path),
      adapter: _FakeAdapter(result),
      deduplicator: deduplicator,
      channelManager: channelManager,
      channel: typingChannel,
      config: config,
    );
  }

  ChannelMessage testMessage({String id = 'msg-1', String messageName = 'spaces/AAAA/messages/BBBB'}) {
    return ChannelMessage(
      id: id,
      channelType: ChannelType.googlechat,
      senderJid: 'users/123',
      groupJid: 'spaces/AAAA',
      text: 'hello',
      metadata: {'spaceName': 'spaces/AAAA', 'messageName': messageName},
    );
  }

  test('sends typing indicator before dispatch when enabled', () async {
    final wiring = buildWiring(
      result: MessageResult([testMessage()]),
      typingChannel: channel,
      config: const GoogleChatConfig(typingIndicatorMode: TypingIndicatorMode.message),
    );

    final acked = await wiring.processMessage(
      const ReceivedMessage(
        ackId: 'ack',
        data: '',
        messageId: 'pubsub-1',
        publishTime: '2026-03-25T10:00:00Z',
        attributes: {},
      ),
    );

    expect(acked, isTrue);
    expect(restClient.sentMessages, [('spaces/AAAA', '_DartClaw is typing..._', null)]);
    expect(restClient.reactions, isEmpty);
    expect(channelManager.handled, hasLength(1));
  });

  test('does not send typing indicator when disabled', () async {
    final wiring = buildWiring(
      result: MessageResult([testMessage()]),
      typingChannel: channel,
      config: const GoogleChatConfig(typingIndicatorMode: TypingIndicatorMode.disabled),
    );

    await wiring.processMessage(
      const ReceivedMessage(
        ackId: 'ack',
        data: '',
        messageId: 'pubsub-1',
        publishTime: '2026-03-25T10:00:00Z',
        attributes: {},
      ),
    );

    expect(restClient.sentMessages, isEmpty);
    expect(restClient.reactions, isEmpty);
    expect(channelManager.handled, hasLength(1));
  });

  test('does not send typing indicator when channel is absent', () async {
    final wiring = buildWiring(
      result: MessageResult([testMessage()]),
      config: const GoogleChatConfig(typingIndicatorMode: TypingIndicatorMode.message),
    );

    await wiring.processMessage(
      const ReceivedMessage(
        ackId: 'ack',
        data: '',
        messageId: 'pubsub-1',
        publishTime: '2026-03-25T10:00:00Z',
        attributes: {},
      ),
    );

    expect(restClient.sentMessages, isEmpty);
    expect(restClient.reactions, isEmpty);
    expect(channelManager.handled, hasLength(1));
  });

  test('sends emoji reaction before dispatch when enabled', () async {
    final wiring = buildWiring(
      result: MessageResult([testMessage()]),
      typingChannel: channel,
      config: const GoogleChatConfig(typingIndicatorMode: TypingIndicatorMode.emoji),
    );

    await wiring.processMessage(
      const ReceivedMessage(
        ackId: 'ack',
        data: '',
        messageId: 'pubsub-1',
        publishTime: '2026-03-25T10:00:00Z',
        attributes: {},
      ),
    );

    expect(restClient.sentMessages, isEmpty);
    expect(restClient.reactions, [('spaces/AAAA/messages/BBBB', typingReactionEmoji)]);
    expect(channelManager.handled, hasLength(1));
  });

  test('dedup prevents duplicate processing', () async {
    final message = testMessage();
    deduplicator.tryProcess(message.metadata['messageName']! as String);
    final wiring = buildWiring(
      result: MessageResult([message]),
      typingChannel: channel,
      config: const GoogleChatConfig(typingIndicatorMode: TypingIndicatorMode.message),
    );

    await wiring.processMessage(
      const ReceivedMessage(
        ackId: 'ack',
        data: '',
        messageId: 'pubsub-1',
        publishTime: '2026-03-25T10:00:00Z',
        attributes: {},
      ),
    );

    expect(restClient.sentMessages, isEmpty);
    expect(restClient.reactions, isEmpty);
    expect(channelManager.handled, isEmpty);
  });
}
