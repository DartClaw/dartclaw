import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeChannel;
import 'package:test/test.dart';

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
      manager = ChannelManager(
        queue: queue,
        config: const ChannelConfig.defaults(),
        liveScopeConfig: LiveScopeConfig(const SessionScopeConfig.defaults()),
      );
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
      expect(dispatched.first.$1, startsWith('agent:main:dm:whatsapp:'));
      expect(dispatched.first.$1, contains(Uri.encodeComponent('sender@s.whatsapp.net')));
      expect(dispatched.first.$2, 'hello');
    });

    test('handleInboundMessage drops unknown JID', () async {
      final msg = ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'unknown@s.whatsapp.net', text: 'hello');
      manager.handleInboundMessage(msg);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(dispatched, isEmpty);
    });

    test('handleInboundMessage can resolve channel ownership from metadata spaceName', () async {
      channel = FakeChannel(type: ChannelType.googlechat, ownedJids: {'spaces/AAAA'});
      manager = ChannelManager(
        queue: queue,
        config: const ChannelConfig.defaults(),
        liveScopeConfig: LiveScopeConfig(const SessionScopeConfig.defaults()),
      );
      manager.registerChannel(channel);

      manager.handleInboundMessage(
        ChannelMessage(
          channelType: ChannelType.googlechat,
          senderJid: 'users/123',
          text: 'hello',
          metadata: const {'spaceName': 'spaces/AAAA'},
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(dispatched, hasLength(1));
      expect(dispatched.single.$2, 'hello');
    });

    test('session key derivation — DM vs group', () {
      final dm = ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'sender@s.whatsapp.net', text: 'dm');
      final group = ChannelMessage(
        channelType: ChannelType.whatsapp,
        senderJid: 'sender@s.whatsapp.net',
        groupJid: 'group@g.us',
        text: 'group msg',
      );

      final dmKey = manager.deriveSessionKey(dm);
      final groupKey = manager.deriveSessionKey(group);

      // Default dmScope is perChannelContact
      expect(dmKey, startsWith('agent:main:dm:whatsapp:'));
      // Default groupScope is shared — sender NOT in key (P0 fix)
      expect(groupKey, startsWith('agent:main:group:'));
      expect(groupKey, contains(Uri.encodeComponent('group@g.us')));
      expect(groupKey, isNot(contains(Uri.encodeComponent('sender@s.whatsapp.net'))));
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

  group('scope-driven routing', () {
    ChannelManager buildManager({SessionScopeConfig? scopeConfig, LiveScopeConfig? liveScopeConfig}) {
      final queue = MessageQueue(
        debounceWindow: const Duration(milliseconds: 50),
        dispatcher: (sessionKey, message, {String? senderJid}) async => 'ok',
      );
      return ChannelManager(
        queue: queue,
        config: const ChannelConfig.defaults(),
        liveScopeConfig: liveScopeConfig ?? LiveScopeConfig(scopeConfig ?? const SessionScopeConfig.defaults()),
      );
    }

    // -----------------------------------------------------------------------
    // DM scope tests
    // -----------------------------------------------------------------------

    test('dmScope: shared — all DM senders route to same key', () {
      final m = buildManager(
        scopeConfig: const SessionScopeConfig(dmScope: DmScope.shared, groupScope: GroupScope.shared),
      );
      final alice = ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'alice@s.whatsapp.net', text: 'hi');
      final bob = ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'bob@s.whatsapp.net', text: 'hi');

      expect(m.deriveSessionKey(alice), m.deriveSessionKey(bob));
      expect(m.deriveSessionKey(alice), equals('agent:main:dm:shared'));
      m.dispose();
    });

    test('dmScope: perContact — different senders get different keys', () {
      final m = buildManager(
        scopeConfig: const SessionScopeConfig(dmScope: DmScope.perContact, groupScope: GroupScope.shared),
      );
      final alice = ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'alice@s.whatsapp.net', text: 'hi');
      final bob = ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'bob@s.whatsapp.net', text: 'hi');
      final aliceSignal = ChannelMessage(
        channelType: ChannelType.signal,
        senderJid: 'alice@s.whatsapp.net',
        text: 'hi',
      );

      expect(m.deriveSessionKey(alice), isNot(m.deriveSessionKey(bob)));
      // Same sender on different channels gets SAME key (perContact, not perChannelContact)
      expect(m.deriveSessionKey(alice), m.deriveSessionKey(aliceSignal));
      m.dispose();
    });

    test('dmScope: perChannelContact — same sender on different channels gets different keys', () {
      final m = buildManager(
        scopeConfig: const SessionScopeConfig(dmScope: DmScope.perChannelContact, groupScope: GroupScope.shared),
      );
      final aliceWa = ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'alice@s.whatsapp.net', text: 'hi');
      final aliceSignal = ChannelMessage(
        channelType: ChannelType.signal,
        senderJid: 'alice@s.whatsapp.net',
        text: 'hi',
      );

      expect(m.deriveSessionKey(aliceWa), isNot(m.deriveSessionKey(aliceSignal)));
      m.dispose();
    });

    // -----------------------------------------------------------------------
    // Group scope tests
    // -----------------------------------------------------------------------

    test('groupScope: shared — different senders in same group get SAME key (P0 fix)', () {
      final m = buildManager(
        scopeConfig: const SessionScopeConfig(dmScope: DmScope.perContact, groupScope: GroupScope.shared),
      );
      final alice = ChannelMessage(
        channelType: ChannelType.whatsapp,
        senderJid: 'alice@s.whatsapp.net',
        groupJid: 'group@g.us',
        text: 'hi',
      );
      final bob = ChannelMessage(
        channelType: ChannelType.whatsapp,
        senderJid: 'bob@s.whatsapp.net',
        groupJid: 'group@g.us',
        text: 'hi',
      );

      expect(m.deriveSessionKey(alice), m.deriveSessionKey(bob));
      m.dispose();
    });

    test('groupScope: perMember — different senders in same group get DIFFERENT keys', () {
      final m = buildManager(
        scopeConfig: const SessionScopeConfig(dmScope: DmScope.perContact, groupScope: GroupScope.perMember),
      );
      final alice = ChannelMessage(
        channelType: ChannelType.whatsapp,
        senderJid: 'alice@s.whatsapp.net',
        groupJid: 'group@g.us',
        text: 'hi',
      );
      final bob = ChannelMessage(
        channelType: ChannelType.whatsapp,
        senderJid: 'bob@s.whatsapp.net',
        groupJid: 'group@g.us',
        text: 'hi',
      );

      expect(m.deriveSessionKey(alice), isNot(m.deriveSessionKey(bob)));
      m.dispose();
    });

    // -----------------------------------------------------------------------
    // Per-channel override tests
    // -----------------------------------------------------------------------

    test('per-channel override: Signal groupScope overrides global', () {
      final m = buildManager(
        scopeConfig: SessionScopeConfig(
          dmScope: DmScope.perContact,
          groupScope: GroupScope.shared,
          channels: {'signal': const ChannelScopeConfig(groupScope: GroupScope.perMember)},
        ),
      );
      final waAlice = ChannelMessage(
        channelType: ChannelType.whatsapp,
        senderJid: 'alice@s.whatsapp.net',
        groupJid: 'group@g.us',
        text: 'hi',
      );
      final waBob = ChannelMessage(
        channelType: ChannelType.whatsapp,
        senderJid: 'bob@s.whatsapp.net',
        groupJid: 'group@g.us',
        text: 'hi',
      );
      final sigAlice = ChannelMessage(
        channelType: ChannelType.signal,
        senderJid: '+4670111',
        groupJid: 'signal-group-1',
        text: 'hi',
      );
      final sigBob = ChannelMessage(
        channelType: ChannelType.signal,
        senderJid: '+4670222',
        groupJid: 'signal-group-1',
        text: 'hi',
      );

      // WhatsApp uses global shared — same key
      expect(m.deriveSessionKey(waAlice), m.deriveSessionKey(waBob));
      // Signal override perMember — different keys
      expect(m.deriveSessionKey(sigAlice), isNot(m.deriveSessionKey(sigBob)));
      m.dispose();
    });

    test('deriveSessionKey reflects live scope change', () {
      final liveScopeConfig = LiveScopeConfig(
        const SessionScopeConfig(dmScope: DmScope.shared, groupScope: GroupScope.shared),
      );
      final m = buildManager(liveScopeConfig: liveScopeConfig);
      final message = ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'alice@s.whatsapp.net', text: 'hi');

      expect(m.deriveSessionKey(message), SessionKey.dmShared());

      liveScopeConfig.update(const SessionScopeConfig(dmScope: DmScope.perContact, groupScope: GroupScope.shared));

      expect(m.deriveSessionKey(message), SessionKey.dmPerContact(peerId: 'alice@s.whatsapp.net'));
      m.dispose();
    });

    test('deriveSessionKey reflects live group scope change', () {
      final liveScopeConfig = LiveScopeConfig(
        const SessionScopeConfig(dmScope: DmScope.perContact, groupScope: GroupScope.shared),
      );
      final m = buildManager(liveScopeConfig: liveScopeConfig);
      final message = ChannelMessage(
        channelType: ChannelType.whatsapp,
        senderJid: 'alice@s.whatsapp.net',
        groupJid: 'group@g.us',
        text: 'hi',
      );

      expect(m.deriveSessionKey(message), SessionKey.groupShared(channelType: 'whatsapp', groupId: 'group@g.us'));

      liveScopeConfig.update(const SessionScopeConfig(dmScope: DmScope.perContact, groupScope: GroupScope.perMember));

      expect(
        m.deriveSessionKey(message),
        SessionKey.groupPerMember(channelType: 'whatsapp', groupId: 'group@g.us', peerId: 'alice@s.whatsapp.net'),
      );
      m.dispose();
    });

    test('per-channel override: WhatsApp dmScope overrides global', () {
      final m = buildManager(
        scopeConfig: SessionScopeConfig(
          dmScope: DmScope.perContact,
          groupScope: GroupScope.shared,
          channels: {'whatsapp': const ChannelScopeConfig(dmScope: DmScope.shared)},
        ),
      );
      final waAlice = ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'alice@s.whatsapp.net', text: 'hi');
      final waBob = ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'bob@s.whatsapp.net', text: 'hi');
      final sigAlice = ChannelMessage(channelType: ChannelType.signal, senderJid: '+4670111', text: 'hi');
      final sigBob = ChannelMessage(channelType: ChannelType.signal, senderJid: '+4670222', text: 'hi');

      // WhatsApp override shared — same key for all DMs
      expect(m.deriveSessionKey(waAlice), m.deriveSessionKey(waBob));
      // Signal uses global perContact — different keys
      expect(m.deriveSessionKey(sigAlice), isNot(m.deriveSessionKey(sigBob)));
      m.dispose();
    });

    // -----------------------------------------------------------------------
    // Edge cases
    // -----------------------------------------------------------------------

    test('group message with same groupJid but different channelTypes gets different keys', () {
      final m = buildManager();
      final waGroup = ChannelMessage(
        channelType: ChannelType.whatsapp,
        senderJid: 'alice@s.whatsapp.net',
        groupJid: 'group-1',
        text: 'hi',
      );
      final sigGroup = ChannelMessage(
        channelType: ChannelType.signal,
        senderJid: '+4670111',
        groupJid: 'group-1',
        text: 'hi',
      );

      expect(m.deriveSessionKey(waGroup), isNot(m.deriveSessionKey(sigGroup)));
      m.dispose();
    });

    test('default config produces same results as SessionScopeConfig.defaults()', () {
      final defaultManager = buildManager();
      final explicitManager = buildManager(scopeConfig: const SessionScopeConfig.defaults());

      final dm = ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'sender@s.whatsapp.net', text: 'hi');
      final group = ChannelMessage(
        channelType: ChannelType.whatsapp,
        senderJid: 'sender@s.whatsapp.net',
        groupJid: 'group@g.us',
        text: 'hi',
      );

      expect(defaultManager.deriveSessionKey(dm), explicitManager.deriveSessionKey(dm));
      expect(defaultManager.deriveSessionKey(group), explicitManager.deriveSessionKey(group));
      defaultManager.dispose();
      explicitManager.dispose();
    });
  });
}
