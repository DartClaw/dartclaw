import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

void main() {
  test('public library composes with kernel types used by Google Chat APIs', () {
    final gating = MentionGating(requireMention: true, mentionPatterns: ['@dartclaw'], ownJid: 'users/123');
    final config = GoogleChatConfig(dmAccess: DmAccessMode.open, groupAccess: GroupAccessMode.open);

    expect(gating.requireMention, isTrue);
    expect(config.dmAccess, DmAccessMode.open);
    expect(ChannelType.googlechat.name, 'googlechat');
  });
}
