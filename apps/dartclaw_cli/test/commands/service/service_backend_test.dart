import 'dart:io';

import 'package:dartclaw_cli/src/commands/service/service_backend.dart';
import 'package:test/test.dart';

class _FakeRunner {
  final Map<String, ProcessResult> _responses;
  final List<ProcessResult> _launchctlResponses;
  final List<(String, List<String>)> calls = [];

  new(this._responses, {List<ProcessResult> launchctlResponses = const []})
    : _launchctlResponses = [...launchctlResponses];

  Future<ProcessResult> call(String exe, List<String> args) async {
    calls.add((exe, args));
    if (exe == 'launchctl' && _launchctlResponses.isNotEmpty) {
      return _launchctlResponses.removeAt(0);
    }
    return _responses[exe] ?? ProcessResult(0, 0, '', '');
  }
}

ProcessResult _ok([String stdout = '']) => ProcessResult(0, 0, stdout, '');

Future<File> _installOldDefinition(MacOSLaunchAgentBackend backend, String home, String instanceDir) async {
  final result = await backend.install(
    binPath: '/old/dartclaw',
    configPath: '$instanceDir/old.yaml',
    port: 3333,
    instanceDir: instanceDir,
  );
  expect(result.success, isTrue);
  return Directory('$home/Library/LaunchAgents').listSync().whereType<File>().single;
}

Future<ServiceResult> _refreshDefinition(MacOSLaunchAgentBackend backend, String instanceDir) => backend.install(
  binPath: '/new/dartclaw',
  configPath: '$instanceDir/new.yaml',
  port: 3333,
  instanceDir: instanceDir,
);

List<String> _launchctlVerbs(_FakeRunner runner) =>
    runner.calls.where((call) => call.$1 == 'launchctl').map((call) => call.$2.first).toList(growable: false);

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
      final escapedInstanceDir = '$instanceDir/a&b';
      final backend = MacOSLaunchAgentBackend(
        run: runner.call,
        home: home,
        environment: {'PATH': '/opt/homebrew/bin::relative:/Users/test/a&b'},
      );

      final install = await backend.install(
        binPath: '/usr/local/bin/dart&claw',
        configPath: '$escapedInstanceDir/config<prod>.yaml',
        port: 3333,
        instanceDir: escapedInstanceDir,
        sourceDir: '/src/"dartclaw"',
      );
      final start = await backend.start(instanceDir: escapedInstanceDir);

      expect(install.success, isTrue);
      expect(start.success, isTrue);
      final plist = Directory('$home/Library/LaunchAgents').listSync().whereType<File>().single;
      expect(plist.path, contains('com.dartclaw.agent.'));
      final content = plist.readAsStringSync();
      expect(content, contains('<key>EnvironmentVariables</key>'));
      expect(content, contains('<key>PATH</key>'));
      expect(content, contains('<string>/opt/homebrew/bin:/Users/test/a&amp;b</string>'));
      expect(content, contains('<string>/usr/local/bin/dart&amp;claw</string>'));
      expect(content, contains('<string>$instanceDir/a&amp;b/config&lt;prod&gt;.yaml</string>'));
      expect(content, contains('<string>/src/&quot;dartclaw&quot;</string>'));
      expect(content, contains('<string>$instanceDir/a&amp;b/logs/dartclaw.log</string>'));
      expect(content, contains('<string>$instanceDir/a&amp;b/logs/dartclaw.err.log</string>'));
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

      expect(_launchctlVerbs(runner), ['bootstrap', 'bootout', 'bootstrap']);
    });

    test('failed backup cleanup reports a warning without failing a loaded replacement', () async {
      final runner = _FakeRunner({'id': _ok('501'), 'launchctl': _ok()});
      final backend = MacOSLaunchAgentBackend(
        run: runner.call,
        home: home,
        deleteFile: (path) => throw FileSystemException('backup cleanup rejected', path),
      );
      final plist = await _installOldDefinition(backend, home, instanceDir);

      final refresh = await _refreshDefinition(backend, instanceDir);

      expect(refresh.success, isTrue);
      expect(refresh.message, contains('previous definition cleanup failed'));
      expect(plist.readAsStringSync(), contains('/new/dartclaw'));
      expect(
        Directory('$home/Library/LaunchAgents')
            .listSync()
            .whereType<File>()
            .any((file) => file.path.contains('.previous_')),
        isTrue,
      );
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

    test('failed bootout keeps the previous LaunchAgent definition', () async {
      final runner = _FakeRunner(
        {'id': _ok('501')},
        launchctlResponses: [_ok(), ProcessResult(0, 1, '', 'permission denied')],
      );
      final backend = MacOSLaunchAgentBackend(run: runner.call, home: home);
      final plist = await _installOldDefinition(backend, home, instanceDir);
      final previous = plist.readAsStringSync();

      final refresh = await _refreshDefinition(backend, instanceDir);

      expect(refresh.success, isFalse);
      expect(plist.readAsStringSync(), previous);
      expect(_launchctlVerbs(runner), ['bootstrap', 'bootout']);
    });

    test('failed staged cleanup cannot mask a bootout failure', () async {
      final runner = _FakeRunner(
        {'id': _ok('501')},
        launchctlResponses: [_ok(), ProcessResult(0, 1, '', 'permission denied')],
      );
      final backend = MacOSLaunchAgentBackend(
        run: runner.call,
        home: home,
        deleteFile: (path) => throw FileSystemException('cleanup rejected', path),
      );
      final plist = await _installOldDefinition(backend, home, instanceDir);
      final previous = plist.readAsStringSync();

      final refresh = await _refreshDefinition(backend, instanceDir);

      expect(refresh.success, isFalse);
      expect(refresh.message, contains('launchctl bootout failed'));
      expect(refresh.message, contains('staged cleanup failed'));
      expect(plist.readAsStringSync(), previous);
    });

    test('failed replacement bootstrap restores and reloads the previous definition', () async {
      final runner = _FakeRunner(
        {'id': _ok('501')},
        launchctlResponses: [_ok(), _ok(), ProcessResult(0, 1, '', 'replacement rejected'), _ok()],
      );
      final backend = MacOSLaunchAgentBackend(run: runner.call, home: home);
      final plist = await _installOldDefinition(backend, home, instanceDir);
      final previous = plist.readAsStringSync();

      final refresh = await _refreshDefinition(backend, instanceDir);

      expect(refresh.success, isFalse);
      expect(refresh.message, contains('previous LaunchAgent restored'));
      expect(plist.readAsStringSync(), previous);
      expect(_launchctlVerbs(runner), ['bootstrap', 'bootout', 'bootstrap', 'bootstrap']);
    });

    test('failed replacement move leaves both definitions recoverable', () async {
      final runner = _FakeRunner(
        {'id': _ok('501')},
        launchctlResponses: [_ok(), _ok(), ProcessResult(0, 1, '', 'replacement rejected')],
      );
      var renameCount = 0;
      final backend = MacOSLaunchAgentBackend(
        run: runner.call,
        home: home,
        renameFile: (source, target) {
          renameCount += 1;
          if (renameCount == 3) throw FileSystemException('replacement move rejected', source);
          File(source).renameSync(target);
        },
      );
      final plist = await _installOldDefinition(backend, home, instanceDir);

      final refresh = await _refreshDefinition(backend, instanceDir);

      expect(refresh.success, isFalse);
      expect(refresh.message, contains('previous definition remains'));
      expect(plist.readAsStringSync(), contains('/new/dartclaw'));
      expect(
        Directory('$home/Library/LaunchAgents')
            .listSync()
            .whereType<File>()
            .any((file) => file.path.contains('.previous_') && file.readAsStringSync().contains('/old/dartclaw')),
        isTrue,
      );
    });

    test('failed rollback rename restores the rejected definition and preserves the backup', () async {
      final runner = _FakeRunner(
        {'id': _ok('501')},
        launchctlResponses: [_ok(), _ok(), ProcessResult(0, 1, '', 'replacement rejected')],
      );
      var renameCount = 0;
      final backend = MacOSLaunchAgentBackend(
        run: runner.call,
        home: home,
        renameFile: (source, target) {
          renameCount += 1;
          if (renameCount == 4) throw FileSystemException('rollback rename rejected', source);
          File(source).renameSync(target);
        },
      );
      final plist = await _installOldDefinition(backend, home, instanceDir);

      final refresh = await _refreshDefinition(backend, instanceDir);

      expect(refresh.success, isFalse);
      expect(refresh.message, contains('previous definition remains'));
      expect(plist.readAsStringSync(), contains('/new/dartclaw'));
      expect(
        Directory('$home/Library/LaunchAgents')
            .listSync()
            .whereType<File>()
            .any((file) => file.path.contains('.previous_') && file.readAsStringSync().contains('/old/dartclaw')),
        isTrue,
      );
    });

    test('failed rejected-definition cleanup cannot prevent reloading the previous definition', () async {
      final runner = _FakeRunner(
        {'id': _ok('501')},
        launchctlResponses: [_ok(), _ok(), ProcessResult(0, 1, '', 'replacement rejected'), _ok()],
      );
      final backend = MacOSLaunchAgentBackend(
        run: runner.call,
        home: home,
        deleteFile: (path) {
          if (path.contains('.rejected_')) throw FileSystemException('cleanup rejected', path);
          File(path).deleteSync();
        },
      );
      final plist = await _installOldDefinition(backend, home, instanceDir);
      final previous = plist.readAsStringSync();

      final refresh = await _refreshDefinition(backend, instanceDir);

      expect(refresh.success, isFalse);
      expect(refresh.message, contains('previous LaunchAgent restored'));
      expect(refresh.message, contains('rejected definition cleanup failed'));
      expect(plist.readAsStringSync(), previous);
    });

    test('failed definition swap restores and reloads the previous definition', () async {
      final runner = _FakeRunner({'id': _ok('501')}, launchctlResponses: [_ok(), _ok(), _ok()]);
      var renameCount = 0;
      final backend = MacOSLaunchAgentBackend(
        run: runner.call,
        home: home,
        renameFile: (source, target) {
          renameCount += 1;
          if (renameCount == 2) throw FileSystemException('swap rejected', source);
          File(source).renameSync(target);
        },
      );
      final plist = await _installOldDefinition(backend, home, instanceDir);
      final previous = plist.readAsStringSync();

      final refresh = await _refreshDefinition(backend, instanceDir);

      expect(refresh.success, isFalse);
      expect(refresh.message, contains('previous LaunchAgent restored'));
      expect(plist.readAsStringSync(), previous);
      expect(_launchctlVerbs(runner), ['bootstrap', 'bootout', 'bootstrap']);
    });

    test('failed staged cleanup cannot prevent reloading the previous definition', () async {
      final runner = _FakeRunner({'id': _ok('501')}, launchctlResponses: [_ok(), _ok(), _ok()]);
      var renameCount = 0;
      final backend = MacOSLaunchAgentBackend(
        run: runner.call,
        home: home,
        renameFile: (source, target) {
          renameCount += 1;
          if (renameCount == 2) throw FileSystemException('swap rejected', source);
          File(source).renameSync(target);
        },
        deleteFile: (path) => throw FileSystemException('cleanup rejected', path),
      );
      final plist = await _installOldDefinition(backend, home, instanceDir);
      final previous = plist.readAsStringSync();

      final refresh = await _refreshDefinition(backend, instanceDir);

      expect(refresh.success, isFalse);
      expect(refresh.message, contains('previous LaunchAgent restored'));
      expect(refresh.message, contains('staged cleanup failed'));
      expect(plist.readAsStringSync(), previous);
      expect(_launchctlVerbs(runner), ['bootstrap', 'bootout', 'bootstrap']);
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
