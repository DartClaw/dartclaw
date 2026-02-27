import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// FakeChannel
// ---------------------------------------------------------------------------

class FakeChannel extends Channel {
  @override
  final String name;
  @override
  final ChannelType type;
  final Set<String> ownedJids;
  final List<(String, ChannelResponse)> sentMessages = [];
  bool connected = false;

  FakeChannel({this.name = 'fake', this.type = ChannelType.whatsapp, this.ownedJids = const {}});

  @override
  Future<void> connect() async => connected = true;

  @override
  Future<void> disconnect() async => connected = false;

  @override
  bool ownsJid(String jid) => ownedJids.contains(jid);

  @override
  Future<void> sendMessage(String recipientJid, ChannelResponse response) async {
    sentMessages.add((recipientJid, response));
  }
}

void main() {
  group('ChannelManager', () {
    late FakeChannel channel;
    late MessageQueue queue;
    late ChannelManager manager;
    final dispatched = <(String, String)>[];

    setUp(() {
      dispatched.clear();
      channel = FakeChannel(ownedJids: {'sender@s.whatsapp.net'});
      queue = MessageQueue(
        debounceWindow: const Duration(milliseconds: 50),
        dispatcher: (sessionKey, message, {String? senderJid}) async {
          dispatched.add((sessionKey, message));
          return 'ok';
        },
      );
      manager = ChannelManager(queue: queue, config: const ChannelConfig.defaults());
      manager.registerChannel(channel);
    });

    tearDown(() => manager.dispose());

    test('registerChannel adds to channels list', () {
      expect(manager.channels, hasLength(1));
      expect(manager.channels.first.name, 'fake');
    });

    test('handleInboundMessage routes to correct session key (DM)', () async {
      final msg = ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'sender@s.whatsapp.net', text: 'hello');
      manager.handleInboundMessage(msg);

      // Wait for debounce + dispatch
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(dispatched, hasLength(1));
      expect(dispatched.first.$1, contains('per-peer'));
      expect(dispatched.first.$1, contains(Uri.encodeComponent('sender@s.whatsapp.net')));
      expect(dispatched.first.$2, 'hello');
    });

    test('handleInboundMessage drops unknown JID', () async {
      final msg = ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'unknown@s.whatsapp.net', text: 'hello');
      manager.handleInboundMessage(msg);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(dispatched, isEmpty);
    });

    test('session key derivation — DM vs group', () {
      final dm = ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'sender@s.whatsapp.net', text: 'dm');
      final group = ChannelMessage(
        channelType: ChannelType.whatsapp,
        senderJid: 'sender@s.whatsapp.net',
        groupJid: 'group@g.us',
        text: 'group msg',
      );

      final dmKey = ChannelManager.deriveSessionKey(dm);
      final groupKey = ChannelManager.deriveSessionKey(group);

      expect(dmKey, startsWith('agent:main:per-peer:'));
      expect(groupKey, startsWith('agent:main:per-channel-peer:whatsapp:'));
      expect(groupKey, contains(Uri.encodeComponent('group@g.us')));
      expect(dmKey, isNot(groupKey));
    });

    test('connectAll / disconnectAll lifecycle', () async {
      expect(channel.connected, isFalse);
      await manager.connectAll();
      expect(channel.connected, isTrue);
      await manager.disconnectAll();
      expect(channel.connected, isFalse);
    });
  });
}
