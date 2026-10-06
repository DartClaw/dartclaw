import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/config_loader.dart';
import 'package:dartclaw_cli/src/commands/doctor_command.dart';
import 'package:dartclaw_cli/src/commands/init/setup_checks.dart';
import 'package:dartclaw_cli/src/runner.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show dartclawVersion;
import 'package:dartclaw_slack/dartclaw_slack.dart';
import 'package:dartclaw_slack/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/fake_exit.dart';

const _botToken = 'xoxb-DOCTOR-BOT-TOKEN-1234';
const _appToken = 'xapp-DOCTOR-APP-TOKEN-5678';
const _signingSecret = 'doctor-signing-secret-no-token-shape';
const _secrets = [_botToken, _appToken, _signingSecret];

Future<List<DiagnosticRow>> _databaseReady(
  DartclawConfig _, {
  required bool bootstrap,
  required Map<String, String> environment,
}) async => const [];

void main() {
  late Directory root;
  late String dataDir;
  late File config;
  late Map<String, String> environment;
  late List<String> lines;
  late FakeSlackWebApi slack;
  late List<String> tokensPresented;
  Map<String, dynamic>? health;

  setUp(() {
    root = Directory.systemTemp.createTempSync('doctor_slack_');
    dataDir = p.join(root.path, 'data');
    environment = {
      'HOME': p.join(root.path, 'home'),
      'PATH': '',
      'SLACK_BOT_TOKEN': _botToken,
      'SLACK_APP_TOKEN': _appToken,
      'SLACK_SIGNING_SECRET': _signingSecret,
    };
    config = File(p.join(root.path, 'dartclaw.yaml'));
    lines = [];
    slack = FakeSlackWebApi();
    tokensPresented = [];
    health = null;
    for (final name in ['workspace', 'sessions', 'logs']) {
      Directory(p.join(dataDir, name)).createSync(recursive: true);
    }
  });
  tearDown(() {
    DartclawConfig.clearStoredCredentialProvider();
    root.deleteSync(recursive: true);
  });

  /// Declares the credentials every reference below names, via environment variables.
  void writeConfig({String mode = 'socket', bool enabled = true, String references = '', String credentials = ''}) {
    final refs = references.isNotEmpty
        ? references
        : mode == 'socket'
        ? '    bot_token_credential: slack_bot\n    app_token_credential: slack_app\n'
        : '    bot_token_credential: slack_bot\n    signing_secret_credential: slack_signing\n';
    final declared = credentials.isNotEmpty
        ? credentials
        : '''
  slack_bot:
    type: api-key
    api_key: \${SLACK_BOT_TOKEN}
  slack_app:
    type: api-key
    api_key: \${SLACK_APP_TOKEN}
  slack_signing:
    type: api-key
    api_key: \${SLACK_SIGNING_SECRET}
''';
    config.writeAsStringSync(
      'data_dir: $dataDir\n'
      'providers:\n  claude:\n    executable: unavailable-claude\n'
      'credentials:\n$declared'
      'channels:\n  slack:\n    enabled: $enabled\n    mode: $mode\n    dm_access: open\n$refs',
    );
    if (!Platform.isWindows) Process.runSync('chmod', ['600', config.path]);
  }

  Map<String, dynamic> serverHealth(Map<String, dynamic>? slackState) => {
    'version': dartclawVersion,
    'uptime_s': 5,
    'slack': ?slackState,
  };

  Future<int> run(List<String> args) async {
    final runner = DartclawRunner()
      ..addCommand(
        DoctorCommand(
          setupChecks: SetupChecks(
            databaseReadiness: _databaseReady,
            probeBinary: (_) async => (outcome: BinaryProbeOutcome.responded, version: '2.1.80'),
            portFree: (_) async => true,
            providerVerified: (_, _, _) async => true,
            runCommand: (_, _) async => ProcessResult(0, 1, '', ''),
            serverHealth: (_, _) async => health,
            slackClientFactory: (token) {
              tokensPresented.add(token);
              return slack;
            },
          ),
          writeLine: lines.add,
          exitFn: fakeExit,
          environment: environment,
          platformCapabilities: PlatformCapabilities(operatingSystem: 'linux', environment: environment),
        ),
      );
    try {
      await runner.run([
        '--config',
        config.path,
        if (health != null) ...['--server', 'http://127.0.0.1:1'],
        'doctor',
        ...args,
      ]);
      return 0;
    } on FakeExit catch (error) {
      return error.code;
    }
  }

  /// Runs doctor as text and as JSON, checks the two agree, and returns the Slack rows by id.
  Future<Map<String, Map<String, dynamic>>> slackRows({bool? fails}) async {
    final textExit = await run([]);
    final text = List.of(lines);
    lines.clear();
    final jsonExit = await run(['--json']);
    expect(textExit, jsonExit);
    final rows = ((jsonDecode(lines.single) as Map<String, dynamic>)['checks'] as List).cast<Map<String, dynamic>>();
    final byId = {
      for (final row in rows)
        if ((row['id'] as String).startsWith('slack.')) row['id'] as String: row,
    };
    expect(
      [
        for (final line in text)
          if (line.startsWith('[') && line.split(' ')[1].startsWith('slack.')) line.split(' ').take(2).join(' '),
      ],
      [for (final row in byId.values) '[${row['status']}] ${row['id']}'],
    );
    final output = '${text.join('\n')}\n${lines.join('\n')}';
    for (final secret in _secrets) {
      expect(output, isNot(contains(secret)), reason: 'doctor output must not carry a Slack secret');
    }
    if (fails != null) {
      expect(byId.values.any((r) => r['status'] == 'fail'), fails, reason: 'a Slack row failing is what fails the run');
    }
    return byId;
  }

  Map<String, dynamic> row(Map<String, Map<String, dynamic>> rows, String id) => rows[id]!;
  String text(Map<String, dynamic> row) =>
      '${row['summary']} ${(row['detail'] ?? const []).join(' ')} ${row['remediation'] ?? ''}';

  group('rows exist only while Slack is enabled', () {
    test('S12 a disabled Slack adds no row, text or JSON', () async {
      writeConfig(enabled: false);
      slack.authError = const SlackApiException('x', errorCode: 'invalid_auth');
      expect(await slackRows(), isEmpty);
      expect(slack.authTestCalls, 0, reason: 'a disabled channel is never called');
    });

    test('S12 an enabled Slack adds the four rows in order', () async {
      writeConfig();
      final rows = await slackRows();
      expect(rows.keys, ['slack.credentials', 'slack.auth', 'slack.scopes', 'slack.transport']);
    });
  });

  group('credentials row', () {
    test('S12 a healthy setup passes credentials, auth and scopes', () async {
      writeConfig();
      health = serverHealth({'mode': 'socket', 'connection': 'connected', 'consecutive_failures': 0});
      final rows = await slackRows(fails: false);
      expect(
        {for (final r in rows.values) r['id']: r['status']},
        {'slack.credentials': 'pass', 'slack.auth': 'pass', 'slack.scopes': 'pass', 'slack.transport': 'pass'},
      );
      expect(tokensPresented, everyElement(_botToken));
    });

    test('S12 a reference naming no credential fails naming the config key and the credential', () async {
      writeConfig(
        credentials: '  slack_app:\n    type: api-key\n    api_key: \${SLACK_APP_TOKEN}\n',
        references: '    bot_token_credential: absent_bot\n    app_token_credential: slack_app\n',
      );
      final rows = await slackRows(fails: true);
      expect(row(rows, 'slack.credentials')['status'], 'fail');
      expect(
        text(row(rows, 'slack.credentials')),
        allOf(contains('channels.slack.bot_token_credential'), contains('absent_bot')),
      );
      expect(text(row(rows, 'slack.credentials')), contains('dartclaw secrets set absent_bot'));
      expect(slack.authTestCalls, 0, reason: 'no token to present, so Slack is not called');
      expect(row(rows, 'slack.auth')['status'], 'skip');
      expect(row(rows, 'slack.scopes')['status'], 'skip');
    });

    test('S12 a credential that resolves empty fails naming the config key and the credential', () async {
      environment['SLACK_APP_TOKEN'] = '';
      writeConfig();
      final rows = await slackRows(fails: true);
      final credentials = row(rows, 'slack.credentials');
      expect(credentials['status'], 'fail');
      expect(
        text(credentials),
        allOf(contains('channels.slack.app_token_credential'), contains('slack_app'), contains('empty')),
      );
      expect(row(rows, 'slack.auth')['status'], 'pass', reason: 'the bot token is fine, so auth still runs');
    });

    test('S12 events mode judges the signing secret, not the app token', () async {
      writeConfig(mode: 'events', credentials: '  slack_bot:\n    type: api-key\n    api_key: \${SLACK_BOT_TOKEN}\n');
      final rows = await slackRows(fails: true);
      expect(
        text(row(rows, 'slack.credentials')),
        allOf(contains('channels.slack.signing_secret_credential'), contains('slack_signing')),
      );
      expect(text(row(rows, 'slack.credentials')), isNot(contains('app_token_credential')));
    });

    test(
      'S11 a credential held only in the store loads, passes config.valid and authenticates with the stored value',
      () async {
        writeConfig(
          credentials: '  unrelated:\n    type: api-key\n    api_key: \${SLACK_APP_TOKEN}\n',
          references: '    bot_token_credential: slack_bot\n    app_token_credential: unrelated\n',
        );
        NamedCredentialStore.open(
          credentialsDir: p.join(dataDir, 'credentials'),
          environment: environment,
        ).write('slack_bot', const CredentialEntry(apiKey: _botToken));

        expect(
          () => loadCliConfig(configPath: config.path, env: environment, resolveStoredCredentials: false),
          returnsNormally,
          reason: 'the stored view is off, so a store-only reference cannot be judged at load',
        );
        final rows = await slackRows();
        expect(row(rows, 'slack.credentials')['status'], 'pass');
        expect(row(rows, 'slack.auth')['status'], 'pass');
        expect(tokensPresented.toSet(), {_botToken});
        expect(lines.single, isNot(contains(_botToken)));
        final all = (jsonDecode(lines.single)['checks'] as List).cast<Map<String, dynamic>>();
        expect(all.singleWhere((r) => r['id'] == 'config.valid')['status'], 'pass');
      },
    );

    test('S11 a literal token in a reference key is still refused by config.valid and adds no Slack row', () async {
      writeConfig(references: '    bot_token_credential: $_botToken\n    app_token_credential: slack_app\n');
      expect(await run(['--json']), 1);
      final checks = (jsonDecode(lines.single)['checks'] as List).cast<Map<String, dynamic>>();
      expect(checks.singleWhere((r) => r['id'] == 'config.valid')['status'], 'fail');
      expect(checks.where((r) => (r['id'] as String).startsWith('slack.')), isEmpty);
      expect(lines.single, isNot(contains(_botToken)));
    });
  });

  group('auth and scopes rows', () {
    for (final code in ['token_revoked', 'invalid_auth']) {
      test('S12 Slack rejecting the token as $code fails auth with the code and the reinstall fix', () async {
        writeConfig();
        slack.authError = SlackApiException('Slack API auth.test failed: $code', errorCode: code);
        final rows = await slackRows(fails: true);
        final auth = row(rows, 'slack.auth');
        expect(auth['status'], 'fail');
        expect(text(auth), contains(code));
        expect(text(auth), allOf(contains('Reinstall'), contains('credential'), contains('slack_bot')));
        expect(row(rows, 'slack.scopes')['status'], 'skip', reason: 'scopes of a rejected token are unknowable');
      });
    }

    test('S12 a token without assistant:write fails scopes naming it, and only it', () async {
      writeConfig();
      slack.scopes = [...slackExpectedBotScopes]..remove('assistant:write');
      final rows = await slackRows(fails: true);
      final scopes = row(rows, 'slack.scopes');
      expect(scopes['status'], 'fail');
      expect(text(scopes), contains('assistant:write'));
      expect(text(scopes), isNot(contains('chat:write')));
      expect(row(rows, 'slack.auth')['status'], 'pass');
    });

    test('S12 every missing scope is named', () async {
      writeConfig();
      slack.scopes = ['chat:write'];
      final scopes = row(await slackRows(fails: true), 'slack.scopes');
      for (final missing in slackExpectedBotScopes.where((s) => s != 'chat:write')) {
        expect(text(scopes), contains(missing));
      }
    });

    test('S12 scopes beyond the manifest warn without failing the run', () async {
      writeConfig();
      slack.scopes = [...slackExpectedBotScopes, 'admin.users:write'];
      final scopes = row(await slackRows(fails: false), 'slack.scopes');
      expect(scopes['status'], 'warn');
      expect(text(scopes), contains('admin.users:write'));
    });

    test('S12 missing and extra scopes together still fail', () async {
      writeConfig();
      slack.scopes = [...slackExpectedBotScopes.skip(1), 'admin.users:write'];
      final scopes = row(await slackRows(fails: true), 'slack.scopes');
      expect(scopes['status'], 'fail');
      expect(text(scopes), allOf(contains(slackExpectedBotScopes.first), contains('admin.users:write')));
    });

    test('S12 an unreachable Slack is a warning, not a failure', () async {
      writeConfig();
      slack.authError = const SlackApiException('Slack API auth.test request failed (SocketException)');
      final rows = await slackRows(fails: false);
      expect(row(rows, 'slack.auth')['status'], 'warn');
      expect(text(row(rows, 'slack.auth')), contains('unreachable'));
      expect(row(rows, 'slack.scopes')['status'], 'skip');
    });

    test('S12 a rate-limited auth.test warns and does not blame the token', () async {
      writeConfig();
      slack.authError = const SlackApiException(
        'Slack API auth.test rate limited',
        errorCode: 'ratelimited',
        statusCode: 429,
      );
      final rows = await slackRows(fails: false);
      expect(row(rows, 'slack.auth')['status'], 'warn');
      expect(text(row(rows, 'slack.auth')), isNot(contains('Reinstall')));
    });

    test('S12 a token for which Slack reports no scopes warns instead of naming ten scopes as missing', () async {
      writeConfig();
      slack.scopes = [];
      final scopes = row(await slackRows(fails: false), 'slack.scopes');
      expect(scopes['status'], 'warn');
      expect(text(scopes), contains('no scopes'));
    });
  });

  group('transport row', () {
    Future<Map<String, dynamic>> transport({required String mode, Map<String, dynamic>? state, bool? fails}) async {
      writeConfig(mode: mode);
      health = serverHealth(state);
      return row(await slackRows(fails: fails), 'slack.transport');
    }

    test('S13 with no running server the row is skipped with the serve fix', () async {
      writeConfig();
      final transport = row(await slackRows(fails: false), 'slack.transport');
      expect(transport['status'], 'skip');
      expect(transport['summary'], contains('running server'));
      expect(text(transport), contains('dartclaw serve'));
    });

    test('S13 a running server that reports no Slack state warns', () async {
      final result = await transport(mode: 'socket', state: null, fails: false);
      expect(result['status'], 'warn');
      expect(text(result), contains('no Slack state'));
    });

    test('S13 a connected socket passes with the last connect time', () async {
      final result = await transport(
        mode: 'socket',
        state: {
          'mode': 'socket',
          'connection': 'connected',
          'last_connected_at': '2026-10-06T08:00:00.000Z',
          'consecutive_failures': 0,
        },
        fails: false,
      );
      expect(result['status'], 'pass');
      expect(text(result), contains('2026-10-06T08:00:00.000Z'));
    });

    test('S13 a socket reconnecting after failures warns naming the count', () async {
      final result = await transport(
        mode: 'socket',
        state: {
          'mode': 'socket',
          'connection': 'disconnected',
          'last_connected_at': '2026-10-06T08:00:00.000Z',
          'consecutive_failures': 4,
        },
        fails: false,
      );
      expect(result['status'], 'warn');
      expect(text(result), allOf(contains('4 consecutive failures'), contains('2026-10-06T08:00:00.000Z')));
    });

    test('S13 a socket that never connected fails and points at the app-level token and Socket Mode', () async {
      final result = await transport(
        mode: 'socket',
        state: {'mode': 'socket', 'connection': 'disconnected', 'consecutive_failures': 6},
        fails: true,
      );
      expect(result['status'], 'fail');
      expect(text(result), allOf(contains('never connected'), contains('6'), contains('connections:write')));
    });

    test('S13 a socket still on its first attempt warns instead of failing', () async {
      final result = await transport(
        mode: 'socket',
        state: {'mode': 'socket', 'connection': 'connecting', 'consecutive_failures': 0},
        fails: false,
      );
      expect(result['status'], 'warn');
    });

    test('S13 events mode with no request yet warns and names the request URL path', () async {
      final result = await transport(mode: 'events', state: {'mode': 'events'}, fails: false);
      expect(result['status'], 'warn');
      expect(text(result), allOf(contains('No Slack request'), contains('/integrations/slack')));
    });

    test('S13 events mode with a verified request passes with its time', () async {
      final result = await transport(
        mode: 'events',
        state: {'mode': 'events', 'last_verified_at': '2026-10-06T08:00:00.000Z'},
        fails: false,
      );
      expect(result['status'], 'pass');
      expect(text(result), contains('2026-10-06T08:00:00.000Z'));
    });

    test('S13 a stale-timestamp failure warns about clock skew', () async {
      final result = await transport(
        mode: 'events',
        state: {
          'mode': 'events',
          'last_failure_reason': 'stale_slack_timestamp',
          'last_failure_at': '2026-10-06T08:00:00.000Z',
        },
        fails: false,
      );
      expect(result['status'], 'warn');
      expect(text(result), contains('clock'));
    });

    test(
      'S13 an invalid signature newer than the last verified request fails naming the signing secret as likely',
      () async {
        final result = await transport(
          mode: 'events',
          state: {
            'mode': 'events',
            'last_verified_at': '2026-10-06T08:00:00.000Z',
            'last_failure_reason': 'invalid_slack_signature',
            'last_failure_at': '2026-10-06T08:05:00.000Z',
          },
          fails: true,
        );
        expect(result['status'], 'fail');
        expect(
          text(result),
          allOf(contains('signing secret'), contains('credentials.slack_signing'), contains('likely')),
        );
      },
    );

    test('S13 an invalid signature with no verified request at all fails the same way', () async {
      final result = await transport(
        mode: 'events',
        state: {
          'mode': 'events',
          'last_failure_reason': 'invalid_slack_signature',
          'last_failure_at': '2026-10-06T08:05:00.000Z',
        },
        fails: true,
      );
      expect(result['status'], 'fail');
    });

    test(
      'S13 an invalid signature older than the last verified request passes: the secret demonstrably works',
      () async {
        final result = await transport(
          mode: 'events',
          state: {
            'mode': 'events',
            'last_verified_at': '2026-10-06T08:10:00.000Z',
            'last_failure_reason': 'invalid_slack_signature',
            'last_failure_at': '2026-10-06T08:05:00.000Z',
          },
          fails: false,
        );
        expect(result['status'], 'pass');
      },
    );

    test('S13 requests arriving without Slack signature headers warn about a proxy stripping them', () async {
      final result = await transport(
        mode: 'events',
        state: {
          'mode': 'events',
          'last_failure_reason': 'missing_slack_signature',
          'last_failure_at': '2026-10-06T08:05:00.000Z',
        },
        fails: false,
      );
      expect(result['status'], 'warn');
      expect(text(result), contains('proxy'));
    });
  });
}
