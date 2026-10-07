import 'dart:async';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_slack/dartclaw_slack.dart'
    show SlackApiException, SlackConfig, SlackWebApiClient, slackExpectedBotScopes;

import 'setup_checks.dart' show DiagnosticRow, DiagnosticStatus;

typedef SlackClientFactory = SlackWebApiClient Function(String botToken);

const _authTimeout = Duration(seconds: 10);

/// The `slack.*` doctor rows for an enabled Slack channel.
///
/// [credentials] is the declared and stored view merged. [server] is the
/// running server's `/health` body, or `null` when none answered. No row
/// carries a credential value.
Future<List<DiagnosticRow>> slackRows(
  SlackConfig slack, {
  required CredentialsConfig credentials,
  required Map<String, dynamic>? server,
  required SlackClientFactory clientFactory,
}) async {
  final events = slack.mode == 'events';
  final botToken = _Reference('bot_token_credential', slack.botTokenCredential, credentials);
  final references = [
    botToken,
    if (events) _Reference('signing_secret_credential', slack.signingSecretCredential, credentials),
    if (!events) _Reference('app_token_credential', slack.appTokenCredential, credentials),
  ];
  final problems = [for (final reference in references) ?reference.problem];
  final rows = <DiagnosticRow>[
    problems.isEmpty
        ? DiagnosticRow(
            id: 'slack.credentials',
            status: DiagnosticStatus.pass,
            summary: 'Slack credentials are present: ${[for (final r in references) r.name].join(', ')}.',
          )
        : DiagnosticRow(
            id: 'slack.credentials',
            status: DiagnosticStatus.fail,
            summary: problems.first,
            detail: problems.length > 1 ? problems.skip(1).toList() : null,
            remediation: _credentialFix(references),
          ),
  ];

  final token = botToken.secret;
  if (token == null) {
    for (final id in ['auth', 'scopes']) {
      rows.add(DiagnosticRow(id: 'slack.$id', status: DiagnosticStatus.skip, summary: 'The bot token is unavailable.'));
    }
  } else {
    rows.addAll(await _authRows(token, botToken.name, clientFactory));
  }
  rows.add(_transportRow(slack, server));
  return rows;
}

String _credentialFix(List<_Reference> references) {
  final names = {
    for (final reference in references)
      if (reference.problem != null && reference.name.isNotEmpty) reference.name,
  };
  if (names.isEmpty) return 'Set each key above to the name of a credential, then rerun dartclaw doctor.';
  return 'Run ${[for (final name in names) 'dartclaw secrets set $name'].join(' and ')}, or declare '
      '${[for (final name in names) 'credentials.$name'].join(' and ')} in the config, then rerun dartclaw doctor.';
}

Future<List<DiagnosticRow>> _authRows(String token, String credentialName, SlackClientFactory clientFactory) async {
  final client = clientFactory(token);
  try {
    final info = await client.authTest().timeout(_authTimeout);
    return [
      const DiagnosticRow(id: 'slack.auth', status: DiagnosticStatus.pass, summary: 'Slack accepted the bot token.'),
      _scopesRow(info.scopes, credentialName),
    ];
  } on SlackApiException catch (error) {
    final code = error.errorCode;
    // `ratelimited` is the client's own code for a second 429, not Slack judging the token.
    if (code != null && code != 'ratelimited') {
      return [
        DiagnosticRow(
          id: 'slack.auth',
          status: DiagnosticStatus.fail,
          summary: 'Slack rejected the bot token: $code.',
          remediation:
              'Reinstall the Slack app to the workspace, then update credential $credentialName '
              '(dartclaw secrets set $credentialName, or the variable it reads).',
        ),
        _scopesSkipped,
      ];
    }
    return [_unreachable(error.message), _scopesSkipped];
  } on TimeoutException {
    return [_unreachable('auth.test did not answer within ${_authTimeout.inSeconds} s'), _scopesSkipped];
  } finally {
    client.close();
  }
}

const _scopesSkipped = DiagnosticRow(
  id: 'slack.scopes',
  status: DiagnosticStatus.skip,
  summary: 'The bot token was not verified, so its scopes are unknown.',
);

DiagnosticRow _unreachable(String reason) => DiagnosticRow(
  id: 'slack.auth',
  status: DiagnosticStatus.warn,
  summary: 'Slack is unreachable, so the bot token was not verified.',
  detail: [reason],
  remediation: 'Check the host\'s network access to slack.com and rerun dartclaw doctor.',
);

DiagnosticRow _scopesRow(List<String> granted, String credentialName) {
  if (granted.isEmpty) {
    return const DiagnosticRow(
      id: 'slack.scopes',
      status: DiagnosticStatus.warn,
      summary: 'Slack reported no scopes for the bot token, so scope drift cannot be checked.',
      remediation: 'Compare OAuth & Permissions in the Slack app with the shipped manifest.',
    );
  }
  final missing = [
    for (final scope in slackExpectedBotScopes)
      if (!granted.contains(scope)) scope,
  ];
  final extra = [
    for (final scope in granted)
      if (!slackExpectedBotScopes.contains(scope)) scope,
  ];
  if (missing.isNotEmpty) {
    return DiagnosticRow(
      id: 'slack.scopes',
      status: DiagnosticStatus.fail,
      summary: 'The bot token lacks required scopes: ${missing.join(', ')}.',
      detail: extra.isEmpty ? null : ['Scopes beyond the manifest: ${extra.join(', ')}.'],
      remediation:
          'Add the scopes under OAuth & Permissions (or import the shipped manifest), reinstall the app and '
          'update credential $credentialName.',
    );
  }
  if (extra.isNotEmpty) {
    return DiagnosticRow(
      id: 'slack.scopes',
      status: DiagnosticStatus.warn,
      summary: 'The bot token holds scopes beyond the manifest: ${extra.join(', ')}.',
      remediation: 'Remove them under OAuth & Permissions unless you added them on purpose.',
    );
  }
  return DiagnosticRow(
    id: 'slack.scopes',
    status: DiagnosticStatus.pass,
    summary: 'The bot token holds all ${slackExpectedBotScopes.length} scopes the manifest declares.',
  );
}

DiagnosticRow _transportRow(SlackConfig slack, Map<String, dynamic>? server) {
  const id = 'slack.transport';
  if (server == null) {
    return const DiagnosticRow(
      id: id,
      status: DiagnosticStatus.skip,
      summary: 'Transport state needs a running server.',
      remediation: 'Start the server with dartclaw serve, then rerun dartclaw doctor.',
    );
  }
  final state = server['slack'];
  if (state is! Map) {
    return const DiagnosticRow(
      id: id,
      status: DiagnosticStatus.warn,
      summary: 'The running server reports no Slack state.',
      remediation: 'It may have started before Slack was enabled; restart it with dartclaw serve.',
    );
  }
  return switch (state['mode']) {
    'socket' => _socketRow(state),
    'events' => _eventsRow(state, slack),
    _ => const DiagnosticRow(
      id: id,
      status: DiagnosticStatus.warn,
      summary: 'The running server reports an unknown Slack transport.',
      remediation: 'Restart it with the matching binary.',
    ),
  };
}

DiagnosticRow _socketRow(Map<dynamic, dynamic> state) {
  const id = 'slack.transport';
  final connectedAt = state['last_connected_at'];
  final failures = state['consecutive_failures'] is int ? state['consecutive_failures'] as int : 0;
  if (state['connection'] == 'connected') {
    return DiagnosticRow(
      id: id,
      status: DiagnosticStatus.pass,
      summary: 'Socket Mode is connected${connectedAt == null ? '' : ' (since $connectedAt)'}.',
    );
  }
  if (connectedAt == null) {
    if (state['connection'] == 'connecting' && failures == 0) {
      return const DiagnosticRow(
        id: id,
        status: DiagnosticStatus.warn,
        summary: 'Socket Mode is still connecting for the first time.',
        remediation: 'Rerun dartclaw doctor in a few seconds.',
      );
    }
    return DiagnosticRow(
      id: id,
      status: DiagnosticStatus.fail,
      summary: 'Socket Mode has never connected ($failures consecutive failures).',
      remediation:
          'Check that Socket Mode is enabled in the Slack app and that the app-level token has the '
          'connections:write scope; the server log names the failure.',
    );
  }
  return DiagnosticRow(
    id: id,
    status: DiagnosticStatus.warn,
    summary: 'Socket Mode is reconnecting after $failures consecutive failures (last connected $connectedAt).',
    remediation: 'The server retries with backoff; if it persists, check the server log and slack.com status.',
  );
}

DiagnosticRow _eventsRow(Map<dynamic, dynamic> state, SlackConfig slack) {
  const id = 'slack.transport';
  final verifiedAt = state['last_verified_at'];
  final reason = state['last_failure_reason'];
  final failedAt = DateTime.tryParse('${state['last_failure_at']}');
  final verified = DateTime.tryParse('$verifiedAt');
  final failureIsLatest = reason != null && (verified == null || failedAt == null || failedAt.isAfter(verified));
  if (failureIsLatest) {
    switch (reason) {
      case 'invalid_slack_signature':
        final name = slack.signingSecretCredential;
        return DiagnosticRow(
          id: id,
          status: DiagnosticStatus.fail,
          summary:
              'Slack requests fail signature verification; the signing secret in '
              '${name == null ? 'channels.slack.signing_secret_credential' : 'credentials.$name'} is likely wrong.',
          remediation:
              'Copy the Signing Secret from Basic Information in the Slack app into that credential and restart '
              'the server. A forged request looks the same, so this is a likely cause, not a certain one.',
        );
      case 'stale_slack_timestamp':
        return const DiagnosticRow(
          id: id,
          status: DiagnosticStatus.warn,
          summary: 'Slack requests arrive with timestamps more than 5 minutes off; the server clock may be skewed.',
          remediation: 'Sync the host clock (NTP) and rerun dartclaw doctor.',
        );
      case 'missing_slack_signature':
        return const DiagnosticRow(
          id: id,
          status: DiagnosticStatus.warn,
          summary: 'Requests reached the Slack route without Slack signature headers.',
          remediation: 'A reverse proxy may be stripping X-Slack-Signature or X-Slack-Request-Timestamp.',
        );
    }
  }
  if (verifiedAt == null) {
    return DiagnosticRow(
      id: id,
      status: DiagnosticStatus.warn,
      summary: 'No Slack request has reached the server yet.',
      remediation:
          'Check that the Request URLs in the Slack app end in ${slack.webhookPath} and reach this server, '
          'then send the app a message.',
    );
  }
  return DiagnosticRow(
    id: id,
    status: DiagnosticStatus.pass,
    summary: 'The last verified Slack request arrived at $verifiedAt.',
  );
}

/// One `channels.slack.*_credential` key resolved against the merged credentials.
class _Reference {
  new(this.key, String? name, CredentialsConfig credentials)
    : name = name?.trim() ?? '',
      _entry = credentials[name?.trim() ?? ''];

  final String key;
  final String name;
  final CredentialEntry? _entry;

  /// The usable value, or `null` when the reference does not resolve to one.
  String? get secret => problem == null ? _entry!.secret : null;

  String? get problem {
    final path = 'channels.slack.$key';
    final entry = _entry;
    if (name.isEmpty) return '$path is not set.';
    if (entry == null) return '$path names credential $name, which is neither declared nor stored.';
    if (!entry.isApiKeyCredential) return '$path names credential $name, which is not an api_key credential.';
    if (!entry.isPresent) {
      final variables = entry.envVars.isEmpty ? '' : ' (set ${entry.envVars.join(', ')})';
      return '$path names credential $name, which resolves to an empty value$variables.';
    }
    return null;
  }
}
