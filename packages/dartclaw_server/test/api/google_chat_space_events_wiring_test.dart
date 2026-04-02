import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
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
  late FakeGoogleChatRestClient restClient;
  late GoogleChatChannel channel;
  late _FakeChannelManager channelManager;
  late MessageDeduplicator deduplicator;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('space_events_wiring_test_');
    restClient = FakeGoogleChatRestClient();
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

  GoogleChatSpaceEventsWiring buildWiring({required AdapterResult result, GoogleChatChannel? typingChannel}) {
    return GoogleChatSpaceEventsWiring(
      pubSubClient: _FakePubSubClient(),
      subscriptionManager: _FakeWorkspaceEventsManager(tempDir.path),
      adapter: _FakeAdapter(result),
      deduplicator: deduplicator,
      channelManager: channelManager,
      channel: typingChannel,
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
    final wiring = buildWiring(result: MessageResult([testMessage()]), typingChannel: channel);

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
    expect(restClient.sentMessages, [('spaces/AAAA', '_DartClaw is typing..._')]);
    expect(channelManager.handled, hasLength(1));
  });

  test('does not send typing indicator when disabled', () async {
    final disabledChannel = GoogleChatChannel(
      config: const GoogleChatConfig(typingIndicatorMode: TypingIndicatorMode.disabled),
      restClient: restClient,
    );
    final wiring = buildWiring(result: MessageResult([testMessage()]), typingChannel: disabledChannel);

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
    expect(channelManager.handled, hasLength(1));
  });

  test('does not send typing indicator when channel is absent', () async {
    final wiring = buildWiring(result: MessageResult([testMessage()]));

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
    expect(channelManager.handled, hasLength(1));
  });

  group('sender display name enrichment', () {
    late GoogleChatChannel disabledChannel;

    setUp(() {
      disabledChannel = GoogleChatChannel(
        config: const GoogleChatConfig(typingIndicatorMode: TypingIndicatorMode.disabled),
        restClient: restClient,
      );
    });

    test('enriches missing senderDisplayName via members API', () async {
      restClient.memberDisplayNames['users/123'] = 'Tobias';
      final wiring = buildWiring(result: MessageResult([testMessage()]), typingChannel: disabledChannel);

      await wiring.processMessage(
        const ReceivedMessage(
          ackId: 'ack',
          data: '',
          messageId: 'p-1',
          publishTime: '2026-03-28T10:00:00Z',
          attributes: {},
        ),
      );

      expect(channelManager.handled, hasLength(1));
      expect(channelManager.handled.first.metadata['senderDisplayName'], 'Tobias');
      expect(restClient.getMemberDisplayNameCalls, [('spaces/AAAA', 'users/123')]);
    });

    test('caches resolved name across messages', () async {
      restClient.memberDisplayNames['users/123'] = 'Tobias';
      final msg1 = testMessage(id: 'msg-1', messageName: 'spaces/AAAA/messages/B1');
      final msg2 = testMessage(id: 'msg-2', messageName: 'spaces/AAAA/messages/B2');
      final wiring = buildWiring(result: MessageResult([msg1, msg2]), typingChannel: disabledChannel);

      await wiring.processMessage(
        const ReceivedMessage(
          ackId: 'ack',
          data: '',
          messageId: 'p-1',
          publishTime: '2026-03-28T10:00:00Z',
          attributes: {},
        ),
      );

      expect(channelManager.handled, hasLength(2));
      expect(channelManager.handled[0].metadata['senderDisplayName'], 'Tobias');
      expect(channelManager.handled[1].metadata['senderDisplayName'], 'Tobias');
      // Only one API call — second message served from cache.
      expect(restClient.getMemberDisplayNameCalls, hasLength(1));
    });

    test('removes senderDisplayName on lookup failure', () async {
      // No entry in memberDisplayNames → returns null.
      final msg = testMessage();
      msg.metadata['senderDisplayName'] = 'users/123'; // raw ID from adapter
      final wiring = buildWiring(result: MessageResult([msg]), typingChannel: disabledChannel);

      await wiring.processMessage(
        const ReceivedMessage(
          ackId: 'ack',
          data: '',
          messageId: 'p-1',
          publishTime: '2026-03-28T10:00:00Z',
          attributes: {},
        ),
      );

      expect(channelManager.handled, hasLength(1));
      expect(channelManager.handled.first.metadata.containsKey('senderDisplayName'), isFalse);
    });

    test('skips enrichment when senderDisplayName already resolved', () async {
      restClient.memberDisplayNames['users/123'] = 'API Name';
      final msg = testMessage();
      msg.metadata['senderDisplayName'] = 'Webhook Name'; // already populated
      final wiring = buildWiring(result: MessageResult([msg]), typingChannel: disabledChannel);

      await wiring.processMessage(
        const ReceivedMessage(
          ackId: 'ack',
          data: '',
          messageId: 'p-1',
          publishTime: '2026-03-28T10:00:00Z',
          attributes: {},
        ),
      );

      expect(channelManager.handled.first.metadata['senderDisplayName'], 'Webhook Name');
      expect(restClient.getMemberDisplayNameCalls, isEmpty);
    });
  });

  test('dedup prevents duplicate processing', () async {
    final message = testMessage();
    deduplicator.tryProcess(message.metadata['messageName']! as String);
    final wiring = buildWiring(result: MessageResult([message]), typingChannel: channel);

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
    expect(channelManager.handled, isEmpty);
  });
}
