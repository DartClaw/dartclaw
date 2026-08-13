@Tags(['integration', 'slow'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart'
    show
        CodexEnvironment,
        containerClaudeExecutable,
        containerCodexExecutable,
        containerExecutableRuns,
        containerGeneratedStatePath;
import 'package:dartclaw_models/dartclaw_models.dart' show ContainerConfig;
import 'package:dartclaw_server/src/container/container_manager.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'container_integration_support.dart';

/// Proves Claude/Codex container parity against a real Docker engine.
///
/// Configuration labels are not evidence here: every assertion observes the
/// running container – the process namespace it actually joined, the mounts the
/// engine actually attached, and the files the container can actually read.
///
/// The shipped agent image is deliberately the subject: this suite is what
/// proves both packaged provider CLIs run and that the pinned, checksum-verified
/// Codex install produced a working binary.
///
/// The contract is identical on Linux Docker and Docker Desktop; a single run
/// proves the executing platform, and the 0.24 release gate records both.
void main() {
  late String checkoutRoot;
  late Directory dataDir;

  setUpAll(() async {
    if (!await dockerAvailable()) {
      throw StateError('Docker is required for the container provider parity suite');
    }
    checkoutRoot = await repoRoot();
    await ensureAgentImage(checkoutRoot);
  });

  setUp(() => dataDir = Directory.systemTemp.createTempSync('parity_integration_'));

  tearDown(() {
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
  });

  Future<ContainerManager> startContainer({String profile = 'workspace', bool hasMcpBridge = false}) async {
    final name = 'dartclaw-parity-${DateTime.now().microsecondsSinceEpoch}';
    // The workspace profile mounts a project; the restricted one deliberately
    // mounts nothing and works out of the container's own tmpfs.
    final workspace = Directory(p.join(dataDir.path, 'workspaces', name))..createSync(recursive: true);
    final manager = ContainerManager(
      config: const ContainerConfig(enabled: true, image: agentProbeImage),
      containerName: name,
      profileId: profile,
      workspaceMounts: profile == 'restricted' ? const [] : ['${workspace.path}:/project:rw'],
      generatedStateDir: p.join(dataDir.path, 'containers', name),
      hasMcpBridge: hasMcpBridge,
      buildContextDir: checkoutRoot,
      workingDir: profile == 'restricted' ? '/tmp' : '/project',
    );
    addTearDown(() async {
      try {
        await manager.stop();
      } catch (_) {} // Teardown is best-effort; the assertions already ran.
    });
    await manager.start();
    return manager;
  }

  group('packaged provider CLIs', () {
    test('both providers run inside the shipped image', () async {
      final manager = await startContainer();

      // The same probe admission uses. Codex passing here is what proves the
      // pinned, checksum-verified install produced a runnable binary.
      expect(await containerExecutableRuns(manager, containerClaudeExecutable), isTrue);
      expect(await containerExecutableRuns(manager, containerCodexExecutable), isTrue);
    });

    test('an absent binary is detected rather than assumed present', () async {
      final manager = await startContainer();

      expect(await containerExecutableRuns(manager, '/home/dartclaw/.local/bin/not-installed'), isFalse);
    });

    test('the image ships the pinned Codex version, not a floating one', () async {
      final manager = await startContainer();

      final version = await execOutput(manager, [containerCodexExecutable, '--version']);

      expect(version.trim(), isNotEmpty);
      expect(version, contains(_pinnedCodexVersion(checkoutRoot)));
    });
  });

  group('effective placement', () {
    test('a containerized process joins the container namespace, not the host', () async {
      final manager = await startContainer();

      final containerCgroup = await execOutput(manager, ['cat', '/proc/self/cgroup']);
      final containerHostname = (await execOutput(manager, ['cat', '/etc/hostname'])).trim();
      final hostHostname = Platform.localHostname;

      // PID 1 in the container is the image's own `sleep infinity`, which can
      // only be true inside a separate PID namespace.
      expect(await execOutput(manager, ['cat', '/proc/1/comm']), contains('sleep'));
      expect(containerHostname, isNot(hostHostname));
      expect(containerCgroup, isNotEmpty);
    });

    test('the working directory resolves inside the selected profile container', () async {
      final workspace = await startContainer();
      final restricted = await startContainer(profile: 'restricted');

      expect((await execOutput(workspace, ['pwd'])).trim(), '/project');
      expect((await execOutput(restricted, ['pwd'])).trim(), '/tmp');
    });

    test('the container keeps network:none with no extra attachment', () async {
      final manager = await startContainer();

      final networks = await _inspect(manager.containerName, '{{json .NetworkSettings.Networks}}');
      expect(networks, contains('none'));
      expect(networks, isNot(contains('bridge')));

      // And the boundary is real, not just labelled.
      final resolved = await Process.run('docker', [
        'exec',
        manager.containerName,
        'sh',
        '-c',
        'getent hosts api.openai.com || echo NO-DNS',
      ]);
      expect(resolved.stdout as String, contains('NO-DNS'));
    });
  });

  group('generated state and host homes', () {
    test('the workspace and its generated state are the only host objects mounted', () async {
      final manager = await startContainer();

      final mounts = (jsonDecode(await _inspect(manager.containerName, '{{json .Mounts}}')) as List<Object?>)
          .cast<Map<String, Object?>>();

      // Bounding the whole set is the point: no host provider home is mounted
      // in. The image's own installer state at `/home/dartclaw/.claude.json` is
      // baked into the layer and is not host login material.
      final byDestination = {for (final mount in mounts) mount['Destination'] as String: mount};
      expect(byDestination.keys, unorderedEquals(['/project', containerGeneratedStatePath]));
      expect(byDestination['/project']!['RW'], isTrue);
      expect(byDestination[containerGeneratedStatePath]!['RW'], isTrue);
      expect(
        await execOutput(manager, ['cat', '/home/dartclaw/.claude.json']),
        allOf(isNot(contains('oauthAccount')), isNot(contains('accessToken'))),
      );
      // No host Codex home was mounted either, so the container starts without
      // one and only ever sees a generated auth-clean home.
      expect(
        await execOutput(manager, ['sh', '-c', 'test -e /home/dartclaw/.codex && echo YES || echo NO']),
        contains('NO'),
      );
    });

    test('an auth-clean Codex home written host-side is what the container reads', () async {
      final manager = await startContainer();
      final hostHome = p.join(manager.generatedStateDir, 'codex-home');
      final environment = CodexEnvironment.containerAuthClean(
        developerInstructions: 'be careful',
        hostHomePath: hostHome,
        containerHomePath: manager.containerPathForHostPath(hostHome)!,
        gatewayBaseUrl: '${manager.providerBridgeUrl}/v1',
        nativeWebSearch: false,
      );
      await environment.setup();

      final containerHome = environment.environmentOverrides()['CODEX_HOME']!;
      final listed = await execOutput(manager, ['ls', '-A', containerHome]);
      final config = await execOutput(manager, ['cat', p.posix.join(containerHome, 'config.toml')]);

      expect(listed.trim(), 'config.toml');
      expect(config, contains('requires_openai_auth = false'));
      expect(config, contains('base_url = "http://127.0.0.1:8080/v1"'));
      expect(config, contains('web_search = false'));
    });

    test('releasing the container destroys its generated state', () async {
      final manager = await startContainer();
      final stateDir = Directory(manager.generatedStateDir);
      File(p.join(stateDir.path, 'config.toml')).writeAsStringSync('generated');
      expect(stateDir.existsSync(), isTrue);

      await manager.stop();

      expect(stateDir.existsSync(), isFalse);
      expect(await containerExists(manager.containerName), isFalse);
    });
  });

  test('no host credential is readable from inside the container', () async {
    final manager = await startContainer();

    final environment = await execOutput(manager, ['env']);
    final processEnviron = await execOutput(manager, ['sh', '-c', 'tr "\\0" "\\n" < /proc/1/environ']);

    // Secret-absence is proved with planted sentinels in the harness unit
    // suites, which control the host environment. What only a real container
    // can show is that `docker exec` grants no inherited host environment at
    // all, so no credential variable exists here to leak in the first place.
    for (final surface in [environment, processEnviron]) {
      expect(surface, isNot(contains('OPENAI_API_KEY')));
      expect(surface, isNot(contains('CLAUDE_CODE_OAUTH_TOKEN')));
    }
    // The one provider-facing variable is the loopback bridge, not a credential.
    expect(environment, contains('ANTHROPIC_BASE_URL=http://127.0.0.1:8080'));
  });
}

/// The exact Codex release `docker/Dockerfile` pins.
String _pinnedCodexVersion(String repoRoot) {
  final dockerfile = File(p.join(repoRoot, 'docker', 'Dockerfile')).readAsStringSync();
  final match = RegExp(r'ARG CODEX_VERSION=(\S+)').firstMatch(dockerfile);
  if (match == null) throw StateError('docker/Dockerfile pins no CODEX_VERSION');
  return match.group(1)!;
}

Future<String> _inspect(String containerName, String format) async {
  final result = await Process.run('docker', ['inspect', '--format', format, containerName]);
  return result.stdout as String;
}
