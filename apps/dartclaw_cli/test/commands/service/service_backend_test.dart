import 'dart:io';

import 'package:dartclaw_cli/src/commands/service/service_backend.dart';
import 'package:test/test.dart';

class _FakeRunner {
  final Map<String, ProcessResult> _responses;
  final List<ProcessResult> _launchctlResponses;
  final Set<String> _accounts;
  final List<(String, List<String>)> calls = [];

  new(this._responses, {List<ProcessResult> launchctlResponses = const [], Set<String> accounts = const {'alice'}})
    : _launchctlResponses = [...launchctlResponses],
      _accounts = accounts;

  Future<ProcessResult> call(String exe, List<String> args) async {
    calls.add((exe, args));
    if (exe == 'launchctl' && _launchctlResponses.isNotEmpty) {
      return _launchctlResponses.removeAt(0);
    }
    // `id -u <name>` resolves an account; bare `id -u` reports the caller.
    if (exe == 'id' && args.length > 1) {
      return _accounts.contains(args[1]) ? _ok('1001') : ProcessResult(0, 1, '', 'id: ${args[1]}: no such user');
    }
    return _responses[exe] ?? ProcessResult(0, 0, '', '');
  }
}

ProcessResult _ok([String stdout = '']) => ProcessResult(0, 0, stdout, '');

/// `id -u` answers for the two privilege levels the system scope discriminates.
ProcessResult _asRoot() => _ok('0');
ProcessResult _asUser() => _ok('501');

List<(String, List<String>)> _launchctlCalls(_FakeRunner runner) =>
    runner.calls.where((call) => call.$1 == 'launchctl').toList(growable: false);

List<String> _launchctlVerbs(_FakeRunner runner) =>
    _launchctlCalls(runner).map((call) => call.$2.first).toList(growable: false);

List<List<String>> _systemctlArgs(_FakeRunner runner) =>
    runner.calls.where((call) => call.$1 == 'systemctl').map((call) => call.$2).toList(growable: false);

void main() {
  late Directory tempDir;
  late String home;
  late String systemRoot;
  late String instanceDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('service_backend_test_');
    home = tempDir.path;
    systemRoot = '$home/system-root';
    instanceDir = '$home/.dartclaw';
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('MacOSLaunchdBackend user scope', () {
    test('install writes an instance-scoped plist and start uses the same instance', () async {
      final runner = _FakeRunner({'id': _asUser(), 'launchctl': _ok()});
      final escapedInstanceDir = '$instanceDir/a&b';
      final backend = MacOSLaunchdBackend(
        run: runner.call,
        home: home,
        systemRoot: systemRoot,
        environment: {'PATH': '/opt/homebrew/bin::relative:/Users/test/a&b'},
      );

      final install = await backend.install(
        binPath: '/usr/local/bin/dart&claw',
        configPath: '$escapedInstanceDir/config<prod>.yaml',
        port: 3333,
        instanceDir: escapedInstanceDir,
        scope: ServiceScope.user,
        sourceDir: '/src/"dartclaw"',
      );
      final start = await backend.start(instanceDir: escapedInstanceDir, scope: ServiceScope.user);

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
      // User scope stays a login-session agent: no run-as user, no boot start.
      expect(content, isNot(contains('<key>UserName</key>')));
      expect(content, contains('<key>RunAtLoad</key>\n  <false/>'));
      expect(Directory('$systemRoot/Library/LaunchDaemons').existsSync(), isFalse);
    });

    test('install falls back to the system PATH when no absolute entries exist', () async {
      final runner = _FakeRunner({'id': _asUser(), 'launchctl': _ok()});
      final backend = MacOSLaunchdBackend(
        run: runner.call,
        home: home,
        environment: {'PATH': 'relative::.', 'DARTCLAW_SECRET': 'must-not-be-written'},
      );

      await backend.install(
        binPath: '/usr/local/bin/dartclaw',
        configPath: '$instanceDir/dartclaw.yaml',
        port: 3333,
        instanceDir: instanceDir,
        scope: ServiceScope.user,
      );

      final content = Directory('$home/Library/LaunchAgents').listSync().whereType<File>().single.readAsStringSync();
      expect(content, contains('<string>/usr/bin:/bin:/usr/sbin:/sbin</string>'));
      expect(content, isNot(contains('must-not-be-written')));
    });

    test('reinstalling over an existing definition loads the new one', () async {
      final runner = _FakeRunner({'id': _asUser(), 'launchctl': _ok()});
      final backend = MacOSLaunchdBackend(run: runner.call, home: home, environment: {'PATH': '/opt/homebrew/bin'});

      await _install(backend, instanceDir, binPath: '/old/dartclaw');
      final refresh = await _install(backend, instanceDir, binPath: '/new/dartclaw');

      expect(refresh.success, isTrue);
      expect(refresh.message, 'LaunchAgent definition refreshed and loaded.');
      final plist = Directory('$home/Library/LaunchAgents').listSync().whereType<File>().single;
      expect(plist.readAsStringSync(), contains('/new/dartclaw'));
      expect(_launchctlVerbs(runner), ['bootstrap', 'bootout', 'bootstrap']);
    });

    test('a failed replacement bootstrap restores and reloads the previous definition', () async {
      final runner = _FakeRunner(
        {'id': _asUser()},
        launchctlResponses: [_ok(), _ok(), ProcessResult(0, 1, '', 'replacement rejected'), _ok()],
      );
      final backend = MacOSLaunchdBackend(run: runner.call, home: home);
      await _install(backend, instanceDir, binPath: '/old/dartclaw');
      final plist = Directory('$home/Library/LaunchAgents').listSync().whereType<File>().single;
      final previous = plist.readAsStringSync();

      final refresh = await _install(backend, instanceDir, binPath: '/new/dartclaw');

      expect(refresh.success, isFalse);
      expect(refresh.message, contains('launchctl bootstrap failed: replacement rejected'));
      expect(refresh.message, contains('previous LaunchAgent restored'));
      expect(plist.readAsStringSync(), previous);
      expect(_launchctlVerbs(runner), ['bootstrap', 'bootout', 'bootstrap', 'bootstrap']);
    });

    test('a failed restore is reported alongside the bootstrap failure', () async {
      final runner = _FakeRunner(
        {'id': _asUser()},
        launchctlResponses: [
          _ok(),
          _ok(),
          ProcessResult(0, 1, '', 'replacement rejected'),
          ProcessResult(0, 1, '', 'restore rejected'),
        ],
      );
      final backend = MacOSLaunchdBackend(run: runner.call, home: home);
      await _install(backend, instanceDir, binPath: '/old/dartclaw');

      final refresh = await _install(backend, instanceDir, binPath: '/new/dartclaw');

      expect(refresh.success, isFalse);
      expect(refresh.message, contains('launchctl bootstrap failed: replacement rejected'));
      expect(refresh.message, contains('restoring the previous LaunchAgent also failed: restore rejected'));
    });

    test('a first install bootstraps without booting out a label that was never loaded', () async {
      final runner = _FakeRunner({'id': _asUser(), 'launchctl': _ok()});
      final backend = MacOSLaunchdBackend(run: runner.call, home: home);

      final result = await _install(backend, instanceDir);

      expect(result.success, isTrue);
      expect(result.message, 'LaunchAgent installed and loaded.');
      expect(_launchctlVerbs(runner), ['bootstrap']);
      expect(Directory('$home/Library/LaunchAgents').listSync().whereType<File>(), hasLength(1));
    });

    test('a refresh tolerates a bootout wording other than "No such process"', () async {
      final runner = _FakeRunner(
        {'id': _asUser()},
        launchctlResponses: [_ok(), ProcessResult(0, 3, '', 'Could not find service "x" in domain'), _ok()],
      );
      final backend = MacOSLaunchdBackend(run: runner.call, home: home);
      await _install(backend, instanceDir, binPath: '/old/dartclaw');

      final refresh = await _install(backend, instanceDir, binPath: '/new/dartclaw');

      expect(refresh.success, isTrue);
      final plist = Directory('$home/Library/LaunchAgents').listSync().whereType<File>().single;
      expect(plist.readAsStringSync(), contains('/new/dartclaw'));
    });

    test('a failed bootout keeps the previous definition untouched', () async {
      final runner = _FakeRunner(
        {'id': _asUser()},
        launchctlResponses: [_ok(), ProcessResult(0, 1, '', 'permission denied')],
      );
      final backend = MacOSLaunchdBackend(run: runner.call, home: home);
      await _install(backend, instanceDir, binPath: '/old/dartclaw');
      final plist = Directory('$home/Library/LaunchAgents').listSync().whereType<File>().single;
      final previous = plist.readAsStringSync();

      final refresh = await _install(backend, instanceDir, binPath: '/new/dartclaw');

      expect(refresh.success, isFalse);
      expect(refresh.message, contains('launchctl bootout failed: permission denied'));
      expect(plist.readAsStringSync(), previous);
    });
  });

  group('MacOSLaunchdBackend system scope', () {
    test('install as root writes a boot-started LaunchDaemon that runs as the operator', () async {
      final runner = _FakeRunner({'id': _asRoot(), 'launchctl': _ok()});
      final backend = MacOSLaunchdBackend(run: runner.call, home: home, systemRoot: systemRoot);

      final result = await backend.install(
        binPath: '/usr/local/bin/dartclaw',
        configPath: '$instanceDir/dartclaw.yaml',
        port: 3333,
        instanceDir: instanceDir,
        scope: ServiceScope.system,
        serviceUser: 'alice',
      );

      expect(result.success, isTrue);
      expect(result.message, 'LaunchDaemon installed and loaded.');
      expect(Directory('$home/Library/LaunchAgents').existsSync(), isFalse);
      final plist = Directory('$systemRoot/Library/LaunchDaemons').listSync().whereType<File>().single;
      final content = plist.readAsStringSync();
      expect(content, contains('<key>UserName</key>\n  <string>alice</string>'));
      expect(content, contains('<key>RunAtLoad</key>\n  <true/>'));
      expect(content, isNot(contains('ANTHROPIC_API_KEY')));
      expect(_launchctlCalls(runner).map((call) => call.$2), [
        ['bootstrap', 'system', plist.path],
      ]);
    });

    test('install without privileges refuses before writing anything', () async {
      final runner = _FakeRunner({'id': _asUser(), 'launchctl': _ok()});
      final backend = MacOSLaunchdBackend(run: runner.call, home: home, systemRoot: systemRoot);

      final result = await backend.install(
        binPath: '/usr/local/bin/dartclaw',
        configPath: '$instanceDir/dartclaw.yaml',
        port: 3333,
        instanceDir: instanceDir,
        scope: ServiceScope.system,
        serviceUser: 'alice',
      );

      expect(result.success, isFalse);
      expect(result.message, contains('requires root privileges'));
      expect(result.message, contains('sudo dartclaw service install --system'));
      expect(Directory('$systemRoot/Library/LaunchDaemons').existsSync(), isFalse);
      expect(_launchctlCalls(runner), isEmpty);
    });

    test('install without a resolvable run-as user refuses rather than running as root', () async {
      final runner = _FakeRunner({'id': _asRoot(), 'launchctl': _ok()});
      final backend = MacOSLaunchdBackend(run: runner.call, home: home, systemRoot: systemRoot);

      final result = await backend.install(
        binPath: '/usr/local/bin/dartclaw',
        configPath: '$instanceDir/dartclaw.yaml',
        port: 3333,
        instanceDir: instanceDir,
        scope: ServiceScope.system,
      );

      expect(result.success, isFalse);
      expect(result.message, contains('--service-user'));
      expect(Directory('$systemRoot/Library/LaunchDaemons').existsSync(), isFalse);
    });

    test('install refuses a run-as user that names no account', () async {
      final runner = _FakeRunner({'id': _asRoot(), 'launchctl': _ok()});
      final backend = MacOSLaunchdBackend(run: runner.call, home: home, systemRoot: systemRoot);

      final result = await _install(backend, instanceDir, scope: ServiceScope.system, serviceUser: 'alicce');

      expect(result.success, isFalse);
      expect(result.message, contains('No account named "alicce"'));
      expect(Directory('$systemRoot/Library/LaunchDaemons').existsSync(), isFalse);
      expect(_launchctlCalls(runner), isEmpty);
    });

    test('uninstall reaches only the scope it is pointed at', () async {
      final runner = _FakeRunner({'id': _asRoot(), 'launchctl': _ok()});
      final backend = MacOSLaunchdBackend(run: runner.call, home: home, systemRoot: systemRoot);
      await _install(backend, instanceDir);
      await _install(backend, instanceDir, scope: ServiceScope.system, serviceUser: 'alice');
      final daemonLabel = _labelIn(systemRoot);

      final removed = await backend.uninstall(instanceDir: instanceDir, scope: ServiceScope.system);

      expect(removed.success, isTrue);
      expect(removed.message, 'LaunchDaemon removed.');
      expect(Directory('$systemRoot/Library/LaunchDaemons').listSync(), isEmpty);
      expect(Directory('$home/Library/LaunchAgents').listSync().whereType<File>(), hasLength(1));
      expect(
        await backend.status(instanceDir: instanceDir, scope: ServiceScope.user),
        isNot(ServiceStatus.notInstalled),
      );
      expect(_launchctlCalls(runner).map((call) => call.$2.join(' ')), contains('bootout system/$daemonLabel'));
    });

    test('start without privileges refuses and issues no launchctl command', () async {
      final runner = _FakeRunner({'id': _asUser(), 'launchctl': _ok()});
      final backend = MacOSLaunchdBackend(run: runner.call, home: home, systemRoot: systemRoot);

      final result = await backend.start(instanceDir: instanceDir, scope: ServiceScope.system);

      expect(result.success, isFalse);
      expect(result.message, contains('sudo dartclaw service start --system'));
      expect(_launchctlCalls(runner), isEmpty);
    });

    test('uninstall without privileges refuses and issues no launchctl command', () async {
      final runner = _FakeRunner({'id': _asUser(), 'launchctl': _ok()});
      final backend = MacOSLaunchdBackend(run: runner.call, home: home, systemRoot: systemRoot);

      final result = await backend.uninstall(instanceDir: instanceDir, scope: ServiceScope.system);

      expect(result.success, isFalse);
      expect(result.message, contains('sudo dartclaw service uninstall --system'));
      expect(_launchctlCalls(runner), isEmpty);
    });

    test('status and start as root address the system domain, never gui/<uid>', () async {
      final runner = _FakeRunner({'id': _asRoot(), 'launchctl': _ok('state = running')});
      final backend = MacOSLaunchdBackend(run: runner.call, home: home, systemRoot: systemRoot);
      await _install(backend, instanceDir, scope: ServiceScope.system, serviceUser: 'alice');
      final label = _labelIn(systemRoot);
      runner.calls.clear();

      expect(await backend.status(instanceDir: instanceDir, scope: ServiceScope.system), ServiceStatus.running);
      expect((await backend.start(instanceDir: instanceDir, scope: ServiceScope.system)).success, isTrue);

      expect(_launchctlCalls(runner).map((call) => call.$2), [
        ['print', 'system/$label'],
        ['kickstart', 'system/$label'],
      ]);
    });

    test('status without privileges cannot answer', () async {
      final runner = _FakeRunner({'id': _asUser(), 'launchctl': _ok()});
      final backend = MacOSLaunchdBackend(run: runner.call, home: home, systemRoot: systemRoot);

      expect(await backend.status(instanceDir: instanceDir, scope: ServiceScope.system), ServiceStatus.unknown);
      expect(_launchctlCalls(runner), isEmpty);
    });
  });

  group('LinuxSystemdBackend user scope', () {
    test('install writes an instance-scoped unit and includes source-dir when provided', () async {
      final runner = _FakeRunner({'systemctl': _ok()});
      final backend = LinuxSystemdBackend(run: runner.call, home: home, systemRoot: systemRoot);

      final result = await backend.install(
        binPath: '/usr/local/bin/dartclaw',
        configPath: '$instanceDir/dartclaw.yaml',
        port: 3333,
        instanceDir: instanceDir,
        scope: ServiceScope.user,
        sourceDir: '/src/dartclaw',
      );

      final unitFiles = Directory('$home/.config/systemd/user').listSync().whereType<File>().toList();
      expect(result.success, isTrue);
      expect(unitFiles, hasLength(1));
      final content = unitFiles.single.readAsStringSync();
      expect(content, contains('--source-dir /src/dartclaw'));
      // User scope stays a login-session unit: no run-as user, no boot target,
      // no filesystem hardening aimed at a root-installed daemon.
      expect(content, isNot(contains('User=')));
      expect(content, contains('WantedBy=default.target'));
      expect(content, isNot(contains('ProtectSystem')));
      expect(content, contains('Restart=on-failure'));
      expect(_systemctlArgs(runner).every((args) => args.first == '--user'), isTrue);
      expect(Directory('$systemRoot/etc/systemd/system').existsSync(), isFalse);
    });

    test('status and uninstall are instance-scoped', () async {
      final runner = _FakeRunner({'systemctl': _ok('active\n')});
      final backend = LinuxSystemdBackend(run: runner.call, home: home);
      await _install(backend, instanceDir);

      expect(await backend.status(instanceDir: instanceDir, scope: ServiceScope.user), ServiceStatus.running);
      expect((await backend.uninstall(instanceDir: instanceDir, scope: ServiceScope.user)).success, isTrue);
    });
  });

  group('LinuxSystemdBackend system scope', () {
    test('install as root writes a hardened multi-user unit that runs as the operator', () async {
      final runner = _FakeRunner({'systemctl': _ok(), 'id': _asRoot()});
      final backend = LinuxSystemdBackend(run: runner.call, home: home, systemRoot: systemRoot);

      final result = await backend.install(
        binPath: '/usr/local/bin/dartclaw',
        configPath: '$instanceDir/dartclaw.yaml',
        port: 3333,
        instanceDir: instanceDir,
        scope: ServiceScope.system,
        serviceUser: 'alice',
      );

      expect(result.success, isTrue);
      expect(Directory('$home/.config/systemd/user').existsSync(), isFalse);
      final unit = Directory('$systemRoot/etc/systemd/system').listSync().whereType<File>().single;
      final content = unit.readAsStringSync();
      expect(content, contains('User=alice'));
      expect(content, contains('WantedBy=multi-user.target'));
      expect(content, contains('NoNewPrivileges=true'));
      expect(content, contains('ProtectSystem=strict'));
      expect(content, contains('ProtectHome=read-only'));
      expect(content, contains('ReadWritePaths=$instanceDir'));
      expect(content, contains('PrivateTmp=true'));
      expect(content, isNot(contains('ANTHROPIC_API_KEY')));
      expect(_systemctlArgs(runner).any((args) => args.contains('--user')), isFalse);
      expect(_systemctlArgs(runner).first, ['daemon-reload']);
    });

    test('install without privileges refuses before writing anything', () async {
      final runner = _FakeRunner({'systemctl': _ok(), 'id': _asUser()});
      final backend = LinuxSystemdBackend(run: runner.call, home: home, systemRoot: systemRoot);

      final result = await backend.install(
        binPath: '/usr/local/bin/dartclaw',
        configPath: '$instanceDir/dartclaw.yaml',
        port: 3333,
        instanceDir: instanceDir,
        scope: ServiceScope.system,
        serviceUser: 'alice',
      );

      expect(result.success, isFalse);
      expect(result.message, contains('requires root privileges'));
      expect(result.message, contains('sudo dartclaw service install --system'));
      expect(Directory('$systemRoot/etc/systemd/system').existsSync(), isFalse);
      expect(_systemctlArgs(runner), isEmpty);
    });

    test('install without a resolvable run-as user refuses rather than running as root', () async {
      final runner = _FakeRunner({'systemctl': _ok(), 'id': _asRoot()});
      final backend = LinuxSystemdBackend(run: runner.call, home: home, systemRoot: systemRoot);

      final result = await backend.install(
        binPath: '/usr/local/bin/dartclaw',
        configPath: '$instanceDir/dartclaw.yaml',
        port: 3333,
        instanceDir: instanceDir,
        scope: ServiceScope.system,
      );

      expect(result.success, isFalse);
      expect(result.message, contains('--service-user'));
      expect(Directory('$systemRoot/etc/systemd/system').existsSync(), isFalse);
    });

    test('install refuses a run-as user that names no account', () async {
      final runner = _FakeRunner({'systemctl': _ok(), 'id': _asRoot()});
      final backend = LinuxSystemdBackend(run: runner.call, home: home, systemRoot: systemRoot);

      final result = await _install(backend, instanceDir, scope: ServiceScope.system, serviceUser: 'alicce');

      expect(result.success, isFalse);
      expect(result.message, contains('No account named "alicce"'));
      expect(Directory('$systemRoot/etc/systemd/system').existsSync(), isFalse);
      expect(_systemctlArgs(runner), isEmpty);
    });

    test('uninstall reaches only the scope it is pointed at', () async {
      final runner = _FakeRunner({'systemctl': _ok('active\n'), 'id': _asRoot()});
      final backend = LinuxSystemdBackend(run: runner.call, home: home, systemRoot: systemRoot);
      await _install(backend, instanceDir);
      await _install(backend, instanceDir, scope: ServiceScope.system, serviceUser: 'alice');

      final removed = await backend.uninstall(instanceDir: instanceDir, scope: ServiceScope.system);

      expect(removed.success, isTrue);
      expect(Directory('$systemRoot/etc/systemd/system').listSync(), isEmpty);
      expect(Directory('$home/.config/systemd/user').listSync().whereType<File>(), hasLength(1));
      expect(await backend.status(instanceDir: instanceDir, scope: ServiceScope.user), ServiceStatus.running);
    });

    test('uninstall without privileges refuses and issues no systemctl command', () async {
      final runner = _FakeRunner({'systemctl': _ok(), 'id': _asUser()});
      final backend = LinuxSystemdBackend(run: runner.call, home: home, systemRoot: systemRoot);

      final result = await backend.uninstall(instanceDir: instanceDir, scope: ServiceScope.system);

      expect(result.success, isFalse);
      expect(result.message, contains('sudo dartclaw service uninstall --system'));
      expect(_systemctlArgs(runner), isEmpty);
    });

    test('status and start as root drop --user and the unit restarts from a clean exit', () async {
      final runner = _FakeRunner({'systemctl': _ok('active\n'), 'id': _asRoot()});
      final backend = LinuxSystemdBackend(run: runner.call, home: home, systemRoot: systemRoot);
      await _install(backend, instanceDir, scope: ServiceScope.system, serviceUser: 'alice');
      final unit = Directory('$systemRoot/etc/systemd/system').listSync().whereType<File>().single;
      runner.calls.clear();

      expect(await backend.status(instanceDir: instanceDir, scope: ServiceScope.system), ServiceStatus.running);
      expect((await backend.start(instanceDir: instanceDir, scope: ServiceScope.system)).success, isTrue);

      expect(_systemctlArgs(runner).any((args) => args.contains('--user')), isFalse);
      expect(_systemctlArgs(runner).first.first, 'is-active');
      expect(unit.readAsStringSync(), contains('Restart=always'));
    });

    test('stop without privileges refuses and issues no systemctl command', () async {
      final runner = _FakeRunner({'systemctl': _ok(), 'id': _asUser()});
      final backend = LinuxSystemdBackend(run: runner.call, home: home, systemRoot: systemRoot);

      final result = await backend.stop(instanceDir: instanceDir, scope: ServiceScope.system);

      expect(result.success, isFalse);
      expect(result.message, contains('sudo dartclaw service stop --system'));
      expect(_systemctlArgs(runner), isEmpty);
    });
  });

  group('UnsupportedPlatformBackend', () {
    final backend = UnsupportedPlatformBackend();

    test('all operations fail with the same guidance for both scopes', () async {
      for (final scope in ServiceScope.values) {
        expect(
          (await backend.install(
            binPath: '/bin/dartclaw',
            configPath: '/tmp/dartclaw.yaml',
            port: 3333,
            instanceDir: '/tmp/.dartclaw',
            scope: scope,
          )).message,
          contains('dartclaw serve'),
        );
        expect(await backend.status(instanceDir: '/tmp/.dartclaw', scope: scope), ServiceStatus.unknown);
        expect((await backend.start(instanceDir: '/tmp/.dartclaw', scope: scope)).success, isFalse);
        expect((await backend.stop(instanceDir: '/tmp/.dartclaw', scope: scope)).success, isFalse);
        expect((await backend.uninstall(instanceDir: '/tmp/.dartclaw', scope: scope)).success, isFalse);
      }
    });
  });
}

Future<ServiceResult> _install(
  ServiceBackend backend,
  String instanceDir, {
  String binPath = '/usr/local/bin/dartclaw',
  ServiceScope scope = ServiceScope.user,
  String? serviceUser,
}) => backend.install(
  binPath: binPath,
  configPath: '$instanceDir/dartclaw.yaml',
  port: 3333,
  instanceDir: instanceDir,
  scope: scope,
  serviceUser: serviceUser,
);

String _labelIn(String systemRoot) {
  final plist = Directory('$systemRoot/Library/LaunchDaemons').listSync().whereType<File>().single;
  return plist.uri.pathSegments.last.replaceAll('.plist', '');
}
