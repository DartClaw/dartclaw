import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/auth/auth_codex_command.dart';
import 'package:dartclaw_cli/src/commands/auth/auth_command.dart';
import 'package:dartclaw_cli/src/runner.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../helpers/fake_exit.dart';

/// The vendor writes a ChatGPT access token whose expiry is an exact JWT claim.
String _jwt(DateTime exp) {
  String segment(Map<String, Object?> value) => base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${segment({'alg': 'RS256', 'typ': 'JWT'})}.'
      '${segment({'exp': exp.millisecondsSinceEpoch ~/ 1000, 'sub': 'chatgpt-account'})}.ZmFrZS1zaWduYXR1cmU';
}

String _authJson(DateTime exp) => jsonEncode({
  'tokens': {'access_token': _jwt(exp), 'refresh_token': 'vendor-owned', 'account_id': 'acct-1'},
  'last_refresh': DateTime.now().toUtc().toIso8601String(),
});

class _RecordedSpawn {
  final String executable;
  final List<String> arguments;
  final Map<String, String> environment;
  final bool includeParentEnvironment;
  final ProcessStartMode mode;

  const new(this.executable, this.arguments, this.environment, this.includeParentEnvironment, this.mode);
}

class _StubProcess implements Process {
  @override
  final Future<int> exitCode;

  new(int code) : exitCode = Future<int>.value(code);

  @override
  int get pid => 0;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => false;

  @override
  IOSink get stdin => throw UnsupportedError('inheritStdio');

  @override
  Stream<List<int>> get stderr => throw UnsupportedError('inheritStdio');

  @override
  Stream<List<int>> get stdout => throw UnsupportedError('inheritStdio');
}

void main() {
  late Directory root;
  late String home;
  late String operatorCodexHome;
  late String credentialsDir;
  late File configFile;
  late List<String> stdoutLines;
  late List<String> stderrLines;
  late List<_RecordedSpawn> spawns;

  setUp(() {
    root = Directory.systemTemp.createTempSync('auth_codex_command_');
    home = p.join(root.path, 'home');
    operatorCodexHome = p.join(root.path, 'operator-codex');
    Directory(home).createSync(recursive: true);
    credentialsDir = p.join(root.path, 'data', 'credentials');
    configFile = File(p.join(root.path, 'dartclaw.yaml'))
      ..writeAsStringSync('data_dir: ${p.join(root.path, 'data')}\n');
    stdoutLines = <String>[];
    stderrLines = <String>[];
    spawns = <_RecordedSpawn>[];
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Map<String, String> env([Map<String, String> extra = const {}]) => {
    'HOME': home,
    'CODEX_HOME': operatorCodexHome,
    'BROWSER': 'firefox',
    ...extra,
  };

  Future<int?> runAuth({
    ProcessStarter? startProcess,
    Map<String, String>? environment,
    List<String> extraArgs = const [],
  }) async {
    final runner = DartclawRunner()
      ..addCommand(
        AuthCommand(
          stdoutLine: stdoutLines.add,
          stderrLine: stderrLines.add,
          exitFn: fakeExit,
          environment: environment ?? env(),
          startProcess: startProcess,
        ),
      );
    try {
      await runner.run(['--config', configFile.path, 'auth', 'codex', ...extraArgs]);
      return null;
    } on FakeExit catch (failure) {
      return failure.code;
    }
  }

  /// A stub vendor CLI that writes the fixture store into whatever `CODEX_HOME`
  /// it was handed, exactly as `codex login` does.
  ProcessStarter stubVendor(DateTime exp, {int exitCode = 0}) =>
      (executable, arguments, {environment, includeParentEnvironment = true, mode = ProcessStartMode.normal}) async {
        spawns.add(_RecordedSpawn(executable, arguments, environment ?? {}, includeParentEnvironment, mode));
        final codexHome = environment?['CODEX_HOME'];
        if (exitCode == 0 && codexHome != null) {
          File(p.join(codexHome, 'auth.json')).writeAsStringSync(_authJson(exp));
        }
        return _StubProcess(exitCode);
      };

  test('the vendor login runs against the dedicated CODEX_HOME and its auth.json resolves', () async {
    final exp = DateTime.now().toUtc().add(const Duration(minutes: 55));
    final dedicatedHome = p.join(credentialsDir, 'codex');

    final code = await runAuth(startProcess: stubVendor(exp));

    expect(code, isNull);
    final spawn = spawns.single;
    expect(spawn.executable, 'codex');
    expect(spawn.arguments, ['login']);
    expect(spawn.mode, ProcessStartMode.inheritStdio, reason: 'the operator completes the flow on their terminal');
    expect(spawn.environment['CODEX_HOME'], dedicatedHome);
    expect(spawn.environment['CODEX_HOME'], isNot(operatorCodexHome));
    expect(spawn.environment['HOME'], home, reason: 'the interactive login needs the operator environment');
    expect(spawn.environment['BROWSER'], 'firefox');
    expect(
      spawn.includeParentEnvironment,
      isFalse,
      reason: 'the handed-over map is the whole environment, so an ambient CODEX_HOME cannot be re-added under it',
    );

    final credential = SubscriptionCredentialStore.open(
      credentialsDir: credentialsDir,
      environment: env(),
    ).read(ProviderIdentity.codex);
    expect(
      credential?.expiry?.expiresAt,
      DateTime.fromMillisecondsSinceEpoch(exp.millisecondsSinceEpoch ~/ 1000 * 1000, isUtc: true),
    );
    expect(credential?.expiry?.derived, isFalse, reason: 'the JWT exp is exact, never estimated');
    expect(stdoutLines.single, contains(dedicatedHome));
    expect(File(p.join(operatorCodexHome, 'auth.json')).existsSync(), isFalse);
    expect(Directory(p.join(home, '.codex')).existsSync(), isFalse);
  });

  /// A vendor that exits 0 having done whatever [onSpawn] does to the store.
  ProcessStarter vendorDoing(void Function(String codexHome) onSpawn) =>
      (executable, arguments, {environment, includeParentEnvironment = true, mode = ProcessStartMode.normal}) async {
        onSpawn(environment!['CODEX_HOME']!);
        return _StubProcess(0);
      };

  group('a vendor exit of 0 is not on its own reported as signed in', () {
    test('a store DartClaw cannot parse is blamed on the file, not on the vendor storing nothing', () async {
      final authPath = p.join(credentialsDir, 'codex', 'auth.json');

      final code = await runAuth(
        startProcess: vendorDoing((home) => File(p.join(home, 'auth.json')).writeAsStringSync('{"tokens":{}}')),
      );

      expect(code, 1, reason: 'an unusable store must surface here, not at the first turn');
      expect(
        stderrLines.single,
        allOf(contains(authPath), contains('cannot read a credential')),
        reason: 'sending the operator to re-run a login that did write would be the wrong fix',
      );
      expect(stdoutLines, isEmpty, reason: 'no success line may claim a sign-in that did not resolve');
    });

    test('a vendor that writes nothing at all is reported as storing nothing', () async {
      final code = await runAuth(startProcess: vendorDoing((_) {}));

      expect(code, 1);
      expect(stderrLines.single, allOf(contains(p.join(credentialsDir, 'codex')), contains('stored no credential')));
      expect(stdoutLines, isEmpty);
    });
  });

  test('a vendor that leaves an already-signed-in credential in place succeeds and says so', () async {
    // `codex login` returns without rewriting the store when the operator is
    // already signed in; the deployment is then exactly as it needs to be, so
    // reporting a failure would send them chasing a problem they do not have.
    final store = SubscriptionCredentialStore.open(credentialsDir: credentialsDir, environment: env());
    File(store.codexAuthPath).writeAsStringSync(_authJson(DateTime.now().toUtc().add(const Duration(minutes: 55))));

    final code = await runAuth(startProcess: vendorDoing((_) {}));

    expect(code, isNull, reason: 'a resolvable credential in the store this instance reads is the outcome wanted');
    expect(stderrLines, isEmpty);
    expect(stdoutLines.single, allOf(contains(store.codexHome), contains('already signed in')));
  });

  test('a vendor login that does not complete stores nothing and exits non-zero', () async {
    final code = await runAuth(startProcess: stubVendor(DateTime.now().toUtc(), exitCode: 1));

    expect(code, 1);
    expect(stderrLines.single, contains(p.join(credentialsDir, 'codex')));
    expect(File(p.join(credentialsDir, 'codex', 'auth.json')).existsSync(), isFalse);
  });

  group('the configured provider executable is the one that is run', () {
    setUp(() {
      configFile.writeAsStringSync(
        'data_dir: ${p.join(root.path, 'data')}\n'
        'providers:\n'
        '  codex:\n'
        '    executable: /opt/bin/codex\n',
      );
    });

    test('the vendor login spawns providers.codex.executable, not a bare `codex`', () async {
      final code = await runAuth(startProcess: stubVendor(DateTime.now().toUtc().add(const Duration(minutes: 55))));

      expect(code, isNull);
      expect(spawns.single.executable, '/opt/bin/codex');
    });

    test('the by-hand fallback names the same binary the command tried to run', () async {
      // An operator whose `codex` is not on PATH must be able to paste the
      // fallback; naming the wrong binary makes it fail exactly as the command did.
      final code = await runAuth(
        startProcess: (
          executable,
          arguments, {
          environment,
          includeParentEnvironment = true,
          mode = ProcessStartMode.normal,
        }) => throw ProcessException(executable, arguments, 'No such file or directory', 2),
      );

      expect(code, 1);
      expect(stderrLines.join('\n'), contains('CODEX_HOME="${p.join(credentialsDir, 'codex')}" /opt/bin/codex login'));
    });
  });

  test('with no codex on PATH the dedicated-home login stays reachable by hand', () async {
    final dedicatedHome = p.join(credentialsDir, 'codex');

    final code = await runAuth(
      startProcess: (
        executable,
        arguments, {
        environment,
        includeParentEnvironment = true,
        mode = ProcessStartMode.normal,
      }) => throw ProcessException(executable, arguments, 'No such file or directory', 2),
    );

    expect(code, 1);
    expect(
      stderrLines.join('\n'),
      contains('CODEX_HOME="$dedicatedHome" codex login'),
      reason: 'the fallback is pasted into a shell, so a data_dir containing a space must survive it',
    );
    expect(Directory(dedicatedHome).existsSync(), isTrue, reason: 'the store was opened before the vendor was spawned');
  });

  test('the manual fallback stays pastable when the data dir contains a space', () async {
    final spacedRoot = p.join(root.path, 'Application Support', 'dartclaw');
    configFile.writeAsStringSync('data_dir: $spacedRoot\n');

    final code = await runAuth(
      startProcess: (
        executable,
        arguments, {
        environment,
        includeParentEnvironment = true,
        mode = ProcessStartMode.normal,
      }) => throw ProcessException(executable, arguments, 'No such file or directory', 2),
    );

    expect(code, 1);
    expect(stderrLines.join('\n'), contains('CODEX_HOME="${p.join(spacedRoot, 'credentials', 'codex')}" codex login'));
  });

  test('a positional argument is refused rather than discarded, so a mistyped credential is flagged', () async {
    const stray = 'sk-ant-oat01-WRONG-SUBCOMMAND';

    final runner = DartclawRunner()
      ..addCommand(
        AuthCommand(
          stdoutLine: stdoutLines.add,
          stderrLine: stderrLines.add,
          exitFn: fakeExit,
          environment: env(),
          startProcess: stubVendor(DateTime.now().toUtc()),
        ),
      );
    int? code;
    try {
      await runner.run(['--config', configFile.path, 'auth', 'codex', stray]);
    } on FakeExit catch (failure) {
      code = failure.code;
    }

    expect(code, 1);
    expect(spawns, isEmpty, reason: 'refusal comes before the vendor is spawned');
    expect(stderrLines.single, allOf(contains('takes no arguments'), contains('shell history')));
    expect([...stdoutLines, ...stderrLines].join('\n'), isNot(contains(stray)));
  });

  test('--data-dir points the vendor login at the store the overridden instance reads', () async {
    // `serve --data-dir D` reads `D/credentials`; without the same override the
    // vendor writes into the YAML data_dir's store and the server sees nothing.
    final exp = DateTime.now().toUtc().add(const Duration(minutes: 55));
    final servedDataDir = p.join(root.path, 'served');

    final code = await runAuth(startProcess: stubVendor(exp), extraArgs: ['--data-dir', servedDataDir]);

    expect(code, isNull);
    expect(spawns.single.environment['CODEX_HOME'], p.join(servedDataDir, 'credentials', 'codex'));
    expect(
      SubscriptionCredentialStore.open(
        credentialsDir: p.join(servedDataDir, 'credentials'),
        environment: env(),
      ).read(ProviderIdentity.codex)?.secret,
      isNotEmpty,
    );
    expect(Directory(p.join(credentialsDir, 'codex')).existsSync(), isFalse);
  });

  test('the real spawn reaches a codex on PATH with the dedicated CODEX_HOME', () async {
    if (Platform.isWindows) return; // Shell-script stub and chmod are POSIX-only.
    final stubDir = Directory(p.join(root.path, 'bin'))..createSync(recursive: true);
    final recorded = p.join(root.path, 'recorded-codex-home');
    final fixture = p.join(root.path, 'fixture-auth.json');
    final exp = DateTime.now().toUtc().add(const Duration(minutes: 55));
    File(fixture).writeAsStringSync(_authJson(exp));
    final stub = File(
      p.join(stubDir.path, 'codex'),
    )..writeAsStringSync('#!/bin/sh\nprintf %s "\$CODEX_HOME" > "$recorded"\ncp "$fixture" "\$CODEX_HOME/auth.json"\n');
    Process.runSync('chmod', ['755', stub.path]);

    final code = await runAuth(environment: env({'PATH': '${stubDir.path}:/bin:/usr/bin'}));

    expect(code, isNull);
    expect(File(recorded).readAsStringSync(), p.join(credentialsDir, 'codex'));
    final credential = SubscriptionCredentialStore.open(
      credentialsDir: credentialsDir,
      environment: env(),
    ).read(ProviderIdentity.codex);
    expect(credential?.secret, isNotEmpty);
  });
}
