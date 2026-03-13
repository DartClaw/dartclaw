import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/src/container/container_config.dart';
import 'package:dartclaw_core/src/container/container_manager.dart';
import 'package:test/test.dart';

void main() {
  const workspaceContainerName = 'dartclaw-test1234-workspace';
  const restrictedContainerName = 'dartclaw-test1234-restricted';

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
        config: const ContainerConfig(enabled: true, extraMounts: ['/tmp/shared:/shared:ro']),
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
          '/tmp/workspace:/workspace:rw',
          '-v',
          '/tmp/project:/project:ro',
          '-v',
          '/tmp/shared:/shared:ro',
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
              'docker exec -d $workspaceContainerName socat TCP-LISTEN:8080,fork,reuseaddr '
                  'UNIX-CLIENT:/var/run/dartclaw/proxy.sock',
        ),
        isTrue,
      );
    });

    test('start creates restricted container with no workspace mounts', () async {
      final calls = <List<String>>[];
      final manager = _manager(
        config: const ContainerConfig(enabled: true, extraMounts: ['/tmp/shared:/shared:ro']),
        containerName: restrictedContainerName,
        profileId: 'restricted',
        workspaceMounts: const [],
        workingDir: '/tmp',
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
      final createCommand = create.join(' ');
      expect(createCommand, isNot(contains('/workspace:rw')));
      expect(createCommand, isNot(contains('/project:ro')));
      expect(createCommand, contains('/shared:ro'));
      expect(
        create,
        containsAll([
          '--network',
          'none',
          '--cap-drop',
          'ALL',
          '--read-only',
          '--tmpfs',
          '/tmp:rw,noexec,nosuid,size=100m',
          '--security-opt',
          'no-new-privileges',
          '-v',
          '/tmp/shared:/shared:ro',
          '-v',
          '/tmp/proxy:/var/run/dartclaw',
        ]),
      );
    });

    test('start filters only workspace-related extra mounts for restricted profile', () async {
      final calls = <List<String>>[];
      final manager = _manager(
        config: const ContainerConfig(
          enabled: true,
          extraMounts: [
            '/tmp/shared:/shared:ro',
            '/tmp/other-project:/project:ro',
            '/tmp/other-workspace:/workspace:rw',
          ],
        ),
        containerName: restrictedContainerName,
        profileId: 'restricted',
        workspaceMounts: const [],
        workingDir: '/tmp',
        run: (executable, arguments) async {
          calls.add([executable, ...arguments]);
          if (arguments.first == 'inspect') {
            return ProcessResult(1, 1, '', 'missing');
          }
          return ProcessResult(1, 0, '', '');
        },
      );

      await manager.start();

      final createCommand = calls.firstWhere((call) => call[1] == 'create').join(' ');
      expect(createCommand, contains('/shared:ro'));
      expect(createCommand, isNot(contains('/other-project:/project:ro')));
      expect(createCommand, isNot(contains('/other-workspace:/workspace:rw')));
    });

    test('defaults buildContextDir to current working directory', () {
      final manager = _manager(
        buildContextDir: null,
        run: (executable, arguments) async => ProcessResult(1, 0, '', ''),
      );

      expect(manager.buildContextDir, Directory.current.path);
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
        ['docker', 'inspect', '--format', '{{.State.Running}}', workspaceContainerName],
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
        ['docker', 'stop', '-t', '5', workspaceContainerName],
        ['docker', 'rm', '-f', workspaceContainerName],
      ]);
    });

    test('deleteFileInContainer removes copied container files', () async {
      final calls = <List<String>>[];
      final manager = _manager(
        run: (executable, arguments) async {
          calls.add([executable, ...arguments]);
          return ProcessResult(1, 0, '', '');
        },
      );

      await manager.deleteFileInContainer('/tmp/dartclaw-mcp-config-123.json');

      expect(calls, [
        ['docker', 'exec', workspaceContainerName, 'rm', '-f', '/tmp/dartclaw-mcp-config-123.json'],
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
        workspaceContainerName,
        'claude',
        '--version',
      ]);
      expect(capturedIncludeParentEnvironment, isTrue);
    });

    test('exec uses /tmp working dir for restricted profile', () async {
      List<String>? capturedArgs;
      final manager = _manager(
        containerName: restrictedContainerName,
        profileId: 'restricted',
        workspaceMounts: const [],
        workingDir: '/tmp',
        run: (executable, arguments) async => ProcessResult(1, 0, '', ''),
        start: (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async {
          capturedArgs = [executable, ...arguments];
          return _FakeProcess();
        },
      );

      await manager.exec(['claude', '--version']);

      expect(capturedArgs, ['docker', 'exec', '-i', '-w', '/tmp', restrictedContainerName, 'claude', '--version']);
    });

    test('isHealthy returns true only for running container', () async {
      final healthy = _manager(run: (executable, arguments) async => ProcessResult(1, 0, 'true\n', ''));
      final unhealthy = _manager(run: (executable, arguments) async => ProcessResult(1, 0, 'false\n', ''));

      expect(await healthy.isHealthy(), isTrue);
      expect(await unhealthy.isHealthy(), isFalse);
    });
  });
}

ContainerManager _manager({
  ContainerConfig config = const ContainerConfig(enabled: true),
  required RunCommand run,
  StartCommand? start,
  String containerName = 'dartclaw-test1234-workspace',
  String profileId = 'workspace',
  List<String> workspaceMounts = const ['/tmp/workspace:/workspace:rw', '/tmp/project:/project:ro'],
  String? buildContextDir = '/tmp/project',
  String workingDir = '/project',
}) {
  return ContainerManager(
    config: config,
    containerName: containerName,
    profileId: profileId,
    workspaceMounts: workspaceMounts,
    proxySocketDir: '/tmp/proxy',
    hostClaudeJsonPath: '/tmp/.claude.json',
    buildContextDir: buildContextDir,
    workingDir: workingDir,
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
