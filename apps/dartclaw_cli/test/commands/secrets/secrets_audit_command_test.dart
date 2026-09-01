import 'dart:io';

import 'package:dartclaw_cli/src/commands/secrets/secrets_command.dart';
import 'package:dartclaw_cli/src/runner.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show ConfigSerializer, RuntimeConfig;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../helpers/fake_exit.dart';

const _storedSecret = 'STORED-BRAVE-SECRET';
const _literalSecret = 'LITERAL-CONFIG-SECRET';

void main() {
  late Directory root;
  late String home;
  late String dataDir;
  late String credentialsDir;
  late File configFile;
  late List<String> stdoutLines;
  late List<String> stderrLines;

  setUp(() {
    root = Directory.systemTemp.createTempSync('secrets_audit_');
    home = p.join(root.path, 'home');
    Directory(home).createSync(recursive: true);
    dataDir = p.join(root.path, 'data');
    credentialsDir = p.join(dataDir, 'credentials');
    configFile = File(p.join(root.path, 'dartclaw.yaml'));
    stdoutLines = <String>[];
    stderrLines = <String>[];
  });

  tearDown(() {
    DartclawConfig.clearStoredCredentialProvider();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Map<String, String> env([Map<String, String> extra = const {}]) => {'HOME': home, ...extra};

  String output() => [...stdoutLines, ...stderrLines].join('\n');

  void writeConfig(String yaml) {
    configFile.writeAsStringSync('data_dir: $dataDir\n$yaml');
    if (!Platform.isWindows) Process.runSync('chmod', ['600', configFile.path]);
  }

  NamedCredentialStore openStore() => NamedCredentialStore.open(credentialsDir: credentialsDir, environment: env());

  Future<int?> runAudit([Map<String, String> extraEnv = const {}]) async {
    final runner = DartclawRunner()
      ..addCommand(
        SecretsCommand(
          stdoutLine: stdoutLines.add,
          stderrLine: stderrLines.add,
          exitFn: fakeExit,
          environment: env(extraEnv),
        ),
      );
    try {
      await runner.run(['--config', configFile.path, 'secrets', 'audit']);
      return null;
    } on FakeExit catch (failure) {
      return failure.code;
    }
  }

  test('every finding class is reported with its config path, and the exit code is non-zero', () async {
    writeConfig(
      'credentials:\n'
      '  literal-x:\n    api_key: $_literalSecret\n'
      '  orphan-z:\n    api_key: \${ORPHAN_VAR}\n'
      '  shadowed:\n    api_key: \${SHADOW_VAR}\n'
      'search:\n  providers:\n    brave:\n      enabled: true\n      api_key: \${UNSET}\n'
      'mcp_servers:\n  demo:\n    url: https://example.test\n    network_class: public\n    credential: shadowed\n',
    );
    openStore().write('shadowed', const CredentialEntry(apiKey: _storedSecret));
    if (!Platform.isWindows) {
      final loose = File(p.join(credentialsDir, 'named', 'loose.json'))
        ..writeAsStringSync('{"type":"api-key","secret":"$_storedSecret"}');
      Process.runSync('chmod', ['644', loose.path]);
    }

    final code = await runAudit();

    expect(code, 1, reason: 'the audit gates a deployment, so a finding is a non-zero exit');
    final rendered = output();
    expect(rendered, contains('Literals in config'));
    expect(rendered, contains('credentials.literal-x'));
    expect(rendered, contains('Unresolvable references'));
    expect(rendered, contains('search.providers.brave.api_key'));
    expect(rendered, contains('UNSET'), reason: 'the unresolvable finding names the variable');
    expect(rendered, contains('Shadowed entries'));
    expect(rendered, contains('credentials.shadowed'));
    expect(rendered, contains('Orphans'));
    expect(rendered, contains('credentials.orphan-z'));
    if (!Platform.isWindows) {
      expect(rendered, contains('Permissions'));
      expect(rendered, contains('loose.json'));
    }

    for (final secret in [_storedSecret, _literalSecret]) {
      for (var start = 0; start + 6 <= secret.length; start++) {
        expect(
          rendered,
          isNot(contains(secret.substring(start, start + 6))),
          reason: 'the audit prints no value and no value prefix',
        );
      }
    }
  });

  test('a consumed reference is not reported as an orphan', () async {
    writeConfig(
      'credentials:\n  brave-search:\n    api_key: \${BRAVE_VAR}\n'
      'search:\n  providers:\n    brave:\n      enabled: true\n      credential: brave-search\n',
    );
    await runAudit();
    expect(output(), isNot(contains('is consumed by no')));
  });

  test('whitespace-only environment references are unresolvable', () async {
    writeConfig(
      'credentials:\n  brave-search:\n    api_key: \${NAMED_KEY}\n'
      'search:\n  providers:\n    brave:\n      enabled: true\n      api_key: \${DIRECT_KEY}\n',
    );

    final code = await runAudit(const {'NAMED_KEY': '   ', 'DIRECT_KEY': '  '});

    expect(code, 1);
    expect(output(), contains('credentials.brave-search'));
    expect(output(), contains('search.providers.brave.api_key'));
    expect(output(), contains('NAMED_KEY'));
    expect(output(), contains('DIRECT_KEY'));
  });

  test('mixed literal and environment templates are reported as literals', () async {
    writeConfig(
      'credentials:\n  mixed:\n    api_key: prefix-\${KEY}\n'
      'search:\n  providers:\n    brave:\n      enabled: true\n      api_key: prefix-\${KEY}\n'
      'github:\n  webhook_secret: prefix-\${KEY}\n',
    );

    final code = await runAudit(const {'KEY': 'resolved'});

    expect(code, 1);
    expect(output(), contains('credentials.mixed'));
    expect(output(), contains('search.providers.brave.api_key'));
    expect(output(), contains('github.webhook_secret'));
    expect(output(), isNot(contains('prefix-resolved')));
  });

  test('an instance whose only secrets are in the store audits clean', () async {
    writeConfig('');
    openStore().write('brave-search', const CredentialEntry(apiKey: _storedSecret));

    final code = await runAudit();

    expect(code, isNull, reason: 'exit 0');
    expect(output(), contains('No secret was found outside the credential store'));
  });

  test('the permissions class is stated as not applicable on Windows', () async {
    writeConfig('');
    openStore().write('brave-search', const CredentialEntry(apiKey: _storedSecret));
    if (!Platform.isWindows) {
      final loose = File(p.join(credentialsDir, 'named', 'brave-search.json'));
      Process.runSync('chmod', ['644', loose.path]);
    }

    final code = await runAudit();

    if (Platform.isWindows) {
      expect(code, isNull, reason: 'the exit code does not differ by platform for the same logical state');
      expect(output(), contains('not applicable on Windows'));
    } else {
      expect(code, 1);
      expect(output(), contains('Permissions'));
    }
  });

  test('audit does not provision a missing credential store', () async {
    writeConfig('');

    final code = await runAudit();

    expect(code, isNull);
    expect(Directory(credentialsDir).existsSync(), isFalse);
  });

  test('audit reports a credential directory accessible beyond its owner', () async {
    if (Platform.isWindows) return;
    writeConfig('');
    final store = openStore();
    store.write('brave-search', const CredentialEntry(apiKey: _storedSecret));
    Process.runSync('chmod', ['755', store.namedDir]);

    final code = await runAudit();

    expect(code, 1);
    expect(output(), contains(store.namedDir));
    expect(output(), contains('accessible beyond its owner'));
    expect(output(), contains('755'));
  });

  test('audit follows a symlinked named store when checking permissions', () async {
    if (Platform.isWindows) return;
    writeConfig('');
    Directory(credentialsDir).createSync(recursive: true);
    Process.runSync('chmod', ['700', credentialsDir]);
    final target = Directory(p.join(root.path, 'named-target'))..createSync();
    Process.runSync('chmod', ['700', target.path]);
    final loose = File(p.join(target.path, 'brave-search.json'))
      ..writeAsStringSync('{"type":"api-key","secret":"$_storedSecret"}');
    Process.runSync('chmod', ['644', loose.path]);
    Link(p.join(credentialsDir, 'named')).createSync(target.path);

    final code = await runAudit();

    expect(code, 1);
    expect(output(), contains('Permissions'));
    expect(output(), contains('brave-search.json'));
    expect(output(), isNot(contains(_storedSecret)));
  });

  test('the merged config does not echo a stored credential over the config API', () {
    // ConfigSerializer emits no `credentials` key and only the search backend,
    // so merging stored credentials into the in-memory config cannot surface
    // them on GET /api/config or the PATCH read-before-merge.
    DartclawConfig.registerStoredCredentialProvider(
      (_) => const {'brave-search': CredentialEntry(apiKey: _storedSecret)},
    );
    writeConfig('search:\n  providers:\n    brave:\n      enabled: true\n      credential: brave-search\n');
    final config = DartclawConfig.load(configPath: configFile.path, env: env());
    expect(config.search.providers['brave']?.apiKey, _storedSecret, reason: 'the value did reach the config');

    final json = const ConfigSerializer().toJson(
      config,
      runtime: RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: false),
    );

    expect(json.containsKey('credentials'), isFalse);
    expect(json.toString(), isNot(contains(_storedSecret)));
  });
}
