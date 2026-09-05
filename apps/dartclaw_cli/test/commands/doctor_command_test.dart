import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/doctor_command.dart';
import 'package:dartclaw_cli/src/commands/init/setup_checks.dart';
import 'package:dartclaw_cli/src/runner.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show dartclawVersion;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../helpers/fake_exit.dart';

void main() {
  late Directory root;
  late String dataDir;
  late File config;
  late Map<String, String> environment;
  late List<String> lines;

  setUp(() {
    root = Directory.systemTemp.createTempSync('doctor_command_');
    dataDir = p.join(root.path, 'data');
    environment = {'HOME': p.join(root.path, 'home'), 'PATH': ''};
    config = File(p.join(root.path, 'dartclaw.yaml'));
    lines = [];
  });
  tearDown(() {
    DartclawConfig.clearStoredCredentialProvider();
    root.deleteSync(recursive: true);
  });

  void writeConfig([String extra = '']) {
    config.writeAsStringSync('data_dir: $dataDir\nproviders:\n  claude:\n    executable: unavailable-claude\n$extra');
    if (!Platform.isWindows) Process.runSync('chmod', ['600', config.path]);
  }

  void layout() {
    for (final name in ['workspace', 'sessions', 'logs']) {
      Directory(p.join(dataDir, name)).createSync(recursive: true);
    }
  }

  Future<int> run(List<String> args, {bool realCredentials = false}) async {
    final runner = DartclawRunner()
      ..addCommand(
        DoctorCommand(
          setupChecks: SetupChecks(
            probeBinary: (_) async => (outcome: BinaryProbeOutcome.responded, version: '2.1.80'),
            portFree: (_) async => true,
            providerVerified: realCredentials ? null : (_, _, _) async => true,
            runCommand: (_, _) async => ProcessResult(0, 1, '', ''),
          ),
          writeLine: lines.add,
          exitFn: fakeExit,
          environment: environment,
          platformCapabilities: PlatformCapabilities(operatingSystem: 'linux', environment: environment),
        ),
      );
    try {
      await runner.run(['--config', config.path, 'doctor', ...args]);
      return 0;
    } on FakeExit catch (error) {
      return error.code;
    }
  }

  Map<String, dynamic> json() => jsonDecode(lines.single) as Map<String, dynamic>;

  test('S01 healthy stopped instance passes using its stored subscription without exposing it', () async {
    writeConfig();
    layout();
    SubscriptionCredentialStore.open(
      credentialsDir: p.join(dataDir, 'credentials'),
      environment: environment,
    ).storeClaudeSetupToken('sk-ant-oat01-DOCTOR-SECRET');
    expect(await run([], realCredentials: true), 0);
    expect(lines.where((line) => line.startsWith('[warn]')).single, contains('container.runtime'));
    expect(lines.any((line) => line.startsWith('[fail]')), isFalse);
    expect(
      lines.join('\n'),
      allOf(
        contains(config.path),
        contains('advisory mode'),
        contains('docs/guide/security.md'),
        isNot(contains('sk-ant-oat01')),
        isNot(contains('DOCTOR-SECRET')),
      ),
    );
    expect(lines.last, matches(r'\d+ pass, 1 warn, 0 fail, 0 skip'));
  });

  test('S08 repairs only missing layout directories while config failure and YAML bytes remain', () async {
    writeConfig('    auth: nonsense\n');
    Directory(p.join(dataDir, 'workspace')).createSync(recursive: true);
    final bytes = config.readAsBytesSync();
    expect(await run([]), 1);
    expect(lines.join('\n'), contains('dartclaw doctor --fix'));
    expect(Directory(p.join(dataDir, 'sessions')).existsSync(), isFalse);
    lines.clear();
    expect(await run(['--fix', '--json']), 1);
    final report = json();
    final rows = (report['checks'] as List).cast<Map<String, dynamic>>();
    expect(rows.singleWhere((r) => r['id'] == 'data_dir.layout')['fixed'], isTrue);
    expect(rows.where((r) => r['id'] == 'config.valid').any((r) => r['status'] == 'fail'), isTrue);
    expect(
      Directory(dataDir).listSync().map((entry) => p.basename(entry.path)),
      unorderedEquals(['workspace', 'sessions', 'logs']),
    );
    expect(config.readAsBytesSync(), bytes);
  });

  test('S09 human and JSON forms carry identical row ids and statuses with the same exit code', () async {
    writeConfig('credentials:\n  brave:\n    type: api-key\n    api_key: DOCTOR-LITERAL-SECRET\n');
    layout();
    expect(await run([]), 1);
    final human = [
      for (final line in lines)
        if (line.startsWith('[')) line.split(' ').take(2).join(' '),
    ];
    lines.clear();
    expect(await run(['--json']), 1);
    final report = json();
    expect(report.keys, unorderedEquals(['version', 'config_path', 'server', 'checks', 'summary']));
    expect(report['version'], dartclawVersion);
    expect(report['config_path'], config.path);
    expect(report['server'], isNull);
    final rows = (report['checks'] as List).cast<Map<String, dynamic>>();
    expect(rows.map((r) => '[${r['status']}] ${r['id']}'), human);
    expect(lines.single, isNot(contains('DOCTOR-LITERAL-SECRET')));
    expect((report['summary'] as Map).keys, unorderedEquals(['pass', 'warn', 'fail', 'skip']));
  });

  test('DR05 malformed credential types cannot expose aliased secrets in either renderer', () async {
    const secret = 'sk-ant-DOCTOR-ALIASED-SECRET';
    writeConfig('credentials:\n  anthropic:\n    api_key: &secret $secret\n    type: *secret\n');
    layout();
    for (final args in [
      <String>[],
      ['--json'],
    ]) {
      lines.clear();
      expect(await run(args), 1);
      expect(lines.join('\n'), allOf(isNot(contains(secret)), isNot(contains('sk-ant-'))));
      expect(lines.join('\n'), contains('credentials.anthropic'));
    }
  });

  test('DR01 shadowed entries survive the fix rerun and only layout directories are created', () async {
    writeConfig('credentials:\n  anthropic:\n    type: api-key\n    api_key: YAML-SECRET\n');
    final credentialsDir = p.join(dataDir, 'credentials');
    NamedCredentialStore.open(
      credentialsDir: credentialsDir,
      environment: environment,
    ).write('anthropic', const CredentialEntry(apiKey: 'STORED-SECRET'));
    expect(await run(['--fix', '--json'], realCredentials: true), 1);
    final rows = (json()['checks'] as List).cast<Map<String, dynamic>>();
    expect(rows.singleWhere((r) => r['id'] == 'secrets.shadowed')['status'], 'fail');
    expect(rows.singleWhere((r) => r['id'] == 'data_dir.layout')['fixed'], isTrue);
    expect(
      Directory(dataDir).listSync().map((e) => p.basename(e.path)),
      unorderedEquals(['credentials', 'workspace', 'sessions', 'logs']),
    );
    expect(Directory(credentialsDir).listSync().map((e) => p.basename(e.path)), ['named']);
    expect(lines.single, allOf(isNot(contains('YAML-SECRET')), isNot(contains('STORED-SECRET'))));
  });

  test('DR02 verification preserves missing stores and existing modes', () async {
    writeConfig();
    layout();
    expect(await run(['--json'], realCredentials: true), 1);
    final credentials = Directory(p.join(dataDir, 'credentials'));
    expect(credentials.existsSync(), isFalse);
    credentials.createSync();
    if (!Platform.isWindows) Process.runSync('chmod', ['755', credentials.path]);
    final before = credentials.statSync().mode;
    lines.clear();
    expect(await run(['--json'], realCredentials: true), 1);
    expect(credentials.statSync().mode, before);
    expect(credentials.listSync(), isEmpty);
  });

  test('DR04 a path collision cannot be reported as fixed', () async {
    writeConfig();
    Directory(dataDir).createSync();
    File(p.join(dataDir, 'sessions')).writeAsStringSync('keep');
    expect(await run(['--fix', '--json']), 1);
    final rows = (json()['checks'] as List).cast<Map<String, dynamic>>();
    final row = rows.singleWhere((r) => r['id'] == 'data_dir.layout');
    expect(row['status'], 'fail');
    expect(row.containsKey('fixed'), isFalse);
    expect(File(p.join(dataDir, 'sessions')).readAsStringSync(), 'keep');
  });

  test('S04 --fix never writes when the loader rejected the config', () async {
    writeConfig('unknown_field: true\n');
    final before = config.readAsBytesSync();
    expect(await run(['--fix', '--json']), 1);
    expect(Directory(dataDir).existsSync(), isFalse);
    expect(config.readAsBytesSync(), before);
  });
}
