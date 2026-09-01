import 'dart:io';

import 'package:dartclaw_cli/src/commands/service/service_backend.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _secret = 'STORED-SECRET-THAT-MUST-SURVIVE';

/// The workaround the store replaces was hand-editing a generated unit file,
/// which the next `dartclaw service install` overwrites. The guarantee is worth
/// pinning: the store lives under `data_dir`, and the generated definition
/// carries no secret to lose.
void main() {
  late Directory root;
  late String home;
  late String instanceDir;
  late String dataDir;
  late String credentialsDir;
  late File configFile;

  setUp(() {
    root = Directory.systemTemp.createTempSync('store_survives_install_');
    home = p.join(root.path, 'home');
    instanceDir = p.join(home, '.dartclaw');
    dataDir = p.join(instanceDir, 'data');
    credentialsDir = p.join(dataDir, 'credentials');
    Directory(instanceDir).createSync(recursive: true);
    configFile = File(p.join(instanceDir, 'dartclaw.yaml'))
      ..writeAsStringSync(
        'data_dir: $dataDir\n'
        'search:\n  providers:\n    brave:\n      enabled: true\n      credential: brave-search\n',
      );
  });

  tearDown(() {
    DartclawConfig.clearStoredCredentialProvider();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<ProcessResult> ok(String _, List<String> _) async => ProcessResult(0, 0, '', '');

  void seedStore() => NamedCredentialStore.open(
    credentialsDir: credentialsDir,
    environment: {'HOME': home},
  ).write('brave-search', const CredentialEntry(apiKey: _secret));

  DartclawConfig loadWithStore() {
    DartclawConfig.registerStoredCredentialProvider(
      (dir) => NamedCredentialStore.open(credentialsDir: dir, environment: {'HOME': home}).readAll(),
    );
    return DartclawConfig.load(configPath: configFile.path, env: {'HOME': home});
  }

  test('the store lives under data_dir, not beside the generated definition', () {
    seedStore();
    final stored = File(p.join(credentialsDir, 'named', 'brave-search.json'));
    expect(stored.existsSync(), isTrue);
    expect(p.isWithin(dataDir, stored.path), isTrue);
    expect(p.isWithin(p.join(home, 'Library'), stored.path), isFalse);
    expect(p.isWithin(p.join(home, '.config'), stored.path), isFalse);
  });

  test('a macOS reinstall regenerates a plist carrying no secret, and the credential still resolves', () async {
    seedStore();
    final backend = MacOSLaunchdBackend(run: ok, home: home, environment: {'HOME': home, 'PATH': '/usr/bin'});

    for (var install = 0; install < 2; install++) {
      final result = await backend.install(
        binPath: '/usr/local/bin/dartclaw',
        configPath: configFile.path,
        port: 3000,
        instanceDir: instanceDir,
        scope: ServiceScope.user,
      );
      expect(result.success, isTrue, reason: 'install $install succeeded');
    }

    final plist = Directory(p.join(home, 'Library', 'LaunchAgents')).listSync().whereType<File>().single;
    expect(plist.readAsStringSync(), isNot(contains(_secret)));
    expect(loadWithStore().search.providers['brave']?.apiKey, _secret);
  });

  test('a Linux reinstall regenerates a unit carrying no secret, and the credential still resolves', () async {
    seedStore();
    final backend = LinuxSystemdBackend(run: ok, home: home);

    for (var install = 0; install < 2; install++) {
      final result = await backend.install(
        binPath: '/usr/local/bin/dartclaw',
        configPath: configFile.path,
        port: 3000,
        instanceDir: instanceDir,
        scope: ServiceScope.user,
      );
      expect(result.success, isTrue, reason: 'install $install succeeded');
    }

    final unit = Directory(p.join(home, '.config', 'systemd', 'user')).listSync().whereType<File>().single;
    expect(unit.readAsStringSync(), isNot(contains(_secret)));
    expect(unit.readAsStringSync(), isNot(contains('Environment=')), reason: 'no secret-bearing environment line');
    expect(loadWithStore().search.providers['brave']?.apiKey, _secret);
  });
}
