import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_slack/dartclaw_slack.dart';
import 'package:test/test.dart';

const _botToken = 'xoxb-1111111111-2222222222-AbCdEfGhIjKlMnOpQrStUvWx';
const _appToken = 'xapp-1-A0123456789-5555555555-a1b2c3d4e5f6a1b2c3d4e5f6';

const _credentials = '''
credentials:
  slack_bot:
    api_key: \${SLACK_BOT_TOKEN}
  slack_app:
    api_key: \${SLACK_APP_TOKEN}
''';

const _env = {'HOME': '/h', 'SLACK_BOT_TOKEN': _botToken, 'SLACK_APP_TOKEN': _appToken};

String _slack(String body) => '$_credentials\nchannels:\n  slack:\n    enabled: true\n$body';

const _validBody = '    bot_token_credential: slack_bot\n    app_token_credential: slack_app\n';

DartclawConfig _load(String yaml, {Map<String, String> env = _env, bool resolveStoredCredentials = true}) =>
    loadDartclawConfig(
      configPath: 'dartclaw.yaml',
      fileReader: (path) => path == 'dartclaw.yaml' ? yaml : null,
      env: env,
      resolveStoredCredentials: resolveStoredCredentials,
    );

/// The refusal a load raises, with the secrets this file feeds it asserted absent.
String _refusal(String yaml, {Map<String, String> env = _env, bool resolveStoredCredentials = true}) {
  try {
    _load(yaml, env: env, resolveStoredCredentials: resolveStoredCredentials);
  } on FormatException catch (error) {
    for (final secret in [_botToken, _appToken, 'plain-secret-value', 'alice']) {
      expect(error.message, isNot(contains(secret)), reason: 'a refusal must never repeat a value from the file');
    }
    return error.message;
  }
  fail('Expected the load to be refused');
}

void main() {
  test('a valid reference pair loads and resolves both tokens', () {
    final config = _load(_slack(_validBody));

    final slack = resolveChannelConfig<SlackConfig>(config, ChannelType.slack);
    expect(slack.enabled, isTrue);
    expect(config.credentials[slack.botTokenCredential!]!.secret, _botToken);
    expect(config.credentials[slack.appTokenCredential!]!.secret, _appToken);
    expect(config.warnings, isEmpty);
  });

  test('a section that is not enabled is never refused', () {
    final config = _load('channels:\n  slack:\n    bot_token_credential: $_botToken\n    dm_access: disabled\n');

    expect(resolveChannelConfig<SlackConfig>(config, ChannelType.slack).enabled, isFalse);
  });

  group('credential references', () {
    test('a literal bot token is refused with the credentials.<name> form, without repeating it', () {
      final message = _refusal(_slack('    bot_token_credential: $_botToken\n    app_token_credential: slack_app\n'));

      expect(message, contains('channels.slack.bot_token_credential'));
      expect(message, contains('credentials.<name>'));
    });

    test('a literal app token is refused the same way', () {
      final message = _refusal(_slack('    bot_token_credential: slack_bot\n    app_token_credential: $_appToken\n'));

      expect(message, contains('channels.slack.app_token_credential'));
      expect(message, contains('credentials.<name>'));
    });

    test('a name no credentials entry carries is refused, and the name is not echoed', () {
      final message = _refusal(
        _slack('    bot_token_credential: plain-secret-value\n    app_token_credential: slack_app\n'),
      );

      expect(message, contains('channels.slack.bot_token_credential: names no credentials entry'));
    });

    test(
      'a load that skipped stored credentials cannot tell a missing entry from a stored one, so it refuses nothing',
      () {
        final config = _load(
          _slack('    bot_token_credential: stored_only_name\n    app_token_credential: slack_app\n'),
          resolveStoredCredentials: false,
        );

        expect(resolveChannelConfig<SlackConfig>(config, ChannelType.slack).botTokenCredential, 'stored_only_name');
      },
    );

    test('a literal token is refused even when stored credentials were not resolved', () {
      final message = _refusal(
        _slack('    bot_token_credential: $_botToken\n    app_token_credential: slack_app\n'),
        resolveStoredCredentials: false,
      );

      expect(message, contains('holds a Slack token'));
    });

    test('an entry that resolves empty is refused', () {
      final message = _refusal(_slack(_validBody), env: const {'HOME': '/h', 'SLACK_APP_TOKEN': _appToken});

      expect(message, contains('channels.slack.bot_token_credential'));
      expect(message, anyOf(contains('empty value'), contains('names no credentials entry')));
    });

    test('a missing bot reference and a missing app reference are each refused by key', () {
      expect(
        _refusal(_slack('    app_token_credential: slack_app\n')),
        contains('channels.slack.bot_token_credential: required'),
      );
      expect(
        _refusal(_slack('    bot_token_credential: slack_bot\n')),
        contains('channels.slack.app_token_credential: required'),
      );
    });

    test('an entry that is not an api_key credential is refused', () {
      const yaml = '''
credentials:
  slack_bot:
    type: github-token
    token: abc
  slack_app:
    api_key: \${SLACK_APP_TOKEN}
channels:
  slack:
    enabled: true
    bot_token_credential: slack_bot
    app_token_credential: slack_app
''';

      expect(_refusal(yaml), contains('channels.slack.bot_token_credential: must name an api_key credentials entry'));
    });
  });

  group('access and identifiers', () {
    test('both dm_access and group_access disabled is refused', () {
      final message = _refusal(_slack('$_validBody    dm_access: disabled\n    group_access: disabled\n'));

      expect(message, contains('dm_access and group_access are both disabled'));
    });

    test('a channel ID outside ^[CG][A-Z0-9]+\$ is refused by position', () {
      final message = _refusal(
        _slack('$_validBody    group_access: allowlist\n    group_allowlist:\n      - C0123ABC\n      - general\n'),
      );

      expect(message, contains('channels.slack.group_allowlist: entry 2 is not a Slack channel ID'));
      expect(message, isNot(contains('entry 1')));
    });

    test('a user ID outside ^[UW][A-Z0-9]+\$ is refused by position', () {
      final message = _refusal(
        _slack('$_validBody    dm_access: allowlist\n    dm_allowlist:\n      - alice\n      - U0123ABC\n'),
      );

      expect(message, contains('channels.slack.dm_allowlist: entry 1 is not a Slack user ID'));
    });

    test('plain IDs and bound rows with valid IDs load', () {
      final config = _load('''
agent:
  agents:
    eng-bot:
      prompt: You build.
${_slack('''
$_validBody    dm_access: allowlist
    dm_allowlist:
      - U0123ABC
      - id: W0456DEF
        name: Bo
    group_access: allowlist
    group_allowlist:
      - C0123ABC
      - id: G0456DEF
        agent: eng-bot
''')}''');

      final slack = resolveChannelConfig<SlackConfig>(config, ChannelType.slack);
      expect(slack.groupIds, ['C0123ABC', 'G0456DEF']);
      expect(slack.groupAllowlist.last.agent, 'eng-bot');
    });

    test('a row binding an agent that agent.agents does not declare is refused like on every channel', () {
      final message = _refusal(
        _slack(
          '$_validBody    group_access: allowlist\n    group_allowlist:\n      - id: C0123ABC\n        agent: nope\n',
        ),
      );

      expect(message, startsWith('channels.slack.group_allowlist'));
      expect(message, contains('"nope"'));
    });

    test('every problem is reported in one refusal', () {
      final message = _refusal(_slack('    dm_access: disabled\n    group_access: disabled\n'));

      expect(message, contains('both disabled'));
      expect(message, contains('bot_token_credential'));
      expect(message, contains('app_token_credential'));
    });
  });

  group('keys', () {
    test('a key channels.slack does not register is refused at load', () {
      expect(
        () => _load(_slack('$_validBody    signing_secret_credential: slack_app\n')),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('channels.slack.signing_secret_credential'),
          ),
        ),
      );
    });

    test('mode accepts only socket', () {
      expect(_refusal(_slack('$_validBody    mode: events\n')), contains('channels.slack.mode'));
      expect(_load(_slack('$_validBody    mode: socket\n')).warnings, isEmpty);
    });
  });
}
