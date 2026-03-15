import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('MentionGating', () {
    const botJid = 'bot@s.whatsapp.net';

    late MentionGating gating;

    setUp(() {
      gating = MentionGating(requireMention: true, mentionPatterns: [r'@bot', r'hey dartclaw'], ownJid: botJid);
    });

    test('DM always processes', () {
      final dm = ChannelMessage(channelType: ChannelType.whatsapp, senderJid: 'user@s.whatsapp.net', text: 'hello');
      expect(gating.shouldProcess(dm), isTrue);
    });

    test('group with native mention processes', () {
      final msg = ChannelMessage(
        channelType: ChannelType.whatsapp,
        senderJid: 'user@s.whatsapp.net',
        groupJid: 'group@g.us',
        text: 'hey',
        mentionedJids: [botJid],
      );
      expect(gating.shouldProcess(msg), isTrue);
    });

    test('group with regex mention processes', () {
      final msg = ChannelMessage(
        channelType: ChannelType.whatsapp,
        senderJid: 'user@s.whatsapp.net',
        groupJid: 'group@g.us',
        text: '@bot what is 2+2?',
      );
      expect(gating.shouldProcess(msg), isTrue);
    });

    test('group without mention does not process', () {
      final msg = ChannelMessage(
        channelType: ChannelType.whatsapp,
        senderJid: 'user@s.whatsapp.net',
        groupJid: 'group@g.us',
        text: 'random chat',
      );
      expect(gating.shouldProcess(msg), isFalse);
    });

    test('requireMention=false processes all group messages', () {
      final openGating = MentionGating(requireMention: false, mentionPatterns: [], ownJid: botJid);
      final msg = ChannelMessage(
        channelType: ChannelType.whatsapp,
        senderJid: 'user@s.whatsapp.net',
        groupJid: 'group@g.us',
        text: 'random',
      );
      expect(openGating.shouldProcess(msg), isTrue);
    });
  });
}
