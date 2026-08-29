import 'dart:async';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/config_loader.dart';
import 'package:dartclaw_cli/src/commands/reload_trigger_service.dart';
import 'package:dartclaw_cli/src/commands/secrets/secrets_command.dart';
import 'package:dartclaw_cli/src/runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../helpers/fake_exit.dart';
import '../../helpers/fake_secret_terminal.dart';

/// Records every delta a reload produced, so a test can prove a store write
/// fans out exactly once rather than looping.
class _RecordingService implements Reconfigurable {
  final List<ConfigDelta> deltas = <ConfigDelta>[];

  @override
  Set<String> get watchKeys => {'credentials.*'};

  @override
  void reconfigure(ConfigDelta delta) => deltas.add(delta);
}

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

  // `GuardEditorService` is not exported from `dartclaw_server`'s barrel and
  // this story leaves that package unmodified, so its reload site is pinned two
  // ways: its source shape here, and the behavior of the identical call below.
  test('the guard-editor reload site carries no credential snapshot of its own', () {
    final source = _serverSource('lib/src/api/guard_editor_service.dart');
    expect(
      source,
      contains('notifier.reload(DartclawConfig.load(configPath: writer.configPath))'),
      reason: 'a snapshot parameter added here would have to be threaded, and could be forgotten',
    );
    expect(source, isNot(contains('CredentialStore')), reason: 'the server opens no credential store');
  });

  test('a load with the guard editor\'s own argument shape picks up a mid-run secrets set', () async {
    openStore().write('brave-search', const CredentialEntry(apiKey: 'v1'));
    final notifier = ConfigNotifier(DartclawConfig.load(configPath: configFile.path));
    final service = _RecordingService();
    notifier.register(service);

    await secretsSet('brave-search', 'v2');
    notifier.reload(DartclawConfig.load(configPath: configFile.path));

    expect(notifier.current.credentials['brave-search']?.secret, 'v2');
    expect(
      service.deltas,
      hasLength(1),
      reason: 'a store write must fan out once — a delta feeding another reload would loop',
    );
    expect(service.deltas.single.hasChanged('credentials.*'), isTrue);
  });

  test('a reload-trigger reload picks up a mid-run secrets set, in exactly one notifier cycle', () async {
    openStore().write('brave-search', const CredentialEntry(apiKey: 'v1'));
    final notifier = ConfigNotifier(DartclawConfig.load(configPath: configFile.path));
    final service = _RecordingService();
    notifier.register(service);

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
    // `DartclawConfig.load(configPath:)` inside the service resolves the store.
    await _pollFor(() => service.deltas.isNotEmpty);

    expect(notifier.current.credentials['brave-search']?.secret, 'v2');
    expect(service.deltas, hasLength(1));
  });
}

/// A `dartclaw_server` source file, located by walking up from the test's CWD
/// so the scan works whichever directory the runner was launched from.
String _serverSource(String relative) {
  final path = p.join('packages', 'dartclaw_server', relative);
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
