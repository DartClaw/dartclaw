// Parses a Slack channel section. Real delivery needs a Slack app with Socket Mode enabled and both
// tokens in `credentials` entries.

import 'package:dartclaw_slack/dartclaw_slack.dart';

void main() {
  final warnings = <String>[];
  final config = SlackConfig.fromYaml({
    'enabled': true,
    'bot_token_credential': 'slack_bot',
    'app_token_credential': 'slack_app',
    'dm_access': 'allowlist',
    'dm_allowlist': ['U0123ABCD'],
    'group_access': 'allowlist',
    'group_allowlist': ['C0123ABCD'],
  }, warnings);

  print('Slack enabled: ${config.enabled}');
  print('Bot token entry: ${config.botTokenCredential}');
  print('Channels: ${config.groupIds}');
  if (warnings.isNotEmpty) {
    print('Warnings: $warnings');
  }
}
