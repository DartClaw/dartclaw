import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('SignalDmAccessController', () {
    group('open mode', () {
      test('allows everyone', () {
        final ctrl = SignalDmAccessController(mode: SignalDmAccessMode.open);
        expect(ctrl.isAllowed('+1234567890'), isTrue);
        expect(ctrl.isAllowed('+9999999999'), isTrue);
      });
    });

    group('disabled mode', () {
      test('denies everyone', () {
        final ctrl = SignalDmAccessController(mode: SignalDmAccessMode.disabled);
        expect(ctrl.isAllowed('+1234567890'), isFalse);
      });
    });

    group('allowlist mode', () {
      test('allows listed numbers', () {
        final ctrl = SignalDmAccessController(mode: SignalDmAccessMode.allowlist, allowlist: {'+1111111111'});
        expect(ctrl.isAllowed('+1111111111'), isTrue);
        expect(ctrl.isAllowed('+2222222222'), isFalse);
      });

      test('addToAllowlist adds number', () {
        final ctrl = SignalDmAccessController(mode: SignalDmAccessMode.allowlist);
        expect(ctrl.isAllowed('+3333333333'), isFalse);
        ctrl.addToAllowlist('+3333333333');
        expect(ctrl.isAllowed('+3333333333'), isTrue);
      });
    });
  });

  group('SignalMentionGating', () {
    const ownNumber = '+0000000000';

    test('DM always processes', () {
      final gating = SignalMentionGating(requireMention: true, mentionPatterns: [], ownNumber: ownNumber);
      final dm = ChannelMessage(channelType: ChannelType.signal, senderJid: '+1234567890', text: 'hello');
      expect(gating.shouldProcess(dm), isTrue);
    });

    test('group with regex mention processes', () {
      final gating = SignalMentionGating(
        requireMention: true,
        mentionPatterns: [r'@bot', r'hey dartclaw'],
        ownNumber: ownNumber,
      );
      final msg = ChannelMessage(
        channelType: ChannelType.signal,
        senderJid: '+1234567890',
        groupJid: 'grp-1',
        text: '@bot what is 2+2?',
      );
      expect(gating.shouldProcess(msg), isTrue);
    });

    test('group without mention does not process', () {
      final gating = SignalMentionGating(requireMention: true, mentionPatterns: [r'@bot'], ownNumber: ownNumber);
      final msg = ChannelMessage(
        channelType: ChannelType.signal,
        senderJid: '+1234567890',
        groupJid: 'grp-1',
        text: 'random chat',
      );
      expect(gating.shouldProcess(msg), isFalse);
    });

    test('requireMention=false processes all group messages', () {
      final gating = SignalMentionGating(requireMention: false, mentionPatterns: [], ownNumber: ownNumber);
      final msg = ChannelMessage(
        channelType: ChannelType.signal,
        senderJid: '+1234567890',
        groupJid: 'grp-1',
        text: 'random',
      );
      expect(gating.shouldProcess(msg), isTrue);
    });

    test('group with native mentionedJids containing ownNumber processes', () {
      final gating = SignalMentionGating(requireMention: true, mentionPatterns: [], ownNumber: ownNumber);
      final msg = ChannelMessage(
        channelType: ChannelType.signal,
        senderJid: '+1234567890',
        groupJid: 'grp-1',
        text: 'hey',
        mentionedJids: [ownNumber],
      );
      expect(gating.shouldProcess(msg), isTrue);
    });
  });
}
