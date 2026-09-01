import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/service/service_backend.dart';
import 'package:dartclaw_cli/src/commands/service/service_command.dart';
import 'package:test/test.dart';

import '../../helpers/capturing_stdout.dart';

class _FakeBackend implements ServiceBackend {
  final ServiceStatus _status;
  final ServiceResult _installResult;
  final ServiceResult _uninstallResult;
  final ServiceResult _startResult;
  final ServiceResult _stopResult;
  final List<String> calls = [];
  String? lastConfigPath;
  ServiceScope? lastScope;
  String? lastServiceUser;

  new({
    ServiceStatus status = ServiceStatus.notInstalled,
    ServiceResult installResult = const ServiceResult(success: true, message: 'installed'),
    ServiceResult uninstallResult = const ServiceResult(success: true, message: 'uninstalled'),
    ServiceResult startResult = const ServiceResult(success: true, message: 'started'),
    ServiceResult stopResult = const ServiceResult(success: true, message: 'stopped'),
  }) : _status = status,
       _installResult = installResult,
       _uninstallResult = uninstallResult,
       _startResult = startResult,
       _stopResult = stopResult;

  @override
  Future<ServiceResult> install({
    required String binPath,
    required String configPath,
    required int port,
    required String instanceDir,
    required ServiceScope scope,
    String? sourceDir,
    String? serviceUser,
  }) async {
    calls.add('install:$instanceDir');
    lastConfigPath = configPath;
    lastScope = scope;
    lastServiceUser = serviceUser;
    return _installResult;
  }

  @override
  Future<ServiceResult> uninstall({required String instanceDir, required ServiceScope scope}) async {
    calls.add('uninstall:$instanceDir');
    lastScope = scope;
    return _uninstallResult;
  }

  @override
  Future<ServiceStatus> status({required String instanceDir, required ServiceScope scope}) async {
    calls.add('status:$instanceDir');
    lastScope = scope;
    return _status;
  }

  @override
  Future<ServiceResult> start({required String instanceDir, required ServiceScope scope}) async {
    calls.add('start:$instanceDir');
    lastScope = scope;
    return _startResult;
  }

  @override
  Future<ServiceResult> stop({required String instanceDir, required ServiceScope scope}) async {
    calls.add('stop:$instanceDir');
    lastScope = scope;
    return _stopResult;
  }
}

CommandRunner<void> _runner(_FakeBackend backend) =>
    CommandRunner<void>('test', 'test')..addCommand(ServiceCommand(backend: backend));

/// A temp instance directory holding a config, which system scope requires.
String _instanceWithConfig() {
  final dir = Directory.systemTemp.createTempSync('service_cmd_instance_');
  addTearDown(() => dir.deleteSync(recursive: true));
  File('${dir.path}/dartclaw.yaml').writeAsStringSync('data_dir: ${dir.path}\nport: 3333\n');
  return dir.path;
}

void main() {
  group('ServiceCommand', () {
    test('registers install, uninstall, status, start, stop subcommands', () {
      final cmd = ServiceCommand();
      expect(cmd.subcommands.keys.toSet(), containsAll(['install', 'uninstall', 'status', 'start', 'stop']));
    });

    test('service install reports success', () async {
      final output = <String>[];
      final backend = _FakeBackend();
      final runner = _runner(backend);

      await IOOverrides.runZoned(
        () => runner.run(['service', 'install', '--instance-dir', '/tmp/one']),
        stdout: () => CapturingStdout(output),
      );

      expect(output.join('\n'), contains('installed'));
      expect(backend.calls, contains('install:/tmp/one'));
      expect(backend.lastConfigPath, '/tmp/one/dartclaw.yaml');
    });

    test('service install preserves DARTCLAW_CONFIG target outside the instance directory', () async {
      final tempDir = await Directory.systemTemp.createTemp('service_cmd_test_');
      addTearDown(() => tempDir.delete(recursive: true));
      final customConfig = File('${tempDir.path}/custom.yaml');
      customConfig.writeAsStringSync('''
data_dir: ${tempDir.path}/instance
port: 4444
''');

      final output = <String>[];
      final backend = _FakeBackend();
      final runner = CommandRunner<void>('test', 'test')
        ..addCommand(
          ServiceCommand(
            backend: backend,
            env: {'HOME': tempDir.path, 'DARTCLAW_CONFIG': customConfig.path},
            detectSourceDir: () => null,
          ),
        );

      await IOOverrides.runZoned(
        () => runner.run(['service', 'install', '--bin-path', '/usr/local/bin/dartclaw']),
        stdout: () => CapturingStdout(output),
      );

      expect(backend.calls, contains('install:${tempDir.path}/instance'));
      expect(backend.lastConfigPath, customConfig.path);
    });

    test('service status uses selected instance', () async {
      final output = <String>[];
      final backend = _FakeBackend(status: ServiceStatus.running);
      final runner = _runner(backend);

      await IOOverrides.runZoned(
        () => runner.run(['service', 'status', '--instance-dir', '/tmp/two']),
        stdout: () => CapturingStdout(output),
      );

      expect(output.join('\n'), contains('/tmp/two'));
      expect(backend.calls, contains('status:/tmp/two'));
    });

    test('every subcommand accepts --system and defaults to user scope', () async {
      final cmd = ServiceCommand();
      for (final name in ['install', 'uninstall', 'status', 'start', 'stop']) {
        expect(cmd.subcommands[name]!.argParser.options.keys, contains('system'), reason: name);
      }
      expect(cmd.subcommands['install']!.argParser.options.keys, contains('service-user'));

      final backend = _FakeBackend();
      await IOOverrides.runZoned(
        () => _runner(backend).run(['service', 'status', '--instance-dir', '/tmp/scope']),
        stdout: () => CapturingStdout([]),
      );
      expect(backend.lastScope, ServiceScope.user);
    });

    test('service install --system passes system scope and the SUDO_USER run-as user', () async {
      final instanceDir = _instanceWithConfig();
      final backend = _FakeBackend();
      final runner = CommandRunner<void>('test', 'test')
        ..addCommand(ServiceCommand(backend: backend, env: {'SUDO_USER': 'alice'}, detectSourceDir: () => null));

      await IOOverrides.runZoned(
        () => runner.run(['service', 'install', '--system', '--instance-dir', instanceDir]),
        stdout: () => CapturingStdout([]),
      );

      expect(backend.lastScope, ServiceScope.system);
      expect(backend.lastServiceUser, 'alice');
    });

    test('--service-user overrides SUDO_USER', () async {
      final instanceDir = _instanceWithConfig();
      final backend = _FakeBackend();
      final runner = CommandRunner<void>('test', 'test')
        ..addCommand(ServiceCommand(backend: backend, env: {'SUDO_USER': 'alice'}, detectSourceDir: () => null));

      await IOOverrides.runZoned(
        () => runner.run(['service', 'install', '--system', '--service-user', 'bob', '--instance-dir', instanceDir]),
        stdout: () => CapturingStdout([]),
      );

      expect(backend.lastServiceUser, 'bob');
    });

    test('--service-user without --system is a usage error', () async {
      final backend = _FakeBackend();

      await expectLater(
        IOOverrides.runZoned(
          () => _runner(backend).run(['service', 'install', '--service-user', 'alice', '--instance-dir', '/tmp/one']),
          stdout: () => CapturingStdout([]),
        ),
        throwsA(isA<UsageException>()),
      );
      expect(backend.calls, isEmpty);
    });

    test('system-scope install refuses an instance with no config rather than writing a broken unit', () async {
      final errors = <String>[];
      final backend = _FakeBackend();
      final runner = CommandRunner<void>('test', 'test')
        ..addCommand(ServiceCommand(backend: backend, env: {'SUDO_USER': 'alice'}, detectSourceDir: () => null));

      await IOOverrides.runZoned(
        () => runner.run(['service', 'install', '--system', '--instance-dir', '/tmp/s30-absent-instance']),
        stderr: () => CapturingStdout(errors),
        stdout: () => CapturingStdout([]),
      );

      expect(errors.join('\n'), contains('/tmp/s30-absent-instance/dartclaw.yaml'));
      expect(backend.calls, isEmpty);
      expect(exitCode, 1);
      exitCode = 0;
    });

    test('service uninstall --system targets the system scope', () async {
      final backend = _FakeBackend();
      await IOOverrides.runZoned(
        () => _runner(backend).run(['service', 'uninstall', '--system', '--instance-dir', '/opt/dartclaw']),
        stdout: () => CapturingStdout([]),
      );

      expect(backend.calls, contains('uninstall:/opt/dartclaw'));
      expect(backend.lastScope, ServiceScope.system);
    });

    test('system scope refuses to guess the instance under sudo', () async {
      final errors = <String>[];
      final backend = _FakeBackend();
      final runner = CommandRunner<void>('test', 'test')
        ..addCommand(ServiceCommand(backend: backend, env: {'SUDO_USER': 'alice'}, detectSourceDir: () => null));

      await IOOverrides.runZoned(
        () => runner.run(['service', 'install', '--system']),
        stderr: () => CapturingStdout(errors),
        stdout: () => CapturingStdout([]),
      );

      expect(errors.join('\n'), contains('--instance-dir'));
      expect(backend.calls, isEmpty);
      expect(exitCode, 1);
      exitCode = 0;
    });

    test('unknown system-scoped status names the root requirement', () async {
      final output = <String>[];
      final backend = _FakeBackend(status: ServiceStatus.unknown);
      final runner = _runner(backend);

      await IOOverrides.runZoned(
        () => runner.run(['service', 'status', '--system', '--instance-dir', '/opt/dartclaw']),
        stdout: () => CapturingStdout(output),
      );

      final printed = output.join('\n');
      expect(printed, contains('unknown'));
      expect(printed, contains('sudo dartclaw service status --system'));
    });

    test('unknown user-scoped status stays silent about root', () async {
      final output = <String>[];
      final backend = _FakeBackend(status: ServiceStatus.unknown);
      final runner = _runner(backend);

      await IOOverrides.runZoned(
        () => runner.run(['service', 'status', '--instance-dir', '/tmp/user-scope']),
        stdout: () => CapturingStdout(output),
      );

      expect(output.join('\n'), isNot(contains('sudo')));
    });

    test('service start failure sets exitCode=1', () async {
      final errors = <String>[];
      final runner = _runner(_FakeBackend(startResult: ServiceResult(success: false, message: 'not installed')));

      await IOOverrides.runZoned(
        () => runner.run(['service', 'start', '--instance-dir', '/tmp/three']),
        stderr: () => CapturingStdout(errors),
        stdout: () => CapturingStdout([]),
      );

      expect(errors.join('\n'), contains('not installed'));
      expect(exitCode, 1);
      exitCode = 0;
    });
  });
}
