import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

ChannelMessage _googleChatMessage({String senderJid = 'users/123', String? groupJid, String text = 'Hello'}) {
  return ChannelMessage(
    channelType: ChannelType.googlechat,
    senderJid: senderJid,
    groupJid: groupJid,
    text: text,
    metadata: {'spaceName': groupJid ?? 'spaces/DM'},
  );
}

void main() {
  group('Google Chat session key derivation', () {
    test('DM with perChannelContact scope (default)', () {
      final config = const SessionScopeConfig.defaults();
      final manager = ChannelManager(
        queue: _NoopMessageQueue(),
        config: const ChannelConfig(),
        liveScopeConfig: LiveScopeConfig(config),
      );

      final message = _googleChatMessage(senderJid: 'users/456');
      final key = manager.deriveSessionKey(message);

      expect(key, contains('users'));
      expect(key, contains('456'));
      expect(key, contains('googlechat'));
    });

    test('DM with perChannelContact scope override', () {
      final config = SessionScopeConfig(
        dmScope: DmScope.perContact,
        groupScope: GroupScope.shared,
        channels: {'googlechat': const ChannelScopeConfig(dmScope: DmScope.perChannelContact)},
      );
      final manager = ChannelManager(
        queue: _NoopMessageQueue(),
        config: const ChannelConfig(),
        liveScopeConfig: LiveScopeConfig(config),
      );

      final message = _googleChatMessage(senderJid: 'users/456');
      final key = manager.deriveSessionKey(message);

      expect(key, contains('googlechat'));
      expect(key, contains('456'));
    });

    test('DM with shared scope', () {
      final config = SessionScopeConfig(dmScope: DmScope.shared, groupScope: GroupScope.shared);
      final manager = ChannelManager(
        queue: _NoopMessageQueue(),
        config: const ChannelConfig(),
        liveScopeConfig: LiveScopeConfig(config),
      );

      final message = _googleChatMessage(senderJid: 'users/456');
      final key = manager.deriveSessionKey(message);

      expect(key, contains('shared'));
    });

    test('Group with shared scope (default)', () {
      final config = const SessionScopeConfig.defaults();
      final manager = ChannelManager(
        queue: _NoopMessageQueue(),
        config: const ChannelConfig(),
        liveScopeConfig: LiveScopeConfig(config),
      );

      final message = _googleChatMessage(senderJid: 'users/123', groupJid: 'spaces/BBBB');
      final key = manager.deriveSessionKey(message);

      expect(key, contains('googlechat'));
      expect(key, contains('BBBB'));
    });

    test('Group with perMember scope override', () {
      final config = SessionScopeConfig(
        dmScope: DmScope.perContact,
        groupScope: GroupScope.shared,
        channels: {'googlechat': const ChannelScopeConfig(groupScope: GroupScope.perMember)},
      );
      final manager = ChannelManager(
        queue: _NoopMessageQueue(),
        config: const ChannelConfig(),
        liveScopeConfig: LiveScopeConfig(config),
      );

      final message = _googleChatMessage(senderJid: 'users/123', groupJid: 'spaces/BBBB');
      final key = manager.deriveSessionKey(message);

      expect(key, contains('googlechat'));
      expect(key, contains('BBBB'));
      expect(key, contains('123'));
    });

    test('Per-channel override takes precedence over global', () {
      final config = SessionScopeConfig(
        dmScope: DmScope.shared,
        groupScope: GroupScope.shared,
        channels: {'googlechat': const ChannelScopeConfig(dmScope: DmScope.perContact)},
      );
      final manager = ChannelManager(
        queue: _NoopMessageQueue(),
        config: const ChannelConfig(),
        liveScopeConfig: LiveScopeConfig(config),
      );

      final message = _googleChatMessage(senderJid: 'users/789');
      final key = manager.deriveSessionKey(message);

      expect(key, contains('789'));
      expect(key, isNot(contains('shared')));
    });
  });
}

class _NoopMessageQueue extends MessageQueue {
  _NoopMessageQueue() : super(dispatcher: (sessionKey, message, {senderJid}) async => '');

  @override
  void enqueue(ChannelMessage message, Channel channel, String sessionKey) {}
}
