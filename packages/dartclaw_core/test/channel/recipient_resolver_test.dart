import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('resolveRecipientId', () {
    test('resolves to senderJid for direct messages', () {
      final message = ChannelMessage(
        channelType: ChannelType.whatsapp,
        senderJid: 'sender@s.whatsapp.net',
        text: 'hello',
      );

      expect(resolveRecipientId(message), 'sender@s.whatsapp.net');
    });

    test('resolves to groupJid for group messages without spaceName', () {
      final message = ChannelMessage(
        channelType: ChannelType.whatsapp,
        senderJid: 'sender@s.whatsapp.net',
        groupJid: 'group@g.us',
        text: 'hello',
      );

      expect(resolveRecipientId(message), 'group@g.us');
    });

    test('resolves to spaceName when present in metadata (Google Chat)', () {
      final message = ChannelMessage(
        channelType: ChannelType.googlechat,
        senderJid: 'users/123',
        text: 'hello',
        metadata: const {'spaceName': 'spaces/AAAA'},
      );

      expect(resolveRecipientId(message), 'spaces/AAAA');
    });

    test('prefers spaceName over groupJid when both present', () {
      final message = ChannelMessage(
        channelType: ChannelType.googlechat,
        senderJid: 'users/123',
        groupJid: 'thread@g.us',
        text: 'hello',
        metadata: const {'spaceName': 'spaces/AAAA'},
      );

      expect(resolveRecipientId(message), 'spaces/AAAA');
    });

    test('ignores empty spaceName, falls through to groupJid', () {
      final message = ChannelMessage(
        channelType: ChannelType.googlechat,
        senderJid: 'users/123',
        groupJid: 'group@g.us',
        text: 'hello',
        metadata: const {'spaceName': ''},
      );

      expect(resolveRecipientId(message), 'group@g.us');
    });

    test('ignores empty spaceName, falls through to senderJid when no groupJid', () {
      final message = ChannelMessage(
        channelType: ChannelType.googlechat,
        senderJid: 'users/123',
        text: 'hello',
        metadata: const {'spaceName': ''},
      );

      expect(resolveRecipientId(message), 'users/123');
    });

    test('prefers spaceName over senderJid for DMs in Google Chat', () {
      final message = ChannelMessage(
        channelType: ChannelType.googlechat,
        senderJid: 'users/123',
        text: 'hello',
        metadata: const {'spaceName': 'spaces/DM-AAAA'},
      );

      expect(resolveRecipientId(message), 'spaces/DM-AAAA');
    });
  });
}
