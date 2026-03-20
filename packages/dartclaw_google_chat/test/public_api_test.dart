import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:test/test.dart';

void main() {
  test('public library re-exports core types used by Google Chat APIs', () {
    final gating = MentionGating(requireMention: true, mentionPatterns: ['@dartclaw'], ownJid: 'users/123');
    final config = GoogleChatConfig(
      dmAccess: DmAccessMode.open,
      groupAccess: GroupAccessMode.open,
      taskTrigger: const TaskTriggerConfig(enabled: true),
    );

    expect(gating.requireMention, isTrue);
    expect(config.taskTrigger.enabled, isTrue);
    expect(ChannelType.googlechat.name, 'googlechat');
  });
}
