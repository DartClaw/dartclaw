import 'package:dartclaw_core/dartclaw_core.dart' show DmAccessMode, GroupEntry;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_slack/dartclaw_slack.dart';

import 'channel_config_resolver.dart';

final _channelIdPattern = RegExp(r'^[CG][A-Z0-9]+$');
final _userIdPattern = RegExp(r'^[UW][A-Z0-9]+$');
final _slackTokenPattern = RegExp(r'^xox[a-z]-|^xapp-');

/// Refuses an enabled `channels.slack` section Slack could not run on.
///
/// A warning would leave a misconfigured Slack half-working, so each problem
/// is collected into one [FormatException] that names the key and the fix.
/// No message repeats a value from the file: a credential reference that is
/// not a reference is a token, and a token must never reach a log.
///
/// A reference naming no `credentials` entry is refused only when
/// [storedCredentialsResolved]: a load that skipped the stored-credential file
/// cannot tell a missing entry from one that lives there.
void refuseUnusableSlackConfig(DartclawConfig config, {required bool storedCredentialsResolved}) {
  final slack = resolveChannelConfig<SlackConfig>(config, ChannelType.slack);
  if (!slack.enabled) return;

  final problems = <String>[];
  if (FieldConstraints.evaluate(ConfigMeta.fields['channels.slack.mode']!, slack.mode) != null) {
    problems.add('channels.slack.mode: unsupported value; use socket.');
  }
  if (slack.dmAccess == DmAccessMode.disabled && slack.groupAccess == GroupAccessMode.disabled) {
    problems.add(
      'channels.slack: dm_access and group_access are both disabled, so nothing can reach the agent. '
      'Enable one of them.',
    );
  }
  problems
    ..addAll(
      _badIds('channels.slack.group_allowlist', slack.groupAllowlist, _channelIdPattern, 'channel ID (C… or G…)'),
    )
    ..addAll(_badIds('channels.slack.dm_allowlist', slack.dmAllowlist, _userIdPattern, 'user ID (U… or W…)'))
    ..addAll(
      _badCredential('bot_token_credential', slack.botTokenCredential, config.credentials, storedCredentialsResolved),
    )
    ..addAll(
      _badCredential('app_token_credential', slack.appTokenCredential, config.credentials, storedCredentialsResolved),
    );

  if (problems.isNotEmpty) {
    throw FormatException('Invalid Slack configuration:\n${problems.map((problem) => '  $problem').join('\n')}');
  }
}

Iterable<String> _badIds(String key, List<GroupEntry> rows, RegExp pattern, String described) sync* {
  for (final (index, row) in rows.indexed) {
    if (!pattern.hasMatch(row.id)) yield '$key: entry ${index + 1} is not a Slack $described.';
  }
}

Iterable<String> _badCredential(
  String key,
  String? reference,
  CredentialsConfig credentials,
  bool storedCredentialsResolved,
) sync* {
  final path = 'channels.slack.$key';
  const fix = 'Put the token under credentials.<name> and set this key to that name, never to the token itself.';
  final name = reference?.trim();
  if (name == null || name.isEmpty) {
    yield '$path: required while Slack is enabled. It names the credentials entry holding the token. $fix';
    return;
  }
  if (_slackTokenPattern.hasMatch(name)) {
    yield '$path: holds a Slack token. $fix';
    return;
  }
  final entry = credentials[name];
  if (entry == null) {
    if (storedCredentialsResolved) yield '$path: names no credentials entry. $fix';
    return;
  }
  if (!entry.isApiKeyCredential) {
    yield '$path: must name an api_key credentials entry.';
  } else if (!entry.isPresent) {
    yield '$path: its credentials entry resolves to an empty value; set the environment variable it reads.';
  }
}
