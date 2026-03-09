import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/src/container/container_config.dart';
import 'package:dartclaw_core/src/container/container_manager.dart';
import 'package:test/test.dart';

void main() {
  group('ContainerManager', () {
    test('isDockerAvailable returns true on zero exit code', () async {
      final manager = _manager(run: (executable, arguments) async => ProcessResult(1, 0, '', ''));

      expect(await manager.isDockerAvailable(), isTrue);
    });

    test('isDockerAvailable returns false on non-zero exit code', () async {
      final manager = _manager(run: (executable, arguments) async => ProcessResult(1, 1, '', 'no docker'));

      expect(await manager.isDockerAvailable(), isFalse);
    });

    test('isDockerAvailable returns false on exception', () async {
      final manager = _manager(
        run: (executable, arguments) async => throw const ProcessException('docker', ['version']),
      );

      expect(await manager.isDockerAvailable(), isFalse);
    });

    test('ensureImage skips build when image exists', () async {
      final calls = <List<String>>[];
      final manager = _manager(
        run: (executable, arguments) async {
          calls.add([executable, ...arguments]);
          return ProcessResult(1, 0, '', '');
        },
      );

      await manager.ensureImage();

      expect(calls, [
        ['docker', 'image', 'inspect', 'dartclaw-agent:latest'],
      ]);
    });

    test('ensureImage builds when image missing', () async {
      final calls = <List<String>>[];
      final manager = _manager(
        run: (executable, arguments) async {
          calls.add([executable, ...arguments]);
          if (arguments.take(2).join(' ') == 'image inspect') {
            return ProcessResult(1, 1, '', 'missing');
          }
          return ProcessResult(1, 0, '', '');
        },
      );

      await manager.ensureImage();

      expect(calls, [
        ['docker', 'image', 'inspect', 'dartclaw-agent:latest'],
        ['docker', 'build', '-t', 'dartclaw-agent:latest', '/tmp/project/docker'],
      ]);
    });

    test('ensureImage throws when build fails', () async {
      final manager = _manager(
        run: (executable, arguments) async {
          if (arguments.take(2).join(' ') == 'image inspect') {
            return ProcessResult(1, 1, '', 'missing');
          }
          return ProcessResult(1, 1, '', 'build failed');
        },
      );

      await expectLater(manager.ensureImage(), throwsA(isA<StateError>()));
    });

    test('start creates container with hardened args and starts socat bridge', () async {
      final calls = <List<String>>[];
      final manager = _manager(
        run: (executable, arguments) async {
          calls.add([executable, ...arguments]);
          if (arguments.first == 'inspect') {
            return ProcessResult(1, 1, '', 'missing');
          }
          return ProcessResult(1, 0, '', '');
        },
      );

      await manager.start();

      final create = calls.firstWhere((call) => call[1] == 'create');
      expect(
        create,
        containsAll([
          '--network',
          'none',
          '--cap-drop',
          'ALL',
          '-e',
          'ANTHROPIC_BASE_URL=http://localhost:8080',
          '-v',
          '/tmp/proxy:/var/run/dartclaw',
          '-v',
          '/tmp/.claude.json:/home/dartclaw/.claude.json:ro',
        ]),
      );
      expect(create, containsAll(['sleep', 'infinity']));
      expect(
        calls.any(
          (call) =>
              call.join(' ') ==
              'docker exec -d dartclaw-agent socat TCP-LISTEN:8080,fork,reuseaddr '
                  'UNIX-CLIENT:/var/run/dartclaw/proxy.sock',
        ),
        isTrue,
      );
    });

    test('startSocatBridge throws on failure', () async {
      final manager = _manager(run: (executable, arguments) async => ProcessResult(1, 1, '', 'boom'));

      await expectLater(manager.startSocatBridge(), throwsA(isA<StateError>()));
    });

    test('start no-ops when container already healthy', () async {
      final calls = <List<String>>[];
      final manager = _manager(
        run: (executable, arguments) async {
          calls.add([executable, ...arguments]);
          if (arguments.first == 'inspect') {
            return ProcessResult(1, 0, 'true', '');
          }
          return ProcessResult(1, 0, '', '');
        },
      );

      await manager.start();

      expect(calls, [
        ['docker', 'inspect', '--format', '{{.State.Running}}', 'dartclaw-agent'],
      ]);
    });

    test('stop stops and removes container', () async {
      final calls = <List<String>>[];
      final manager = _manager(
        run: (executable, arguments) async {
          calls.add([executable, ...arguments]);
          return ProcessResult(1, 0, '', '');
        },
      );

      await manager.stop();

      expect(calls, [
        ['docker', 'stop', '-t', '5', 'dartclaw-agent'],
        ['docker', 'rm', '-f', 'dartclaw-agent'],
      ]);
    });

    test('exec passes env vars through docker exec', () async {
      List<String>? capturedArgs;
      bool? capturedIncludeParentEnvironment;
      final manager = _manager(
        run: (executable, arguments) async => ProcessResult(1, 0, '', ''),
        start: (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async {
          capturedArgs = [executable, ...arguments];
          capturedIncludeParentEnvironment = includeParentEnvironment;
          return _FakeProcess();
        },
      );

      await manager.exec(['claude', '--version'], env: {'FOO': 'bar'});

      expect(capturedArgs, [
        'docker',
        'exec',
        '-i',
        '-w',
        '/project',
        '-e',
        'FOO=bar',
        'dartclaw-agent',
        'claude',
        '--version',
      ]);
      expect(capturedIncludeParentEnvironment, isTrue);
    });

    test('isHealthy returns true only for running container', () async {
      final healthy = _manager(run: (executable, arguments) async => ProcessResult(1, 0, 'true\n', ''));
      final unhealthy = _manager(run: (executable, arguments) async => ProcessResult(1, 0, 'false\n', ''));

      expect(await healthy.isHealthy(), isTrue);
      expect(await unhealthy.isHealthy(), isFalse);
    });
  });
}

ContainerManager _manager({required RunCommand run, StartCommand? start}) {
  return ContainerManager(
    config: const ContainerConfig(enabled: true),
    workspaceDir: '/tmp/workspace',
    projectDir: '/tmp/project',
    proxySocketDir: '/tmp/proxy',
    hostClaudeJsonPath: '/tmp/.claude.json',
    runCommand: run,
    startCommand: start ?? _defaultStart,
  );
}

Future<Process> _defaultStart(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
  bool includeParentEnvironment = true,
}) async {
  return _FakeProcess();
}

class _FakeProcess implements Process {
  final _stdinController = StreamController<List<int>>();

  @override
  Future<int> get exitCode async => 0;

  @override
  int get pid => 1;

  @override
  IOSink get stdin => IOSink(_stdinController.sink);

  @override
  Stream<List<int>> get stderr => const Stream<List<int>>.empty();

  @override
  Stream<List<int>> get stdout => const Stream<List<int>>.empty();

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}
