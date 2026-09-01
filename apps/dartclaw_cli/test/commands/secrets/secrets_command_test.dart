import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/config_loader.dart';
import 'package:dartclaw_cli/src/commands/secrets/secrets_command.dart';
import 'package:dartclaw_cli/src/runner.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../helpers/fake_exit.dart';
import '../../helpers/fake_secret_terminal.dart';

const _secret = 'BSA-STORED-SECRET-VALUE';

void main() {
  late Directory root;
  late String home;
  late String dataDir;
  late String credentialsDir;
  late File configFile;
  late List<String> stdoutLines;
  late List<String> stderrLines;

  setUp(() {
    root = Directory.systemTemp.createTempSync('secrets_command_');
    home = p.join(root.path, 'home');
    Directory(home).createSync(recursive: true);
    dataDir = p.join(root.path, 'data');
    credentialsDir = p.join(dataDir, 'credentials');
    configFile = File(p.join(root.path, 'dartclaw.yaml'))..writeAsStringSync('data_dir: $dataDir\n');
    stdoutLines = <String>[];
    stderrLines = <String>[];
  });

  tearDown(() {
    DartclawConfig.clearStoredCredentialProvider();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Map<String, String> env() => {'HOME': home};

  String output() => [...stdoutLines, ...stderrLines].join('\n');

  /// Fails on any leak of [secret], including a prefix or a suffix.
  void expectNoTrace(String secret) {
    final captured = output();
    for (var start = 0; start + 6 <= secret.length; start++) {
      expect(
        captured,
        isNot(contains(secret.substring(start, start + 6))),
        reason: 'output leaks the substring at offset $start of the stored value',
      );
    }
  }

  Future<int?> runSecrets(List<String> args, {FakeSecretTerminal? terminal}) async {
    final runner = DartclawRunner()
      ..addCommand(
        SecretsCommand(
          stdoutLine: stdoutLines.add,
          stderrLine: stderrLines.add,
          exitFn: fakeExit,
          environment: env(),
          terminal: terminal ?? FakeSecretTerminal(hasTerminal: false, readLine: () => null),
        ),
      );
    try {
      await runner.run(['--config', configFile.path, ...args]);
      return null;
    } on FakeExit catch (failure) {
      return failure.code;
    }
  }

  NamedCredentialStore openStore() => NamedCredentialStore.open(credentialsDir: credentialsDir, environment: env());

  /// Names in the store, without creating it — a refusal path must leave no
  /// directory behind either.
  Iterable<String> storedNames() {
    final named = Directory(p.join(credentialsDir, 'named'));
    return named.existsSync() ? named.listSync().map((entity) => p.basename(entity.path)) : const [];
  }

  void writeConfig(String yaml) => configFile.writeAsStringSync('data_dir: $dataDir\n$yaml');

  group('secrets set', () {
    test('a masked terminal read stores an owner-only api-key entry', () async {
      final code = await runSecrets([
        'secrets',
        'set',
        'brave-search',
        '--type',
        'api-key',
      ], terminal: FakeSecretTerminal.typing(_secret));

      expect(code, isNull);
      final file = File(p.join(credentialsDir, 'named', 'brave-search.json'));
      expect(file.existsSync(), isTrue);
      expect(jsonDecode(file.readAsStringSync()), {'type': 'api-key', 'secret': _secret});
      if (!Platform.isWindows) {
        expect(file.statSync().mode & 0x1ff, 0x180);
        expect(Directory(p.dirname(file.path)).statSync().mode & 0x1ff, 0x1c0);
      }
      expect(stdoutLines.join('\n'), contains(file.path));
      expectNoTrace(_secret);
    });

    test('a stored entry resolves through a config load with no credentials block', () async {
      await runSecrets([
        'secrets',
        'set',
        'brave-search',
        '--type',
        'api-key',
      ], terminal: FakeSecretTerminal.typing(_secret));

      expect(configFile.readAsStringSync(), isNot(contains('credentials')));
      ensureStoredCredentialProviderRegistered(env: env());
      final config = DartclawConfig.load(configPath: configFile.path, env: env());
      expect(
        config.credentials['brave-search']?.secret,
        _secret,
        reason: 'the CLI bootstrap registered the store as a credential source for every load',
      );
    });

    test('a piped value is stored with its trailing newline stripped, echoing nothing', () async {
      final terminal = FakeSecretTerminal(hasTerminal: false, readLine: () => _secret);

      final code = await runSecrets(['secrets', 'set', 'brave-search', '--type', 'api-key'], terminal: terminal);

      expect(code, isNull);
      expect(openStore().read('brave-search')?.secret, _secret);
      expect(terminal.output, isEmpty, reason: 'a piped read prompts nothing and echoes nothing');
      expect(terminal.enterCount, 0, reason: 'no terminal mode is touched on piped input');
    });

    test('a github-token entry carries its repository', () async {
      final code = await runSecrets([
        'secrets',
        'set',
        'github-main',
        '--type',
        'github-token',
        '--repository',
        'org/app',
      ], terminal: FakeSecretTerminal.typing('ghp_value'));

      expect(code, isNull);
      final entry = openStore().read('github-main');
      expect(entry?.type, CredentialType.githubToken);
      expect(entry?.repository, 'org/app');
    });

    test('--repository is refused for an api-key entry', () async {
      final code = await runSecrets([
        'secrets',
        'set',
        'brave-search',
        '--type',
        'api-key',
        '--repository',
        'org/app',
      ], terminal: FakeSecretTerminal.typing(_secret));

      expect(code, 1);
      expect(stderrLines.join('\n'), contains('--repository'));
      expect(storedNames(), isEmpty);
    });

    test('--type is required, refused with a message rather than a thrown option read', () async {
      final code = await runSecrets(['secrets', 'set', 'brave-search']);
      expect(code, 1);
      expect(stderrLines.join('\n'), contains('--type'));
    });

    test('an empty value is refused and nothing is stored', () async {
      final code = await runSecrets([
        'secrets',
        'set',
        'brave-search',
        '--type',
        'api-key',
      ], terminal: FakeSecretTerminal.typing('   '));

      expect(code, 1);
      expect(storedNames(), isEmpty);
    });

    test('a name is required', () async {
      final code = await runSecrets(['secrets', 'set']);
      expect(code, 1);
      expect(stderrLines.join('\n'), contains('name'));
    });
  });

  group('secrets set refuses a name that is not a plain identifier', () {
    for (final name in ['../../../etc/evil', 'a/b', 'UPPER', '-leading']) {
      test('"$name" is refused before any path is built', () async {
        final escapeRoot = Directory(p.join(root.path, 'escape'))..createSync(recursive: true);

        final code = await runSecrets([
          'secrets',
          'set',
          '--type',
          'api-key',
          // `--` so a dash-leading name reaches the validator instead of being
          // parsed as an option — the same way an operator would have to type it.
          '--',
          name,
        ], terminal: FakeSecretTerminal.typing(_secret));

        expect(code, 1);
        expect(stderrLines.join('\n'), contains('[a-z0-9]'), reason: 'the refusal names the required pattern');
        // Asserted outside <data_dir> as well: a traversal that escaped would
        // land here, and an inside-only check would not see it.
        expect(escapeRoot.listSync(), isEmpty);
        expect(root.listSync().map((entity) => p.basename(entity.path)), isNot(contains('etc')));
        expect(storedNames(), isEmpty);
      });
    }
  });

  group('the value never reaches argv', () {
    test('no option on `secrets set` can carry a secret value', () {
      final command = SecretsCommand(environment: env());
      final set = command.subcommands['set']!;

      expect(
        set.argParser.options.keys,
        unorderedEquals(['help', 'data-dir', 'type', 'repository']),
        reason: 'argv is world-readable through `ps` and lands in shell history (D9)',
      );
    });

    test('a positional beyond <name> is an error', () async {
      final code = await runSecrets([
        'secrets',
        'set',
        'brave-search',
        'the-secret-typed-here',
        '--type',
        'api-key',
      ], terminal: FakeSecretTerminal.typing(_secret));

      expect(code, 1);
      expect(stderrLines.join('\n'), contains('shell history'));
      expect(storedNames(), isEmpty);
    });
  });

  group('secrets rm', () {
    test('removes only the stored half of a shadowed name', () async {
      writeConfig('credentials:\n  github-main:\n    type: github-token\n    token: from-yaml\n');
      openStore().write('github-main', const CredentialEntry.githubToken(token: 'from-store'));

      final code = await runSecrets(['secrets', 'rm', 'github-main']);

      expect(code, isNull);
      expect(File(p.join(credentialsDir, 'named', 'github-main.json')).existsSync(), isFalse);
      expect(
        output(),
        contains('config'),
        reason: 'the operator must learn a config-declared entry of the same name survives',
      );
      final config = DartclawConfig.load(configPath: configFile.path, env: env());
      expect(config.credentials['github-main']?.secret, 'from-yaml');
    });

    test('removing an unstored name reports it and exits non-zero', () async {
      final code = await runSecrets(['secrets', 'rm', 'absent']);
      expect(code, 1);
      expect(stderrLines.join('\n'), contains('absent'));
    });

    test('an invalid name is refused rather than joined into a path', () async {
      final code = await runSecrets(['secrets', 'rm', '../../etc/evil']);
      expect(code, 1);
      expect(stderrLines.join('\n'), contains('[a-z0-9]'));
    });
  });

  group('secrets list', () {
    test('reports provenance across store, config and env, marking the shadowed name', () async {
      writeConfig(
        'credentials:\n'
        '  github-main:\n    type: github-token\n    token: from-yaml\n'
        '  literal-key:\n    api_key: LITERAL-SECRET-VALUE\n'
        '  env-key:\n    api_key: \${SOME_VAR}\n',
      );
      openStore()
        ..write('github-main', const CredentialEntry.githubToken(token: 'from-store'))
        ..write('brave-search', const CredentialEntry(apiKey: _secret));

      final code = await runSecrets(['secrets', 'list']);

      expect(code, isNull);
      final rendered = stdoutLines.join('\n');
      expect(rendered, contains('brave-search'));
      expect(rendered, contains('api-key'));
      expect(rendered, contains('store'));
      expect(rendered, contains('literal-key'));
      expect(rendered, contains('config'));
      expect(rendered, contains('env-key'));
      expect(rendered, contains('env'));
      expect(rendered, contains('SOME_VAR'));
      expect(
        rendered.split('\n').firstWhere((line) => line.contains('github-main')),
        contains('shadow'),
        reason: 'a name present in both the store and config must be reported as shadowed',
      );
      expectNoTrace(_secret);
      expect(rendered, isNot(contains('LITERAL-SECRET-VALUE')));
      expect(rendered, isNot(contains('from-yaml')));
      expect(rendered, isNot(contains('from-store')));
    });

    test('an empty instance lists nothing and says so', () async {
      final code = await runSecrets(['secrets', 'list']);
      expect(code, isNull);
      expect(stdoutLines.join('\n'), contains('No credentials'));
    });
  });
}
