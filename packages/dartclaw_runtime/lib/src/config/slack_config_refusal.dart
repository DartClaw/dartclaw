import 'package:dartclaw_core/dartclaw_core.dart' show DmAccessMode, GroupEntry;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart' show GoogleChatConfig;
import 'package:dartclaw_slack/dartclaw_slack.dart';

import 'channel_config_resolver.dart';

final _channelIdPattern = RegExp(r'^[CG][A-Z0-9]+$');
final _slackTokenPattern = RegExp(r'^xox[a-z]-|^xapp-');
final _signingSecretPattern = RegExp(r'^[0-9a-fA-F]{32}$');

/// Refuses an enabled `channels.slack` section Slack could not run on.
///
/// A warning would leave a misconfigured Slack half-working, so each problem
/// is collected into one [FormatException] that names the key and the fix.
/// No message repeats a value from the file: a credential reference that is
/// not a reference is a secret, and a secret must never reach a log.
///
/// Whether a reference names a usable `credentials` entry is judged only when
/// [storedCredentialsResolved]: a load that skipped the stored-credential file
/// cannot tell a missing or empty entry from one the store supplies.
void refuseUnusableSlackConfig(DartclawConfig config, {required bool storedCredentialsResolved}) {
  final slack = resolveChannelConfig<SlackConfig>(config, ChannelType.slack);
  if (!slack.enabled) return;

  final problems = <String>[];
  final modeProblem = FieldConstraints.evaluate(ConfigMeta.fields['channels.slack.mode']!, slack.mode);
  if (modeProblem != null) {
    problems.add('channels.slack.mode: unsupported value; use socket or events.');
  }
  if (slack.dmAccess == DmAccessMode.disabled && slack.groupAccess == GroupAccessMode.disabled) {
    problems.add(
      'channels.slack: dm_access and group_access are both disabled, so nothing can reach the agent. '
      'Enable one of them.',
    );
  }
  problems
    ..addAll(_badWebhookPath(config, slack.webhookPath))
    ..addAll(
      _badIds('channels.slack.group_allowlist', slack.groupAllowlist, _channelIdPattern, 'channel ID (C… or G…)'),
    )
    ..addAll(_badIds('channels.slack.dm_allowlist', slack.dmAllowlist, slackUserIdPattern, 'user ID (U… or W…)'));

  final events = slack.mode == 'events';
  final references = [
    _Reference('bot_token_credential', slack.botTokenCredential, _slackTokenPattern, 'token', required: true),
    _Reference('app_token_credential', slack.appTokenCredential, _slackTokenPattern, 'token', required: !events),
    _Reference(
      'signing_secret_credential',
      slack.signingSecretCredential,
      _signingSecretPattern,
      'signing secret',
      required: events,
    ),
  ];
  for (final reference in references) {
    problems.addAll(reference.problems(config.credentials, storedCredentialsResolved));
  }

  if (problems.isNotEmpty) {
    throw FormatException('Invalid Slack configuration:\n${problems.map((problem) => '  $problem').join('\n')}');
  }
  for (final reference in references) {
    if (reference.unused) {
      config.parseWithLoadWarnings(
        (warns) => addConfigAdvisory(
          warns,
          'channels.slack.${reference.key} is set but unused in ${slack.mode} mode; remove it or switch mode.',
        ),
      );
    }
  }
}

Iterable<String> _badWebhookPath(DartclawConfig config, String path) sync* {
  const key = 'channels.slack.webhook_path';
  if (!path.startsWith('/')) {
    yield '$key: must start with /; use a path such as /integrations/slack.';
    return;
  }
  final googleChat = resolveChannelConfig<GoogleChatConfig>(config, ChannelType.googlechat).webhookPath;
  if (path == googleChat) yield '$key: collides with the Google Chat webhook path; choose a different path.';
  if (path == _gitHubWebhookPath(config)) yield '$key: collides with the GitHub webhook path; choose a different path.';
}

String _gitHubWebhookPath(DartclawConfig config) {
  try {
    return config.extension<GitHubWebhookConfig>('github').webhookPath;
  } catch (_) {
    return const GitHubWebhookConfig.defaults()
        .webhookPath; // Extension parser not registered: the default is in force.
  }
}

Iterable<String> _badIds(String key, List<GroupEntry> rows, RegExp pattern, String described) sync* {
  for (final (index, row) in rows.indexed) {
    if (!pattern.hasMatch(row.id)) yield '$key: entry ${index + 1} is not a Slack $described.';
  }
}

/// One `channels.slack.*_credential` key: a name that points at a `credentials` entry.
class _Reference {
  new(this.key, String? value, this._literalPattern, this._noun, {required this.required}) : _name = value?.trim();

  final String key;
  final bool required;
  final String? _name;
  final RegExp _literalPattern;
  final String _noun;

  bool get unused => !required && (_name?.isNotEmpty ?? false);

  Iterable<String> problems(CredentialsConfig credentials, bool storedCredentialsResolved) sync* {
    final path = 'channels.slack.$key';
    final fix = 'Put the $_noun under credentials.<name> and set this key to that name, never to the $_noun itself.';
    final name = _name;
    if (name == null || name.isEmpty) {
      if (required) {
        yield '$path: required while Slack is enabled. It names the credentials entry holding the $_noun. $fix';
      }
      return;
    }
    if (_literalPattern.hasMatch(name)) {
      yield '$path: holds a Slack $_noun. $fix';
      return;
    }
    if (!required || !storedCredentialsResolved) return;
    final entry = credentials[name];
    if (entry == null) {
      yield '$path: names no credentials entry. $fix';
    } else if (!entry.isApiKeyCredential) {
      yield '$path: must name an api_key credentials entry.';
    } else if (!entry.isPresent) {
      yield '$path: its credentials entry resolves to an empty value; set the environment variable it reads.';
    }
  }
}
