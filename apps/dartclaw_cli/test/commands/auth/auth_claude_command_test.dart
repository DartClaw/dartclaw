import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/auth/auth_claude_command.dart';
import 'package:dartclaw_cli/src/commands/auth/auth_command.dart';
import 'package:dartclaw_cli/src/commands/auth/auth_subcommand.dart';
import 'package:dartclaw_cli/src/commands/token_command.dart';
import 'package:dartclaw_cli/src/runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show ProviderIdentity;
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../helpers/fake_exit.dart';
import '../../helpers/fake_secret_terminal.dart';

const _token = 'sk-ant-oat01-INGESTED-VALUE';

void main() {
  late Directory root;
  late String home;
  late String credentialsDir;
  late File configFile;
  late List<String> stdoutLines;
  late List<String> stderrLines;

  setUp(() {
    root = Directory.systemTemp.createTempSync('auth_claude_command_');
    home = p.join(root.path, 'home');
    Directory(home).createSync(recursive: true);
    credentialsDir = p.join(root.path, 'data', 'credentials');
    configFile = File(p.join(root.path, 'dartclaw.yaml'))
      ..writeAsStringSync('data_dir: ${p.join(root.path, 'data')}\n');
    stdoutLines = <String>[];
    stderrLines = <String>[];
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  String output() => [...stdoutLines, ...stderrLines].join('\n');

  /// Fails on any leak of [secret], including a prefix or a suffix: every
  /// 8-character window of the value must be absent from everything written.
  void expectNoTrace(String secret) {
    final captured = output();
    for (var start = 0; start + 8 <= secret.length; start++) {
      expect(
        captured,
        isNot(contains(secret.substring(start, start + 8))),
        reason: 'output leaks the substring at offset $start of the supplied value',
      );
    }
  }

  Map<String, String> env([Map<String, String> extra = const {}]) => {'HOME': home, ...extra};

  /// Runs the command, answering the exit code or `null` when it exited `0`.
  Future<int?> runAuth(
    List<String> args, {
    required FakeSecretTerminal terminal,
    Map<String, String>? environment,
  }) async {
    final runner = DartclawRunner()
      ..addCommand(
        AuthCommand(
          stdoutLine: stdoutLines.add,
          stderrLine: stderrLines.add,
          exitFn: fakeExit,
          environment: environment ?? env(),
          terminal: terminal,
        ),
      );
    try {
      await runner.run(['--config', configFile.path, ...args]);
      return null;
    } on FakeExit catch (failure) {
      return failure.code;
    }
  }

  SubscriptionCredentialStore openStore() =>
      SubscriptionCredentialStore.open(credentialsDir: credentialsDir, environment: env());

  void seedToken(String token, {required DateTime issuedAt}) =>
      openStore().storeClaudeSetupToken(token, issuedAt: issuedAt);

  test('a piped setup-token becomes a resolvable Claude subscription credential', () async {
    final before = DateTime.now().toUtc();

    final code = await runAuth([
      'auth',
      'claude',
    ], terminal: FakeSecretTerminal(hasTerminal: false, readLine: () => _token));

    expect(code, isNull, reason: 'ingestion succeeded');
    final credential = openStore().read(ProviderIdentity.claude);
    expect(credential?.secret, _token);
    expect(credential?.expiry?.expiresAt.difference(before).inDays, allOf(greaterThanOrEqualTo(364), lessThan(367)));
    expect(
      credential?.expiry?.derived,
      isTrue,
      reason: 'a setup-token carries no expiry claim, so its expiry is derived',
    );
    expect(stdoutLines.first, contains(p.join(credentialsDir, 'claude', 'setup-token.json')));
    expect(output(), contains(credential!.expiry!.expiresAt.toIso8601String().split('T').first));
    expectNoTrace(_token);
    expect(stderrLines, isEmpty);
    expect(
      stdoutLines,
      hasLength(2),
      reason: 'confirmation is the store path and the derived expiry — no third line to leak a length or a fragment',
    );
    expect(Directory(p.join(home, '.claude')).existsSync(), isFalse);
    expect(Directory(p.join(home, '.codex')).existsSync(), isFalse);
  });

  test('the printed renewal command names the instance that was written, not the default one', () async {
    // The renewal instruction is only true if it lands in the store named on
    // the line above it; a bare re-run would write to $HOME/.dartclaw instead.
    final code = await runAuth([
      'auth',
      'claude',
    ], terminal: FakeSecretTerminal(hasTerminal: false, readLine: () => _token));

    expect(code, isNull);
    expect(stdoutLines.last, contains('dartclaw --config "${configFile.path}" auth claude'));
  });

  group('--data-dir targets the store the running instance reads', () {
    // `credentialsDir` is derived from `server.data_dir`, and `serve` accepts a
    // `--data-dir` that overrides the YAML value. Without the same override
    // here, a documented `serve --config C --data-dir D` deployment has no way
    // to write into the store it reads.
    late String servedCredentialsDir;

    setUp(() {
      servedCredentialsDir = p.join(root.path, 'served', 'credentials');
    });

    test('the token lands in the overridden store, not the one the YAML names', () async {
      final code = await runAuth([
        'auth',
        'claude',
        '--data-dir',
        p.join(root.path, 'served'),
      ], terminal: FakeSecretTerminal(hasTerminal: false, readLine: () => _token));

      expect(code, isNull);
      expect(
        SubscriptionCredentialStore.open(
          credentialsDir: servedCredentialsDir,
          environment: env(),
        ).read(ProviderIdentity.claude)?.secret,
        _token,
      );
      expect(
        File(p.join(credentialsDir, 'claude', 'setup-token.json')).existsSync(),
        isFalse,
        reason: 'the YAML data_dir store must be left untouched when the override names another',
      );
      expectNoTrace(_token);
    });

    test('the printed renewal command carries the override, so pasting it back hits the same store', () async {
      final code = await runAuth([
        'auth',
        'claude',
        '--data-dir',
        p.join(root.path, 'served'),
      ], terminal: FakeSecretTerminal(hasTerminal: false, readLine: () => _token));

      expect(code, isNull);
      expect(stdoutLines.first, contains(p.join(servedCredentialsDir, 'claude', 'setup-token.json')));
      expect(stdoutLines.last, contains('auth claude --data-dir "${p.join(root.path, 'served')}"'));
    });
  });

  test('an interactively pasted token is prompted for, shown only as a mask, and never printed back', () async {
    final terminal = FakeSecretTerminal.typing(_token);

    final code = await runAuth(['auth', 'claude'], terminal: terminal);

    expect(code, isNull);
    expect(terminal.enterCount, 1, reason: 'the command must drive the masked read, not a plain one');
    expect(terminal.output, '${'*' * _token.length}\n', reason: 'the terminal shows progress, never the value');
    expect(terminal.restoresAfterByteReads, [
      terminal.byteReadCount,
    ], reason: 'the operator gets their terminal back, once, after the last byte');
    expect(stdoutLines.first, contains('Paste the token'), reason: 'an interactive operator gets a prompt');
    expect(openStore().read(ProviderIdentity.claude)?.secret, _token);
    expectNoTrace(_token);
  });

  test('an interrupted prompt exits 130, stores nothing, and says nothing about a missing token', () async {
    final terminal = FakeSecretTerminal(hasTerminal: true, input: [...utf8.encode('sk-ant-oat01-PART'), 3]);

    final code = await runAuth(['auth', 'claude'], terminal: terminal);

    expect(code, 130, reason: '128 + SIGINT, the shell convention for an interrupted command');
    expect(terminal.restoresAfterByteReads, hasLength(1), reason: 'Ctrl-C must not leave the terminal in hidden mode');
    expect(terminal.hidden, isFalse);
    expect(File(p.join(credentialsDir, 'claude', 'setup-token.json')).existsSync(), isFalse);
    expect(
      stderrLines,
      isEmpty,
      reason: 'the interrupt is its own outcome — a "no token was supplied" line would read as a rejected value',
    );
  });

  test('re-ingesting a re-issued token replaces the stored one with no confirmation gate', () async {
    seedToken('sk-ant-oat01-EXPIRING-SOON', issuedAt: DateTime.now().toUtc().subtract(const Duration(days: 364)));
    final before = DateTime.now().toUtc();

    final code = await runAuth([
      'auth',
      'claude',
    ], terminal: FakeSecretTerminal(hasTerminal: false, readLine: () => _token));

    expect(code, isNull, reason: 'the documented annual renewal path must succeed on the first attempt');
    final credential = openStore().read(ProviderIdentity.claude);
    expect(credential?.secret, _token);
    expect(credential?.expiry?.expiresAt.isAfter(before.add(const Duration(days: 360))), isTrue);
    final tokenFile = File(p.join(credentialsDir, 'claude', 'setup-token.json'));
    expect(tokenFile.readAsStringSync(), isNot(contains('EXPIRING-SOON')));
    if (!Platform.isWindows) {
      expect((tokenFile.statSync().mode & 0x1ff).toRadixString(8), '600');
    }
  });

  group('input that is not a single token is refused and nothing is written', () {
    // Each case pairs the supplied input with the word its refusal must name,
    // so a generic "invalid input" message cannot satisfy the assertion.
    const cases = {
      'empty input': ('', 'No token was supplied'),
      'whitespace-only input': ('   ', 'No token was supplied'),
      'an embedded space': ('sk-ant-oat01 TRAILING', 'whitespace'),
      'an embedded tab': ('sk-ant-oat01\tTRAILING', 'whitespace'),
    };

    for (final entry in cases.entries) {
      final (input, expectedReason) = entry.value;

      test('${entry.key} leaves a fresh store untouched', () async {
        final terminal = FakeSecretTerminal(hasTerminal: false, readLine: () => input);

        final code = await runAuth(['auth', 'claude'], terminal: terminal);

        expect(code, 1);
        expect(stderrLines.single, contains(expectedReason), reason: 'the refusal names what was wrong');
        expect(File(p.join(credentialsDir, 'claude', 'setup-token.json')).existsSync(), isFalse);
        expectNoTrace(input.trim());
      });

      test('${entry.key} leaves an already-stored token byte-identical', () async {
        seedToken('sk-ant-oat01-ALREADY-STORED', issuedAt: DateTime.now().toUtc());
        final tokenFile = File(p.join(credentialsDir, 'claude', 'setup-token.json'));
        final before = tokenFile.readAsBytesSync();

        final code = await runAuth([
          'auth',
          'claude',
        ], terminal: FakeSecretTerminal(hasTerminal: false, readLine: () => input));

        expect(code, 1);
        expect(tokenFile.readAsBytesSync(), before);
      });
    }
  });

  group('an unusable store refuses before the token is read', () {
    test('a dedicated store resolving onto the operator login store names both paths', () async {
      final terminal = FakeSecretTerminal(hasTerminal: false, readLine: () => _token);
      final loginStore = p.join(credentialsDir, 'claude');

      final code = await runAuth(
        ['auth', 'claude'],
        terminal: terminal,
        environment: env({'CLAUDE_CONFIG_DIR': loginStore}),
      );

      expect(code, 1);
      expect(stderrLines.single, allOf(startsWith('Dedicated claude credential store'), contains(loginStore)));
      expect(terminal.readCount, 0, reason: 'the operator must still hold the token when the store refuses');
      expect(Directory(loginStore).existsSync(), isFalse, reason: 'nothing may be created under the login store');
    });

    test('a credentials directory that cannot be created refuses with a message, not a stack trace', () async {
      File(credentialsDir)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('not a directory');
      final terminal = FakeSecretTerminal(hasTerminal: false, readLine: () => _token);

      final code = await runAuth(['auth', 'claude'], terminal: terminal);

      expect(code, 1);
      expect(
        stderrLines.single,
        allOf(startsWith('Cannot open the dedicated credential store'), contains(credentialsDir)),
      );
      expect(terminal.readCount, 0);
    });

    test('a store the token cannot be written into refuses with a message, not a stack trace', () async {
      // The directories open() creates are real; the token record's own path is
      // occupied by a directory, so only the write can fail.
      Directory(p.join(credentialsDir, 'claude', 'setup-token.json')).createSync(recursive: true);
      final terminal = FakeSecretTerminal(hasTerminal: false, readLine: () => _token);

      final code = await runAuth(['auth', 'claude'], terminal: terminal);

      expect(code, 1);
      expect(terminal.readCount, 1, reason: 'this failure is only reachable after the token has been read');
      expect(stderrLines.single, allOf(contains('Could not write'), contains('Nothing was stored')));
      expectNoTrace(_token);
    });

    test('an unrecognized failure is named by type, never by stringifying an error that embeds the value', () {
      // `ArgumentError.value(...).toString()` embeds the rejected value, and the
      // write-failure printer runs with the token in scope, so the fallback arm
      // must never stringify what it caught.
      final rendered = AuthSubcommand.reasonFor(ArgumentError.value(_token, 'token', 'must not be blank'));

      expect(rendered, isNot(contains(_token)));
      expect(rendered, contains('ArgumentError'), reason: 'a field report still needs to identify what was thrown');
    });
  });

  group('the token can never become a process argument', () {
    test('the only option the subcommand declares selects the store, never the credential', () {
      // An option value lands in shell history and in `ps`, so the surface is
      // pinned to an exact allowlist: `--data-dir` names the store `serve` reads
      // and carries no secret. Any new value option is a regression until it is
      // proven to be non-credential-bearing and added here deliberately.
      final valueOptions = AuthClaudeCommand().argParser.options.values.where((option) => !option.isFlag);

      expect(valueOptions.map((option) => option.name), ['data-dir']);
      expect(AuthClaudeCommand().argParser.commands, isEmpty);
    });

    test('a value supplied as a positional is refused as already exposed, not quietly ingested', () async {
      const positional = 'sk-ant-oat01-FROM-ARGV';
      final terminal = FakeSecretTerminal(hasTerminal: false, readLine: () => positional);

      final code = await runAuth(['auth', 'claude', positional], terminal: terminal);

      expect(code, 1);
      expect(
        stderrLines.single,
        allOf(contains('takes no arguments'), contains('shell history')),
        reason: 'the operator must learn the value they typed is exposed, not that it was silently dropped',
      );
      expect(terminal.readCount, 0, reason: 'nothing is read, so the argv value cannot reach the store either way');
      expect(File(p.join(credentialsDir, 'claude', 'setup-token.json')).existsSync(), isFalse);
      expectNoTrace(positional);
    });
  });

  test('the gateway token command keeps its separate meaning and surface', () {
    final token = TokenCommand();

    expect(token.description, 'Manage gateway authentication token');
    expect(token.subcommands.keys, unorderedEquals(['show', 'rotate']));
  });
}
