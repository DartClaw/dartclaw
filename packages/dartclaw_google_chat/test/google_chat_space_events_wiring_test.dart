import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_google_chat/testing.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:http/testing.dart';
import 'package:test/test.dart';

class _FakePubSubClient extends PubSubClient {
  new()
    : super(
        authClient: MockClient((request) async => throw UnimplementedError()),
        projectId: 'project',
        subscription: 'subscription',
        onMessage: (_) async => true,
      );
}

class _FakeWorkspaceEventsManager extends WorkspaceEventsManager {
  new(String dataDir)
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
  new(this.result);

  final AdapterResult result;

  @override
  AdapterResult processMessage(ReceivedMessage message) => result;
}

void main() {
  late Directory tempDir;
  late FakeGoogleChatRestClient restClient;
  late GoogleChatChannel channel;
  late FakeChannelManager channelManager;
  late MessageDeduplicator deduplicator;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('space_events_wiring_test_');
    restClient = FakeGoogleChatRestClient();
    channel = GoogleChatChannel(
      config: const GoogleChatConfig(
        typingIndicatorMode: TypingIndicatorMode.message,
        groupAccess: GroupAccessMode.open,
      ),
      restClient: restClient,
    );
    channelManager = FakeChannelManager();
    deduplicator = MessageDeduplicator();
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  GoogleChatSpaceEventsWiring buildWiring({required AdapterResult result, required GoogleChatChannel typingChannel}) {
    return GoogleChatSpaceEventsWiring(
      pubSubClient: _FakePubSubClient(),
      subscriptionManager: _FakeWorkspaceEventsManager(tempDir.path),
      adapter: _FakeAdapter(result),
      deduplicator: deduplicator,
      channelManager: channelManager,
      channel: typingChannel,
    );
  }

  GoogleChatChannel gatedChannel({
    GroupAccessMode groupAccess = GroupAccessMode.open,
    List<GroupEntry> groupAllowlist = const [],
    MentionGating? mentionGating,
  }) {
    return GoogleChatChannel(
      config: GoogleChatConfig(
        typingIndicatorMode: TypingIndicatorMode.message,
        groupAccess: groupAccess,
        groupAllowlist: groupAllowlist,
      ),
      restClient: restClient,
      mentionGating: mentionGating,
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
    expect(channelManager.received, hasLength(1));
  });

  test('does not send typing indicator when disabled', () async {
    final disabledChannel = GoogleChatChannel(
      config: const GoogleChatConfig(
        typingIndicatorMode: TypingIndicatorMode.disabled,
        groupAccess: GroupAccessMode.open,
      ),
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
    expect(channelManager.received, hasLength(1));
  });

  group('sender display name enrichment', () {
    late GoogleChatChannel disabledChannel;

    setUp(() {
      disabledChannel = GoogleChatChannel(
        config: const GoogleChatConfig(
          typingIndicatorMode: TypingIndicatorMode.disabled,
          groupAccess: GroupAccessMode.open,
        ),
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

      expect(channelManager.received, hasLength(1));
      expect(channelManager.received.first.metadata['senderDisplayName'], 'Tobias');
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

      expect(channelManager.received, hasLength(2));
      expect(channelManager.received[0].metadata['senderDisplayName'], 'Tobias');
      expect(channelManager.received[1].metadata['senderDisplayName'], 'Tobias');
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

      expect(channelManager.received, hasLength(1));
      expect(channelManager.received.first.metadata.containsKey('senderDisplayName'), isFalse);
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

      expect(channelManager.received.first.metadata['senderDisplayName'], 'Webhook Name');
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
    expect(channelManager.received, isEmpty);
  });

  group('inbound gate on the Pub/Sub path', () {
    const received = ReceivedMessage(
      ackId: 'ack',
      data: '',
      messageId: 'pubsub-1',
      publishTime: '2026-03-25T10:00:00Z',
      attributes: {},
    );

    test('a space outside the group allowlist never reaches the channel manager', () async {
      final wiring = buildWiring(
        result: MessageResult([testMessage()]),
        typingChannel: gatedChannel(
          groupAccess: GroupAccessMode.allowlist,
          groupAllowlist: [const GroupEntry(id: 'spaces/OTHER')],
        ),
      );

      final acked = await wiring.processMessage(received);

      // Refused traffic is acked, not nacked: a redelivery would only be refused again.
      expect(acked, isTrue);
      expect(channelManager.received, isEmpty);
      expect(restClient.sentMessages, isEmpty, reason: 'no typing indicator for refused traffic');
      expect(restClient.getMemberDisplayNameCalls, isEmpty, reason: 'no enrichment call for refused traffic');
    });

    test('group_access: disabled drops every space message', () async {
      final wiring = buildWiring(
        result: MessageResult([testMessage()]),
        typingChannel: gatedChannel(groupAccess: GroupAccessMode.disabled),
      );

      await wiring.processMessage(received);

      expect(channelManager.received, isEmpty);
    });

    test('an allowlisted space still reaches the channel manager', () async {
      final wiring = buildWiring(
        result: MessageResult([testMessage()]),
        typingChannel: gatedChannel(
          groupAccess: GroupAccessMode.allowlist,
          groupAllowlist: [const GroupEntry(id: 'spaces/AAAA')],
        ),
      );

      await wiring.processMessage(received);

      expect(channelManager.received, hasLength(1));
    });

    // Space Events exist to deliver traffic that never mentions the bot, so the
    // mention stage of the gate is the one stage this path skips.
    test('mention gating does not apply to Space Events traffic', () async {
      final wiring = buildWiring(
        result: MessageResult([testMessage()]),
        typingChannel: gatedChannel(
          mentionGating: MentionGating(requireMention: true, mentionPatterns: const [], ownJid: 'users/bot'),
        ),
      );

      await wiring.processMessage(received);

      expect(channelManager.received, hasLength(1));
    });
  });
}
