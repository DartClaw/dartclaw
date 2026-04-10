import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/service/service_backend.dart';
import 'package:dartclaw_cli/src/commands/service/service_command.dart';
import 'package:test/test.dart';

class _FakeBackend implements ServiceBackend {
  final ServiceStatus _status;
  final ServiceResult _installResult;
  final ServiceResult _uninstallResult;
  final ServiceResult _startResult;
  final ServiceResult _stopResult;
  final List<String> calls = [];
  String? lastConfigPath;

  _FakeBackend({
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
    String? sourceDir,
  }) async {
    calls.add('install:$instanceDir');
    lastConfigPath = configPath;
    return _installResult;
  }

  @override
  Future<ServiceResult> uninstall({required String instanceDir}) async {
    calls.add('uninstall:$instanceDir');
    return _uninstallResult;
  }

  @override
  Future<ServiceStatus> status({required String instanceDir}) async {
    calls.add('status:$instanceDir');
    return _status;
  }

  @override
  Future<ServiceResult> start({required String instanceDir}) async {
    calls.add('start:$instanceDir');
    return _startResult;
  }

  @override
  Future<ServiceResult> stop({required String instanceDir}) async {
    calls.add('stop:$instanceDir');
    return _stopResult;
  }
}

CommandRunner<void> _runner(_FakeBackend backend) =>
    CommandRunner<void>('test', 'test')..addCommand(ServiceCommand(backend: backend));

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
        stdout: () => _CapturingStdout(output),
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
        stdout: () => _CapturingStdout(output),
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
        stdout: () => _CapturingStdout(output),
      );

      expect(output.join('\n'), contains('/tmp/two'));
      expect(backend.calls, contains('status:/tmp/two'));
    });

    test('service start failure sets exitCode=1', () async {
      final errors = <String>[];
      final runner = _runner(_FakeBackend(startResult: ServiceResult(success: false, message: 'not installed')));

      await IOOverrides.runZoned(
        () => runner.run(['service', 'start', '--instance-dir', '/tmp/three']),
        stderr: () => _CapturingStdout(errors),
        stdout: () => _CapturingStdout([]),
      );

      expect(errors.join('\n'), contains('not installed'));
      expect(exitCode, 1);
      exitCode = 0;
    });
  });
}

class _CapturingStdout implements Stdout {
  final List<String> lines;
  _CapturingStdout(this.lines);

  @override
  void writeln([Object? object = '']) => lines.add(object.toString());

  @override
  void write(Object? object) => lines.add(object.toString());

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
