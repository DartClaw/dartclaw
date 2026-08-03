import 'dart:io';

import 'package:dartclaw_cli/src/commands/service/service_backend.dart';
import 'package:test/test.dart';

class _FakeRunner {
  final Map<String, ProcessResult> _responses;
  final List<(String, List<String>)> calls = [];

  _FakeRunner(this._responses);

  Future<ProcessResult> call(String exe, List<String> args) async {
    calls.add((exe, args));
    return _responses[exe] ?? ProcessResult(0, 0, '', '');
  }
}

ProcessResult _ok([String stdout = '']) => ProcessResult(0, 0, stdout, '');

void main() {
  late Directory tempDir;
  late String home;
  late String instanceDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('service_backend_test_');
    home = tempDir.path;
    instanceDir = '$home/.dartclaw';
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('MacOSLaunchAgentBackend', () {
    test('install writes an instance-scoped plist and start uses the same instance', () async {
      final runner = _FakeRunner({'id': _ok('501'), 'launchctl': _ok()});
      final backend = MacOSLaunchAgentBackend(
        run: runner.call,
        home: home,
        environment: {'PATH': '/opt/homebrew/bin::relative:/Users/test/a&b'},
      );

      final install = await backend.install(
        binPath: '/usr/local/bin/dartclaw',
        configPath: '$instanceDir/dartclaw.yaml',
        port: 3333,
        instanceDir: instanceDir,
        sourceDir: '/src/dartclaw',
      );
      final start = await backend.start(instanceDir: instanceDir);

      expect(install.success, isTrue);
      expect(start.success, isTrue);
      final plist = Directory('$home/Library/LaunchAgents').listSync().whereType<File>().single;
      expect(plist.path, contains('com.dartclaw.agent.'));
      final content = plist.readAsStringSync();
      expect(content, contains('<key>EnvironmentVariables</key>'));
      expect(content, contains('<key>PATH</key>'));
      expect(content, contains('<string>/opt/homebrew/bin:/Users/test/a&amp;b</string>'));
      expect(content, isNot(contains('relative')));
    });

    test('reinstall refreshes the loaded definition', () async {
      final runner = _FakeRunner({'id': _ok('501'), 'launchctl': _ok()});
      final backend = MacOSLaunchAgentBackend(run: runner.call, home: home, environment: {'PATH': '/opt/homebrew/bin'});

      for (var i = 0; i < 2; i++) {
        expect(
          (await backend.install(
            binPath: '/usr/local/bin/dartclaw',
            configPath: '$instanceDir/dartclaw.yaml',
            port: 3333,
            instanceDir: instanceDir,
          )).success,
          isTrue,
        );
      }

      final launchctlCalls = runner.calls.where((call) => call.$1 == 'launchctl').map((call) => call.$2.first).toList();
      expect(launchctlCalls, ['bootstrap', 'bootout', 'bootstrap']);
    });

    test('install falls back to the system PATH when no absolute entries exist', () async {
      final runner = _FakeRunner({'id': _ok('501'), 'launchctl': _ok()});
      final backend = MacOSLaunchAgentBackend(
        run: runner.call,
        home: home,
        environment: {'PATH': 'relative::.', 'DARTCLAW_SECRET': 'must-not-be-written'},
      );

      await backend.install(
        binPath: '/usr/local/bin/dartclaw',
        configPath: '$instanceDir/dartclaw.yaml',
        port: 3333,
        instanceDir: instanceDir,
      );

      final content = Directory('$home/Library/LaunchAgents').listSync().whereType<File>().single.readAsStringSync();
      expect(content, contains('<string>/usr/bin:/bin:/usr/sbin:/sbin</string>'));
      expect(content, isNot(contains('must-not-be-written')));
    });
  });

  group('LinuxSystemdUserBackend', () {
    test('install writes an instance-scoped unit and includes source-dir when provided', () async {
      final runner = _FakeRunner({'systemctl': _ok()});
      final backend = LinuxSystemdUserBackend(run: runner.call, home: home);

      final result = await backend.install(
        binPath: '/usr/local/bin/dartclaw',
        configPath: '$instanceDir/dartclaw.yaml',
        port: 3333,
        instanceDir: instanceDir,
        sourceDir: '/src/dartclaw',
      );

      final unitFiles = Directory('$home/.config/systemd/user').listSync().whereType<File>().toList();
      expect(result.success, isTrue);
      expect(unitFiles, hasLength(1));
      expect(unitFiles.single.readAsStringSync(), contains('--source-dir /src/dartclaw'));
    });

    test('status and uninstall are instance-scoped', () async {
      final runner = _FakeRunner({'systemctl': _ok('active\n')});
      final backend = LinuxSystemdUserBackend(run: runner.call, home: home);
      await backend.install(
        binPath: '/usr/local/bin/dartclaw',
        configPath: '$instanceDir/dartclaw.yaml',
        port: 3333,
        instanceDir: instanceDir,
      );

      expect(await backend.status(instanceDir: instanceDir), ServiceStatus.running);
      expect((await backend.uninstall(instanceDir: instanceDir)).success, isTrue);
    });
  });

  group('UnsupportedPlatformBackend', () {
    final backend = UnsupportedPlatformBackend();

    test('all operations fail with guidance', () async {
      expect(
        (await backend.install(
          binPath: '/bin/dartclaw',
          configPath: '/tmp/dartclaw.yaml',
          port: 3333,
          instanceDir: '/tmp/.dartclaw',
        )).success,
        isFalse,
      );
      expect(await backend.status(instanceDir: '/tmp/.dartclaw'), ServiceStatus.unknown);
      expect((await backend.start(instanceDir: '/tmp/.dartclaw')).success, isFalse);
      expect((await backend.stop(instanceDir: '/tmp/.dartclaw')).success, isFalse);
      expect((await backend.uninstall(instanceDir: '/tmp/.dartclaw')).success, isFalse);
    });
  });
}
