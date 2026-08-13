import 'dart:io';

import 'package:dartclaw_bridge/dartclaw_bridge.dart' show BridgeSurface;
import 'package:dartclaw_core/dartclaw_core.dart' show containerGeneratedStatePath;
import 'package:dartclaw_models/dartclaw_models.dart' show ContainerConfig;
import 'package:dartclaw_server/src/container/bridge_binary.dart' show BridgeBinaryProvisioner;
import 'package:dartclaw_server/src/container/container_manager.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeProcess;
import 'package:path/path.dart' as p;
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

    test('start creates a network:none container whose only host object is the read-only bridge', () async {
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
          'ANTHROPIC_BASE_URL=http://127.0.0.1:8080',
          '-v',
          '/tmp/workspace:/workspace:rw',
          '-v',
          '/tmp/project:/project:ro',
          '-v',
          '/tmp/dartclaw-bridge:/opt/dartclaw/dartclaw-bridge:ro',
          '-v',
          '${manager.generatedStateDir}:$containerGeneratedStatePath:rw',
        ]),
      );
      expect(create, containsAll(['sleep', 'infinity']));

      // The container gets no socket, no published port, no added network, and
      // no egress-capable relay — only the read-only bridge binary.
      final createCommand = create.join(' ');
      expect(createCommand, isNot(contains('/var/run/docker.sock')));
      expect(createCommand, isNot(contains('.sock')));
      expect(createCommand, isNot(contains('-p ')));
      expect(createCommand, isNot(contains('--publish')));
      expect(createCommand, isNot(contains('--network host')));
      expect(calls.any((call) => call.contains('socat')), isFalse);
      expect(calls.any((call) => call.contains('-d')), isFalse, reason: 'no detached in-container helper');
      // No host provider home is mounted: login state stays outside the boundary.
      expect(createCommand, isNot(contains('.claude.json')));
      expect(createCommand, isNot(contains('.codex')));
    });

    test('start builds the exact docker create argv — the full container security boundary', () async {
      // CT-01 / G-HIGH-7. Order-exact golden over the entire `docker create`
      // argv. The semantic test above asserts with containsAll + a substring
      // denylist, so appending a privilege- or mount-granting flag passes it
      // green; this pins the whole vector so any addition, removal, or reorder
      // reddens. The expected list is built from the same name/mount/port
      // constants the production code uses.
      //
      // Mutation this rejects: appending `--privileged` (or `--cap-add`,
      // `SYS_ADMIN`, or an extra `-v` mount) to the args in ContainerManager
      // .start() — the golden no longer matches, reddening the test.
      final calls = <List<String>>[];
      final manager = _manager(
        artifactsDir: '/tmp/data/artifacts',
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
        equals([
          'docker',
          'create',
          '--name',
          workspaceContainerName,
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
          '/tmp/workspace:/workspace:rw',
          '-v',
          '/tmp/project:/project:ro',
          '-v',
          '/tmp/dartclaw-bridge:${BridgeBinaryProvisioner.containerPath}:ro',
          '-v',
          '${manager.generatedStateDir}:$containerGeneratedStatePath:rw',
          '-v',
          '/tmp/data/artifacts:$containerArtifactsPath:rw',
          '-e',
          'ANTHROPIC_BASE_URL=${manager.providerBridgeUrl}',
          'dartclaw-agent:latest',
          'sleep',
          'infinity',
        ]),
      );
    });

    test('start chowns both per-authority host mount dirs to the image uid (G-HIGH-5)', () async {
      // Native Linux passes bind-mount ownership through verbatim, so the
      // generated-state and artifacts mounts must be owned by the image's
      // uid-1000 `dartclaw` user or the container cannot read/write its own
      // state. Verified on a native-Linux VM: without this the writes fail with
      // permission denied; with the host dirs chowned to 1000 they succeed.
      final stateDir = Directory(p.join(Directory.systemTemp.createTempSync('cm-chown-').path, 'authority'));
      addTearDown(() {
        final parent = stateDir.parent;
        if (parent.existsSync()) parent.deleteSync(recursive: true);
      });

      final calls = <List<String>>[];
      final manager = _manager(
        generatedStateDir: stateDir.path,
        artifactsDir: '/tmp/data/artifacts',
        run: (executable, arguments) async {
          calls.add([executable, ...arguments]);
          return arguments.first == 'inspect' ? ProcessResult(1, 1, '', 'missing') : ProcessResult(1, 0, '', '');
        },
      );

      await manager.start();

      expect(calls, contains(equals(['chown', '1000:1000', stateDir.path])));
      expect(calls, contains(equals(['chown', '1000:1000', '/tmp/data/artifacts'])));
    });

    test('start creates the generated-state directory empty and owner-only', () async {
      final stateDir = Directory(p.join(Directory.systemTemp.createTempSync('cm-state-').path, 'authority'));
      addTearDown(() {
        final parent = stateDir.parent;
        if (parent.existsSync()) parent.deleteSync(recursive: true);
      });
      // Residue a previous authority could have left behind.
      stateDir.createSync(recursive: true);
      File(p.join(stateDir.path, 'stale.toml')).writeAsStringSync('leftover');

      final manager = _manager(
        generatedStateDir: stateDir.path,
        run: (executable, arguments) async =>
            arguments.first == 'inspect' ? ProcessResult(1, 1, '', 'missing') : ProcessResult(1, 0, '', ''),
      );

      await manager.start();

      expect(stateDir.existsSync(), isTrue);
      expect(stateDir.listSync(), isEmpty);
      if (!Platform.isWindows) {
        expect(stateDir.statSync().modeString(), 'rwx------');
      }
    });

    test('stop destroys the generated state along with the container', () async {
      final stateDir = Directory(p.join(Directory.systemTemp.createTempSync('cm-state-').path, 'authority'));
      addTearDown(() {
        final parent = stateDir.parent;
        if (parent.existsSync()) parent.deleteSync(recursive: true);
      });

      final manager = _manager(
        generatedStateDir: stateDir.path,
        run: (executable, arguments) async =>
            arguments.first == 'inspect' ? ProcessResult(1, 1, '', 'missing') : ProcessResult(1, 0, '', ''),
      );
      await manager.start();
      File(p.join(stateDir.path, 'config.toml')).writeAsStringSync('generated');

      await manager.stop();

      expect(stateDir.existsSync(), isFalse);
    });

    test('exposes container-loopback bridge URLs, and none for MCP without a grant', () {
      Future<ProcessResult> noDocker(String executable, List<String> arguments) async => ProcessResult(1, 0, '', '');

      expect(_manager(run: noDocker).providerBridgeUrl, 'http://127.0.0.1:8080');
      expect(_manager(run: noDocker).mcpBridgeUrl, isNull);
      expect(_manager(run: noDocker, hasMcpBridge: true).mcpBridgeUrl, 'http://127.0.0.1:8081/mcp');
    });

    test('translates a generated-state host path into its container path', () {
      final manager = _manager(
        generatedStateDir: '/host/state',
        run: (executable, arguments) async => ProcessResult(1, 0, '', ''),
      );

      expect(manager.containerPathForHostPath('/host/state'), containerGeneratedStatePath);
      expect(
        manager.containerPathForHostPath('/host/state/codex-home/config.toml'),
        '$containerGeneratedStatePath/codex-home/config.toml',
      );
    });

    test('start creates restricted container with no workspace mounts', () async {
      final calls = <List<String>>[];
      final manager = _manager(
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
          '/tmp/dartclaw-bridge:/opt/dartclaw/dartclaw-bridge:ro',
        ]),
      );
    });

    test('start rejects arbitrary mounts before invoking Docker', () async {
      final calls = <List<String>>[];
      final manager = _manager(
        config: const ContainerConfig(enabled: true, extraMounts: ['/:/project/subdir:rw']),
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

      await expectLater(
        manager.start(),
        throwsA(isA<StateError>().having((error) => error.message, 'message', contains('container.mounts'))),
      );
      expect(calls, isEmpty);
    });

    test('start rejects raw Docker arguments before invoking Docker', () async {
      final calls = <List<String>>[];
      final manager = _manager(
        config: const ContainerConfig(enabled: true, extraArgs: ['--net=host']),
        run: (executable, arguments) async {
          calls.add([executable, ...arguments]);
          return ProcessResult(0, 0, '', '');
        },
      );

      await expectLater(
        manager.start(),
        throwsA(isA<StateError>().having((error) => error.message, 'message', contains('container.extra_args'))),
      );
      expect(calls, isEmpty);
    });

    test('an execution artifacts dir is mounted read-write and translates into the container', () async {
      final calls = <List<String>>[];
      final manager = _manager(
        artifactsDir: '/tmp/data/workflows/runs/run-1/runtime-artifacts/steps/review',
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
        containsAll(['-v', '/tmp/data/workflows/runs/run-1/runtime-artifacts/steps/review:/artifacts:rw']),
      );
      expect(
        manager.containerPathForHostPath('/tmp/data/workflows/runs/run-1/runtime-artifacts/steps/review/report.md'),
        '/artifacts/report.md',
      );
    });

    test('a container without an artifacts dir mounts none', () async {
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

      expect(calls.firstWhere((call) => call[1] == 'create').join(' '), isNot(contains(containerArtifactsPath)));
    });

    test('a container that died is never recreated in place', () async {
      var running = false;
      final calls = <List<String>>[];
      final manager = _manager(
        run: (executable, arguments) async {
          calls.add([executable, ...arguments]);
          if (arguments.first == 'inspect') {
            return running ? ProcessResult(1, 0, 'true\n', '') : ProcessResult(1, 1, '', 'not running');
          }
          if (arguments.first == 'start') running = true;
          return ProcessResult(1, 0, '', '');
        },
      );

      await manager.start();
      expect(calls.where((call) => call[1] == 'create'), hasLength(1));

      // A harness restart after the container died: recreating it would leave
      // the harness pointing at bridges that died with the old one.
      running = false;
      calls.clear();
      await expectLater(
        manager.start(),
        throwsA(
          isA<ContainerAuthorityLostException>().having(
            (error) => error.message,
            'message',
            allOf(contains('no longer running'), contains('new container authority')),
          ),
        ),
      );
      expect(calls.where((call) => call[1] == 'create'), isEmpty);
      expect(calls.where((call) => call.contains('rm')), isEmpty);
    });

    test('health distinguishes running, not-running, and daemon-error (unknown)', () async {
      ContainerManager managerFor(ProcessResult inspect) => _manager(
        run: (executable, arguments) async => arguments.first == 'inspect' ? inspect : ProcessResult(1, 0, '', ''),
      );

      expect(await managerFor(ProcessResult(1, 0, 'true\n', '')).health(), ContainerHealth.running);
      expect(await managerFor(ProcessResult(1, 0, 'false\n', '')).health(), ContainerHealth.notRunning);
      expect(
        await managerFor(ProcessResult(1, 1, '', 'Error: No such object: x')).health(),
        ContainerHealth.notRunning,
      );
      // A daemon-connection failure exits non-zero exactly like a dead container
      // by exit code alone, but proves nothing — it must read as unknown.
      expect(
        await managerFor(ProcessResult(1, 1, '', 'Cannot connect to the Docker daemon at unix:///var/run/docker.sock'))
            .health(),
        ContainerHealth.unknown,
      );
    });

    test('stop throws when a failed removal cannot be confirmed (daemon unreachable)', () async {
      final manager = _manager(
        run: (executable, arguments) async {
          if (arguments.first == 'rm') return ProcessResult(1, 1, '', 'Cannot connect to the Docker daemon');
          if (arguments.first == 'inspect') return ProcessResult(1, 1, '', 'Cannot connect to the Docker daemon');
          return ProcessResult(1, 0, '', '');
        },
      );

      // An unconfirmable removal must throw, not silently return capacity while
      // the container may still be alive once the daemon recovers.
      await expectLater(
        manager.stop(),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('Failed to destroy container'))),
      );
    });

    test('stop can reclaim an unconfirmed orphan after the daemon recovers', () async {
      var daemonAvailable = false;
      var removals = 0;
      final manager = _manager(
        run: (executable, arguments) async {
          if (arguments.first == 'rm') {
            removals++;
            return daemonAvailable
                ? ProcessResult(1, 0, '', '')
                : ProcessResult(1, 1, '', 'Cannot connect to the Docker daemon');
          }
          if (arguments.first == 'inspect' && !daemonAvailable) {
            return ProcessResult(1, 1, '', 'Cannot connect to the Docker daemon');
          }
          return ProcessResult(1, 0, '', '');
        },
      );

      await expectLater(manager.stop(), throwsStateError);
      daemonAvailable = true;
      await manager.stop();

      expect(removals, 2);
    });

    test('start rejects local project mounts outside the allowlist', () async {
      final manager = _manager(
        workspaceMounts: const ['/tmp/other:/projects/live:ro'],
        localPathAllowlist: const ['/tmp/allowed'],
        run: (executable, arguments) async => ProcessResult(1, 0, '', ''),
      );

      await expectLater(manager.start(), throwsA(isA<StateError>()));
    });

    test('start accepts local project mounts within the allowlist', () async {
      final calls = <List<String>>[];
      final manager = _manager(
        workspaceMounts: const ['/tmp/allowed/live:/projects/live:ro'],
        localPathAllowlist: const ['/tmp/allowed'],
        run: (executable, arguments) async {
          calls.add([executable, ...arguments]);
          if (arguments.first == 'inspect') {
            return ProcessResult(1, 1, '', 'missing');
          }
          return ProcessResult(1, 0, '', '');
        },
      );

      await manager.start();

      expect(calls.any((call) => call[1] == 'create'), isTrue);
    });

    test('containerPathForHostPath resolves real-path descendants under symlinked mount roots', () async {
      final tempDir = Directory.systemTemp.createTempSync('container_manager_symlink_mount_test_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });
      final realRoot = Directory(p.join(tempDir.path, 'real-root'))..createSync(recursive: true);
      final aliasRoot = p.join(tempDir.path, 'alias-root');
      Link(aliasRoot).createSync(realRoot.path);

      final manager = _manager(
        workspaceMounts: ['$aliasRoot:/projects/alias:ro'],
        run: (executable, arguments) async => ProcessResult(1, 0, '', ''),
      );

      final translated = manager.containerPathForHostPath(p.join(realRoot.path, 'new-checkout'));

      expect(translated, '/projects/alias/new-checkout');
    });

    test('defaults buildContextDir to current working directory', () {
      final manager = _manager(
        buildContextDir: null,
        run: (executable, arguments) async => ProcessResult(1, 0, '', ''),
      );

      expect(manager.buildContextDir, Directory.current.path);
    });

    test('stop reports a container it could not destroy', () async {
      final manager = _manager(
        run: (executable, arguments) async {
          if (arguments.first == 'rm') return ProcessResult(1, 1, '', 'device or resource busy');
          if (arguments.first == 'inspect') return ProcessResult(1, 0, 'true\n', '');
          return ProcessResult(1, 0, '', '');
        },
      );

      // A surviving container keeps its authority's mounts and root process,
      // and its per-authority name is never reused, so silence would strand it.
      await expectLater(
        manager.stop(),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('Failed to destroy container'))),
      );
    });

    test('stop stays quiet when removal raced an already-gone container', () async {
      final manager = _manager(
        run: (executable, arguments) async {
          if (arguments.first == 'rm') return ProcessResult(1, 1, '', 'No such container');
          if (arguments.first == 'inspect') return ProcessResult(1, 1, '', 'No such container');
          return ProcessResult(1, 0, '', '');
        },
      );

      await manager.stop();
    });

    test('startBridge execs the delivered bridge for the requested surface and port', () async {
      final started = <List<String>>[];
      final manager = _manager(
        run: (executable, arguments) async => ProcessResult(1, 0, '', ''),
        start:
            (
              executable,
              arguments, {
              String? workingDirectory,
              Map<String, String>? environment,
              bool includeParentEnvironment = true,
            }) async {
              started.add([executable, ...arguments]);
              return FakeProcess();
            },
      );

      await manager.startBridge(BridgeSurface.mcp, 8081);

      expect(started.single, [
        'docker',
        'exec',
        '-i',
        workspaceContainerName,
        '/opt/dartclaw/dartclaw-bridge',
        '--surface=mcp',
        '--port=8081',
      ]);
    });

    test('startBridge refuses when no bridge binary was delivered', () async {
      final manager = ContainerManager(
        config: const ContainerConfig(enabled: true),
        containerName: workspaceContainerName,
        profileId: 'workspace',
        workspaceMounts: const [],
        generatedStateDir: '/tmp/dartclaw-state',
        runCommand: (executable, arguments) async => ProcessResult(1, 0, '', ''),
      );

      await expectLater(
        manager.startBridge(BridgeSurface.provider, 8080),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('no bridge binary'))),
      );
    });

    test('serverArchitecture maps the docker engine arch onto a shipped bridge variant', () async {
      expect(await _manager(run: (_, _) async => ProcessResult(1, 0, 'aarch64\n', '')).serverArchitecture(), 'arm64');
      expect(await _manager(run: (_, _) async => ProcessResult(1, 0, 'amd64\n', '')).serverArchitecture(), 'x64');
      expect(await _manager(run: (_, _) async => ProcessResult(1, 0, 'riscv64\n', '')).serverArchitecture(), isNull);
      expect(await _manager(run: (_, _) async => ProcessResult(1, 1, '', 'boom')).serverArchitecture(), isNull);
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

    test('exec passes env vars through docker exec', () async {
      List<String>? capturedArgs;
      bool? capturedIncludeParentEnvironment;
      final manager = _manager(
        run: (executable, arguments) async => ProcessResult(1, 0, '', ''),
        start: (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async {
          capturedArgs = [executable, ...arguments];
          capturedIncludeParentEnvironment = includeParentEnvironment;
          return FakeProcess();
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
          return FakeProcess();
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
  List<String> localPathAllowlist = const [],
  String? buildContextDir = '/tmp/project',
  String workingDir = '/project',
  String generatedStateDir = '/tmp/dartclaw-state',
  String? artifactsDir,
  bool hasMcpBridge = false,
}) {
  return ContainerManager(
    config: config,
    containerName: containerName,
    profileId: profileId,
    workspaceMounts: workspaceMounts,
    generatedStateDir: generatedStateDir,
    artifactsDir: artifactsDir,
    hasMcpBridge: hasMcpBridge,
    localPathAllowlist: localPathAllowlist,
    bridgeBinaryPath: '/tmp/dartclaw-bridge',
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
  return FakeProcess();
}
