import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_slack/dartclaw_slack.dart';
import 'package:test/test.dart';

void main() {
  test('an empty section is a disabled Slack that admits listed senders and ignores channels', () {
    final warnings = <String>[];

    final config = SlackConfig.fromYaml(const {}, warnings);

    expect(config.enabled, isFalse);
    expect(config.mode, 'socket');
    expect(config.dmAccess, DmAccessMode.allowlist);
    expect(config.groupAccess, GroupAccessMode.disabled);
    expect(config.requireMention, isTrue);
    expect(config.botTokenCredential, isNull);
    expect(config.appTokenCredential, isNull);
    expect(warnings, isEmpty);
  });

  test('every Slack key is read, allowlist rows keep the agent they bind', () {
    final warnings = <String>[];

    final config = SlackConfig.fromYaml({
      'enabled': true,
      'mode': 'socket',
      'bot_token_credential': 'slack_bot',
      'app_token_credential': 'slack_app',
      'dm_access': 'open',
      'dm_allowlist': [
        'U1',
        {'id': 'U2', 'name': 'Bo'},
      ],
      'group_access': 'allowlist',
      'group_allowlist': [
        'C1',
        {'id': 'C2', 'agent': 'eng-bot'},
      ],
      'require_mention': false,
      'mention_patterns': [r'\bbot\b'],
    }, warnings);

    expect(config.enabled, isTrue);
    expect(config.botTokenCredential, 'slack_bot');
    expect(config.appTokenCredential, 'slack_app');
    expect(config.dmAccess, DmAccessMode.open);
    expect(config.dmIds, ['U1', 'U2']);
    expect(config.groupIds, ['C1', 'C2']);
    expect(config.groupAllowlist.last.agent, 'eng-bot');
    expect(config.requireMention, isFalse);
    expect(config.mentionPatterns, [r'\bbot\b']);
    expect(warnings, isEmpty);
  });

  test('streaming defaults to on, turns off with false, and a non-bool warns naming the key', () {
    final warnings = <String>[];

    expect(SlackConfig.fromYaml(const {}, warnings).streaming, isTrue);
    expect(SlackConfig.fromYaml(const {'streaming': false}, warnings).streaming, isFalse);
    expect(warnings, isEmpty);

    expect(SlackConfig.fromYaml(const {'streaming': 'off'}, warnings).streaming, isTrue);
    expect(warnings.single, contains('slack.streaming'));
  });

  test('a value of the wrong type warns and keeps the default', () {
    final warnings = <String>[];

    final config = SlackConfig.fromYaml({
      'enabled': 'yes',
      'bot_token_credential': 12,
      'dm_access': 'sometimes',
    }, warnings);

    expect(config.enabled, isFalse);
    expect(config.botTokenCredential, isNull);
    expect(config.dmAccess, DmAccessMode.allowlist);
    expect(warnings, hasLength(3));
  });
}
