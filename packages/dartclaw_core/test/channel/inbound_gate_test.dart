import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('ChannelInboundGate', () {
    const botJid = 'bot@s.whatsapp.net';
    const senderJid = 'user@s.whatsapp.net';
    const groupJid = 'group@g.us';

    ChannelMessage dm({String sender = senderJid}) =>
        ChannelMessage(channelType: ChannelType.whatsapp, senderJid: sender, text: 'hello');

    ChannelMessage groupMessage({String text = 'random chat', List<String> mentionedJids = const []}) => ChannelMessage(
      channelType: ChannelType.whatsapp,
      senderJid: senderJid,
      groupJid: groupJid,
      text: text,
      mentionedJids: mentionedJids,
    );

    ChannelInboundDecision evaluate(
      ChannelMessage message, {
      DmAccessController? dmAccess,
      MentionGating? mentionGating,
      GroupAccessMode groupAccess = GroupAccessMode.open,
      List<String> groupAllowlist = const [],
    }) => ChannelInboundGate.evaluate(
      message,
      dmAccess: dmAccess,
      mentionGating: mentionGating,
      groupAccess: groupAccess,
      groupAllowlist: groupAllowlist,
    );

    group('DM access', () {
      test('admits when no controller is wired — an absent gate admits, it does not deny', () {
        expect(evaluate(dm()), ChannelInboundDecision.admitted);
      });

      test('admits an allowlisted sender', () {
        final access = DmAccessController(mode: DmAccessMode.allowlist, allowlist: {senderJid});
        expect(evaluate(dm(), dmAccess: access), ChannelInboundDecision.admitted);
      });

      test('drops an unknown sender when the controller disallows it', () {
        final access = DmAccessController(mode: DmAccessMode.allowlist);
        expect(evaluate(dm(), dmAccess: access), ChannelInboundDecision.dmDenied);
      });

      test('leaves the allowlist untouched on every denial — the gate mutates no collaborator', () {
        for (final mode in DmAccessMode.values) {
          final access = DmAccessController(mode: mode, allowlist: {'other@s.whatsapp.net'});
          evaluate(dm(), dmAccess: access);
          expect(access.allowlist, {'other@s.whatsapp.net'}, reason: 'mode $mode must not self-heal the allowlist');
        }
      });

      test('drops rather than offers pairing when DMs are disabled entirely', () {
        final access = DmAccessController(mode: DmAccessMode.disabled, allowlist: {senderJid});
        expect(evaluate(dm(), dmAccess: access), ChannelInboundDecision.dmDenied);
      });

      test('reports an unknown sender as pairing-eligible in pairing mode, without creating the pairing', () {
        final access = DmAccessController(mode: DmAccessMode.pairing);
        expect(evaluate(dm(), dmAccess: access), ChannelInboundDecision.dmPairingRequired);
        expect(access.pendingCount, 0, reason: 'the pairing effect belongs to the call site');
      });

      test('does not apply DM access to group messages', () {
        final access = DmAccessController(mode: DmAccessMode.disabled);
        expect(evaluate(groupMessage(), dmAccess: access), ChannelInboundDecision.admitted);
      });
    });

    group('group access', () {
      test('drops a group message when group access is disabled', () {
        expect(
          evaluate(groupMessage(), groupAccess: GroupAccessMode.disabled),
          ChannelInboundDecision.groupAccessDisabled,
        );
      });

      test('drops a group message whose groupJid is absent from the allowlist', () {
        expect(
          evaluate(groupMessage(), groupAccess: GroupAccessMode.allowlist, groupAllowlist: const ['other@g.us']),
          ChannelInboundDecision.groupNotAllowlisted,
        );
      });

      test('admits a group message listed in the allowlist', () {
        expect(
          evaluate(groupMessage(), groupAccess: GroupAccessMode.allowlist, groupAllowlist: const [groupJid]),
          ChannelInboundDecision.admitted,
        );
      });

      test('admits any group when access is open', () {
        expect(evaluate(groupMessage(), groupAccess: GroupAccessMode.open), ChannelInboundDecision.admitted);
      });

      test('does not apply group access to DMs', () {
        expect(evaluate(dm(), groupAccess: GroupAccessMode.disabled), ChannelInboundDecision.admitted);
      });
    });

    group('mention gating', () {
      MentionGating gating({bool requireMention = true}) =>
          MentionGating(requireMention: requireMention, mentionPatterns: [r'@bot'], ownJid: botJid);

      test('drops a mention-less group message when gating requires a mention', () {
        expect(evaluate(groupMessage(), mentionGating: gating()), ChannelInboundDecision.mentionRequired);
      });

      test('admits a mention-less group message when no gating is wired', () {
        expect(evaluate(groupMessage()), ChannelInboundDecision.admitted);
      });

      test('admits a mention-less group message when gating does not require a mention', () {
        expect(evaluate(groupMessage(), mentionGating: gating(requireMention: false)), ChannelInboundDecision.admitted);
      });

      test('admits a mentioning group message', () {
        expect(evaluate(groupMessage(text: '@bot hi'), mentionGating: gating()), ChannelInboundDecision.admitted);
      });

      test('is not applied to DMs', () {
        expect(evaluate(dm(), mentionGating: gating()), ChannelInboundDecision.admitted);
      });
    });

    test('DM access is evaluated before group access and mention gating', () {
      final access = DmAccessController(mode: DmAccessMode.allowlist);
      expect(evaluate(dm(), dmAccess: access, groupAccess: GroupAccessMode.disabled), ChannelInboundDecision.dmDenied);
    });

    test('group access is evaluated before mention gating', () {
      expect(
        evaluate(
          groupMessage(),
          groupAccess: GroupAccessMode.disabled,
          mentionGating: MentionGating(requireMention: true, mentionPatterns: const [], ownJid: botJid),
        ),
        ChannelInboundDecision.groupAccessDisabled,
      );
    });
  });
}
