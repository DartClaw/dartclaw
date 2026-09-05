import 'dart:async';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/config_loader.dart';
import 'package:dartclaw_cli/src/commands/reload_trigger_service.dart';
import 'package:dartclaw_cli/src/commands/secrets/secrets_command.dart';
import 'package:dartclaw_cli/src/runner.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../helpers/fake_exit.dart';
import '../../helpers/fake_secret_terminal.dart';

void main() {
  late Directory root;
  late String home;
  late String dataDir;
  late String credentialsDir;
  late File configFile;

  setUp(() {
    root = Directory.systemTemp.createTempSync('stored_credential_reload_');
    home = p.join(root.path, 'home');
    Directory(home).createSync(recursive: true);
    dataDir = p.join(root.path, 'data');
    credentialsDir = p.join(dataDir, 'credentials');
    configFile = File(p.join(root.path, 'dartclaw.yaml'))..writeAsStringSync('data_dir: $dataDir\n');
    ensureStoredCredentialProviderRegistered(env: {'HOME': home});
  });

  tearDown(() {
    DartclawConfig.clearStoredCredentialProvider();
    DartclawConfig.clearExtensionParsers();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  NamedCredentialStore openStore() =>
      NamedCredentialStore.open(credentialsDir: credentialsDir, environment: {'HOME': home});

  /// Writes a new value through the real `dartclaw secrets set` path, as an
  /// operator would while the server is running.
  Future<void> secretsSet(String name, String value) async {
    final runner = DartclawRunner()
      ..addCommand(
        SecretsCommand(
          stdoutLine: (_) {},
          stderrLine: (_) {},
          exitFn: fakeExit,
          environment: {'HOME': home},
          terminal: FakeSecretTerminal.typing(value),
        ),
      );
    await runner.run(['--config', configFile.path, 'secrets', 'set', name, '--type', 'api-key']);
  }

  test('DR01 merged to declared to merged loads preserve each view without invoking the store for declared', () {
    configFile.writeAsStringSync(
      'data_dir: $dataDir\ncredentials:\n  sample:\n    type: api-key\n    api_key: declared\n',
    );
    var calls = 0;
    DartclawConfig.registerStoredCredentialProvider((_) {
      calls++;
      return {'sample': const CredentialEntry(apiKey: 'stored')};
    });
    expect(DartclawConfig.load(configPath: configFile.path).credentials['sample']?.secret, 'stored');
    expect(
      loadCliConfig(configPath: configFile.path, resolveStoredCredentials: false).credentials['sample']?.secret,
      'declared',
    );
    expect(calls, 1);
    expect(DartclawConfig.load(configPath: configFile.path).credentials['sample']?.secret, 'stored');
    expect(calls, 2);
  });

  test('DR02 a config load does not provision credential directories', () {
    loadCliConfig(configPath: configFile.path, env: {'HOME': home});
    expect(Directory(credentialsDir).existsSync(), isFalse);
  });

  test('the registered provider is re-invoked per load, not replayed from a startup snapshot', () async {
    openStore().write('brave-search', const CredentialEntry(apiKey: 'v1'));
    final startup = DartclawConfig.load(configPath: configFile.path);
    expect(startup.credentials['brave-search']?.secret, 'v1');

    await secretsSet('brave-search', 'v2');

    expect(
      DartclawConfig.load(configPath: configFile.path).credentials['brave-search']?.secret,
      'v2',
      reason: 'a snapshot cached at startup would still answer v1',
    );
  });

  // `GuardEditorService` is not exported from `dartclaw_runtime`'s barrel, so
  // its reload site is pinned two ways: its source shape here, and the behavior
  // of the identical call below.
  test('the guard-editor reload site carries no credential snapshot of its own', () {
    final source = _runtimeSource('lib/src/api/guard_editor_service.dart');
    expect(
      source,
      contains('notifier.reload(loadDartclawConfig(configPath: writer.configPath))'),
      reason: 'a snapshot parameter added here would have to be threaded, and could be forgotten',
    );
    expect(source, isNot(contains('CredentialStore')), reason: 'the server opens no credential store');
  });

  // `credentials` is a restart-tier section: a reload that sees a store write
  // records it in `restartRequiredSections` and delivers no delta, so the
  // running server applies the new value at its next restart rather than live.
  test('a load with the guard editor\'s own argument shape sees a mid-run secrets set', () async {
    openStore().write('brave-search', const CredentialEntry(apiKey: 'v1'));
    final notifier = ConfigNotifier(DartclawConfig.load(configPath: configFile.path));

    await secretsSet('brave-search', 'v2');
    final reloaded = DartclawConfig.load(configPath: configFile.path);

    expect(reloaded.credentials['brave-search']?.secret, 'v2');
    expect(notifier.reload(reloaded), isNull, reason: 'a restart-tier change is withheld from the delta');
    expect(notifier.restartRequiredSections, contains('credentials'));
  });

  test('a reload-trigger reload re-reads the store through the default loader', () async {
    openStore().write('brave-search', const CredentialEntry(apiKey: 'v1'));
    final notifier = ConfigNotifier(DartclawConfig.load(configPath: configFile.path));

    await secretsSet('brave-search', 'v2');

    final signals = StreamController<ProcessSignal>();
    addTearDown(signals.close);
    final trigger = ReloadTriggerService(
      configPath: configFile.path,
      notifier: notifier,
      reloadConfig: const ReloadConfig(mode: 'signal'),
      sigusr1Watch: () => signals.stream,
    )..start();
    addTearDown(trigger.dispose);

    signals.add(ProcessSignal.sigusr1);
    // The default loader is deliberately not replaced: this asserts the real
    // `loadCliConfig(configPath:)` inside the service resolves the store — the
    // section can only read as changed because the store was re-read.
    await _pollFor(() => notifier.restartRequiredSections.contains('credentials'));
  });
}

/// A `dartclaw_runtime` source file, located by walking up from the test's CWD
/// so the scan works whichever directory the runner was launched from.
String _runtimeSource(String relative) {
  final path = p.join('packages', 'dartclaw_runtime', relative);
  for (var current = Directory.current.absolute; ; current = current.parent) {
    final candidate = File(p.join(current.path, path));
    if (candidate.existsSync()) return candidate.readAsStringSync();
    if (current.path == current.parent.path) {
      throw StateError('Could not locate $path from ${Directory.current.path}');
    }
  }
}

/// Polls until [ready] with a generous cap — a fixed delay sized to a threshold
/// passes locally and fails under parallel load.
Future<void> _pollFor(bool Function() ready) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (ready()) return;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  fail('condition was never reached');
}
