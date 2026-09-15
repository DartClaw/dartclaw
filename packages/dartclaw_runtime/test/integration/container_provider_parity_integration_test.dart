@Tags(['integration', 'slow'])
library;

import 'dart:async';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart'
    show
        CodexEnvironment,
        ContainerExecutor,
        HarnessFactory,
        HarnessFactoryConfig,
        SubscriptionCredentialStore,
        containerClaudeExecutable,
        containerCodexExecutable,
        containerExecutableRuns,
        containerGeneratedStatePath;
import 'package:dartclaw_runtime/src/runtime/harness_wiring.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'container_integration_support.dart';
import '../runtime/harness_wiring_fixture.dart';

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
    await ensureBridgeBinary(checkoutRoot);
  });

  setUp(() => dataDir = Directory.systemTemp.createTempSync('parity_integration_'));

  tearDown(() {
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
  });

  /// Builds an unstarted manager, so a test can observe what starting it — or
  /// being refused before it starts — leaves behind.
  ContainerManager buildContainer({String profile = 'workspace', bool hasMcpBridge = false, String? name}) {
    final containerName = name ?? 'dartclaw-parity-${DateTime.now().microsecondsSinceEpoch}';
    // The workspace profile mounts a project; the restricted one deliberately
    // mounts nothing and works out of the container's own tmpfs.
    final workspace = Directory(p.join(dataDir.path, 'workspaces', containerName))..createSync(recursive: true);
    final manager = ContainerManager(
      ownerLabel: ContainerManager.ownerLabel(dataDir.path),
      config: const ContainerConfig(enabled: true, image: agentProbeImage),
      containerName: containerName,
      profileId: profile,
      workspaceMounts: profile == 'restricted' ? const [] : ['${workspace.path}:/project:rw'],
      generatedStateDir: p.join(dataDir.path, 'containers', containerName),
      hasMcpBridge: hasMcpBridge,
      buildContextDir: checkoutRoot,
      workingDir: profile == 'restricted' ? '/tmp' : '/project',
    );
    addTearDown(() async {
      try {
        await manager.stop();
      } catch (_) {} // Teardown is best-effort; the assertions already ran.
    });
    return manager;
  }

  Future<ContainerManager> startContainer({String profile = 'workspace', bool hasMcpBridge = false}) async {
    final manager = buildContainer(profile: profile, hasMcpBridge: hasMcpBridge);
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

    test('a configured agent container mounts only its pinned workspace', () async {
      final agentA = Directory(p.join(dataDir.path, 'agents', 'a'))..createSync(recursive: true);
      final agentB = Directory(p.join(dataDir.path, 'agents', 'b'))..createSync();
      File(p.join(agentA.path, 'identity.txt')).writeAsStringSync('AGENT-A-ONLY');
      File(p.join(agentB.path, 'identity.txt')).writeAsStringSync('AGENT-B-ONLY');
      final manager = ContainerManager(
        ownerLabel: ContainerManager.ownerLabel(dataDir.path),
        config: const ContainerConfig(enabled: true, image: agentProbeImage),
        containerName: 'dartclaw-agent-workspace-${DateTime.now().microsecondsSinceEpoch}',
        profileId: 'workspace',
        workspaceMounts: SecurityProfile.workspace(workspaceDir: agentA.path, projectDir: null).workspaceMounts,
        generatedStateDir: p.join(dataDir.path, 'containers', 'agent-a'),
        hasMcpBridge: false,
        buildContextDir: checkoutRoot,
        workingDir: '/workspace',
      );
      addTearDown(() async {
        try {
          await manager.stop();
        } catch (_) {}
      });

      await manager.start();
      final mounts = (jsonDecode(await _inspect(manager.containerName, '{{json .Mounts}}')) as List<Object?>)
          .cast<Map<String, Object?>>();
      final destinations = {for (final mount in mounts) mount['Destination'] as String};

      expect((await execOutput(manager, ['pwd'])).trim(), '/workspace');
      expect(await execOutput(manager, ['cat', '/workspace/identity.txt']), contains('AGENT-A-ONLY'));
      expect(destinations, contains('/workspace'));
      expect(destinations, isNot(contains(agentB.path)));
      expect(
        await execOutput(manager, ['sh', '-c', 'find /workspace -type f -exec cat {} \\;']),
        isNot(contains('AGENT-B-ONLY')),
      );
    });

    test('production acquisition pins each workspace and Codex discovers only its agent skill', () async {
      final ownerDir = await createImageOwnedWorkspace(p.join(dataDir.path, 'workspace'));
      final agentADir = await createImageOwnedWorkspace(p.join(dataDir.path, 'agents', 'a'));
      final agentBDir = await createImageOwnedWorkspace(p.join(dataDir.path, 'agents', 'b'));
      final authorizedProject = Directory(p.join(dataDir.path, 'projects', 'authorized'))..createSync(recursive: true);
      final unrelatedProject = Directory(p.join(dataDir.path, 'projects', 'unrelated'))..createSync();
      File(p.join(authorizedProject.path, 'authority-marker.txt')).writeAsStringSync('AUTHORIZED-PROJECT-ONLY');
      File(p.join(unrelatedProject.path, 'unrelated-marker.txt')).writeAsStringSync('UNRELATED-PROJECT-DENIED');
      await writeWorkspacePromptFiles(ownerDir.path);
      await writeWorkspacePromptFiles(agentADir.path);
      await writeWorkspacePromptFiles(agentBDir.path);
      _writeSkill(agentADir, '.agents', 'agent-a-native-skill');
      _writeSkill(agentBDir, '.agents', 'agent-b-native-skill');

      final workspaceA = AgentWorkspace(agentId: 'a', directory: agentADir.path);
      final workspaceB = AgentWorkspace(agentId: 'b', directory: agentBDir.path);
      Never unexpectedExit(int code) => throw StateError('Unexpected exit($code) in container composition proof');
      final config = DartclawConfig(
        server: ServerConfig(dataDir: dataDir.path, claudeExecutable: Platform.resolvedExecutable),
        container: const ContainerConfig(enabled: true, image: agentProbeImage),
        security: const SecurityConfig(contentGuardFailOpen: true),
        agent: AgentConfig(
          provider: 'claude',
          execution: ExecutionMode.host,
          definitions: [
            AgentDefinition(
              id: 'a',
              description: 'A',
              prompt: 'A',
              execution: ExecutionMode.container,
              workspace: workspaceA,
            ),
            AgentDefinition(
              id: 'b',
              description: 'B',
              prompt: 'B',
              execution: ExecutionMode.container,
              workspace: workspaceB,
            ),
            const AgentDefinition(id: 'c', description: 'C', prompt: 'C', execution: ExecutionMode.container),
          ],
        ),
        providers: ProvidersConfig(
          entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 4)},
        ),
        credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'integration-key')}),
        gateway: const GatewayConfig(authMode: 'none'),
        projects: ProjectConfig(
          definitions: {'unrelated': ProjectDefinition(id: 'unrelated', localPath: unrelatedProject.path)},
          localPathAllowlist: [unrelatedProject.path],
        ),
      );
      final eventBus = EventBus();
      final storage = await wireTestStorage(config: config, eventBus: eventBus, exitFn: unexpectedExit);
      final security = await wireTestSecurity(
        config: config,
        dataDir: dataDir.path,
        eventBus: eventBus,
        exitFn: unexpectedExit,
      );
      final harnessConfigs = <HarnessFactoryConfig>[];
      final factory = HarnessFactory()
        ..register('claude', (factoryConfig) {
          harnessConfigs.add(factoryConfig);
          return FakeAgentHarness(promptStrategy: PromptStrategy.append, supportsNoWorkTools: true);
        });
      final wiring = HarnessWiring(
        config: config,
        dataDir: dataDir.path,
        port: 0,
        harnessFactory: factory,
        exitFn: unexpectedExit,
        storage: storage,
        security: security,
        messageRedactor: MessageRedactor(),
        eventBus: eventBus,
      );
      await wiring.wire(turnManagerGetter: () => null);
      await wiring.startPrimary();
      addTearDown(() async {
        await wiring.executions.dispose();
        await security.dispose();
        await storage.dispose();
      });

      Future<({ExecutionLease lease, HarnessFactoryConfig config})> acquire({
        required Session session,
        required String? agentId,
        required AgentWorkspace? workspace,
        String? directory,
      }) async {
        final before = harnessConfigs.length;
        final lease = await wiring.executions.acquire(
          ExecutionRequest(
            surface: agentId == null ? ExecutionSurface.task : ExecutionSurface.logicalAgent,
            providerId: 'claude',
            policy: const ExecutionPolicy.container('workspace'),
            sessionId: session.id,
            logicalAgentId: agentId,
            workspace: workspace,
            directory: directory,
            allowedTools: const [],
          ),
        );
        expect(lease, isNotNull);
        expect(harnessConfigs, hasLength(before + 1), reason: 'a different execution principal reused a worker');
        return (lease: lease!, config: harnessConfigs.last);
      }

      Future<Map<String, Map<String, Object?>>> mounts(HarnessFactoryConfig config) async {
        final manager = config.containerManager! as ContainerManager;
        final decoded = (jsonDecode(await _inspect(manager.containerName, '{{json .Mounts}}')) as List<Object?>)
            .cast<Map<String, Object?>>();
        return {for (final mount in decoded) mount['Destination']! as String: mount};
      }

      final ownerSession = await storage.sessions.createSession(type: SessionType.task);
      final aSession = await storage.sessions.getOrCreateByKey(
        SessionKey.logicalAgentSession(agentId: 'a', conversationId: 'docker-a'),
        type: SessionType.logicalAgent,
        workspace: workspaceA,
      );
      final bSession = await storage.sessions.getOrCreateByKey(
        SessionKey.logicalAgentSession(agentId: 'b', conversationId: 'docker-b'),
        type: SessionType.logicalAgent,
        workspace: workspaceB,
      );
      final cSession = await storage.sessions.getOrCreateByKey(
        SessionKey.logicalAgentSession(agentId: 'c', conversationId: 'docker-c'),
        type: SessionType.logicalAgent,
      );
      final owner = await acquire(session: ownerSession, agentId: null, workspace: null);
      final ownerMounts = await mounts(owner.config);
      await owner.lease.release();
      final a = await acquire(
        session: aSession,
        agentId: 'a',
        workspace: workspaceA,
        directory: authorizedProject.path,
      );
      final aMounts = await mounts(a.config);
      final aContainer = a.config.containerManager! as ContainerManager;
      final codexVersion = (await execOutput(aContainer, [containerCodexExecutable, '--version'])).trim();
      expect(codexVersion, contains(_pinnedCodexVersion(checkoutRoot)), reason: 'actual image version: $codexVersion');
      final nativeSkills = await _codexSkillsList(aContainer, cwd: '/project');
      final authorizedContent = await execOutput(aContainer, ['cat', '/project/authority-marker.txt']);
      final visibleContent = await execOutput(aContainer, [
        'sh',
        '-c',
        'find /workspace /project -type f -exec cat {} \\;',
      ]);
      await a.lease.release();
      final b = await acquire(session: bSession, agentId: 'b', workspace: workspaceB);
      final bMounts = await mounts(b.config);
      await b.lease.release();
      final c = await acquire(session: cSession, agentId: 'c', workspace: null);
      final cMounts = await mounts(c.config);
      await c.lease.release();
      expect(_mountSourceMatches(ownerMounts['/workspace']!['Source']! as String, ownerDir.path), isTrue);
      expect(_mountSourceMatches(aMounts['/workspace']!['Source']! as String, agentADir.path), isTrue);
      expect(_mountSourceMatches(bMounts['/workspace']!['Source']! as String, agentBDir.path), isTrue);
      expect(cMounts, isNot(contains('/workspace')));
      expect(_mountSourceMatches(aMounts['/project']!['Source']! as String, authorizedProject.path), isTrue);
      expect(aMounts, isNot(contains('/projects')));
      expect(bMounts, isNot(anyOf(contains('/project'), contains('/projects'))));
      expect(
        aMounts.values.any((mount) => _mountSourceMatches(mount['Source']! as String, unrelatedProject.path)),
        isFalse,
      );
      expect(aMounts.values.any((mount) => _mountSourceMatches(mount['Source']! as String, checkoutRoot)), isFalse);
      expect(authorizedContent, contains('AUTHORIZED-PROJECT-ONLY'));
      expect(visibleContent, isNot(contains('UNRELATED-PROJECT-DENIED')));
      for (final entry in [owner.config, c.config]) {
        final manager = entry.containerManager!;
        expect(manager.containerPathForHostPath(checkoutRoot), '/project');
        expect(entry.cwd, checkoutRoot);
      }
      expect(a.config.containerManager!.containerPathForHostPath(authorizedProject.path), '/project');
      expect(a.config.containerManager!.containerPathForHostPath(checkoutRoot), isNull);
      expect(b.config.containerManager!.containerPathForHostPath(checkoutRoot), isNull);
      expect(a.config.skillWorkspaceDir, agentADir.path);
      expect(a.config.containerManager!.containerPathForHostPath(a.config.skillWorkspaceDir!), '/workspace');
      expect(b.config.skillWorkspaceDir, agentBDir.path);
      expect(c.config.skillWorkspaceDir, isNull);
      expect(a.config.declaredWritableRoots, contains(agentADir.path));
      expect(b.config.declaredWritableRoots, contains(agentBDir.path));
      expect(c.config.declaredWritableRoots, isNot(contains(ownerDir.path)));
      expect(aMounts.values.any((mount) => _mountSourceMatches(mount['Source']! as String, agentBDir.path)), isFalse);
      expect(bMounts.values.any((mount) => _mountSourceMatches(mount['Source']! as String, agentADir.path)), isFalse);
      final stateSources = [
        ownerMounts[containerGeneratedStatePath]!['Source'],
        aMounts[containerGeneratedStatePath]!['Source'],
        bMounts[containerGeneratedStatePath]!['Source'],
        cMounts[containerGeneratedStatePath]!['Source'],
      ];
      expect(stateSources.toSet(), hasLength(4));

      final encodedSkills = jsonEncode(nativeSkills);
      expect(encodedSkills, contains('agent-a-native-skill'));
      expect(encodedSkills, isNot(contains('agent-b-native-skill')));
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
    // The dedicated stores are written under this run's data dir — the same
    // parent that holds the workspace and generated-state directories the
    // container *does* get. Absence of the variable names alone would pass
    // against a container that never had a credential to lose; planting the
    // real values here is what makes the sweep able to fail, and what turns
    // "no host provider home is mounted" into an observed fact.
    final store = openSentinelCredentialStore(dataDir);
    writeSentinelClaudeCredential(store);
    writeSentinelCodexCredential(store);
    expect(
      File(store.codexAuthPath).readAsStringSync(),
      allOf(contains(sentinelCodexAccessToken), contains(sentinelCodexRefreshToken)),
      reason: 'the fixture planted nothing, so the sweep below would prove nothing',
    );

    final manager = await startContainer();

    final environment = await _readContainer(manager, ['env'], 'the container environment');
    final processEnviron = await _readContainer(manager, [
      'sh',
      '-c',
      'tr "\\0" "\\n" < /proc/1/environ',
    ], 'PID 1 environ');
    // `grep -r`, never `-l`: the list form prints only file *paths*, so a
    // sentinel-absence assertion over it could never fail.
    final readable = <String, String>{};
    for (final sentinel in subscriptionSentinels) {
      readable['container filesystem ($sentinel)'] = await _readContainer(manager, [
        'sh',
        '-c',
        'grep -r "$sentinel" /tmp /home/dartclaw /project 2>/dev/null || true',
      ], 'the container filesystem');
    }

    expectSentinelsAbsent({
      'container env': environment,
      '/proc/1/environ': processEnviron,
      'docker inspect': await _inspect(manager.containerName, '{{json .}}'),
      ...readable,
    }, subscriptionSentinels);

    // `docker exec` grants no inherited host environment at all, so the
    // credential variables have no value to carry in the first place.
    for (final surface in [environment, processEnviron]) {
      expect(surface, isNot(contains('OPENAI_API_KEY')));
      expect(surface, isNot(contains('CLAUDE_CODE_OAUTH_TOKEN')));
    }
    // The one provider-facing variable is the loopback bridge, not a credential.
    expect(environment, contains('ANTHROPIC_BASE_URL=http://127.0.0.1:8080'));
  });

  group('fail-closed admission', () {
    /// Registers [manager]'s principal the way production does — registration
    /// first, container second — so a refusal is observably artifact-free.
    Future<void> registerThenStart(HostGateway gateway, ContainerManager manager) async {
      gateway.register(
        principal: GatewayPrincipal(
          sessionId: 'admission-${manager.containerName}',
          providerId: 'codex',
          policy: const ExecutionPolicy.container('workspace'),
        ),
      );
      await manager.start();
    }

    test('a refused registration leaves no container, no generated state, and no authority', () async {
      final store = openSentinelCredentialStore(dataDir);
      // `providers.codex.auth: subscription` with nothing stored: the forced
      // selection cannot be satisfied, so the host has no credential to mediate
      // with and must refuse before anything is created.
      final gateway = _codexGateway(store);
      final manager = buildContainer(name: 'dartclaw-refused-${DateTime.now().microsecondsSinceEpoch}');

      // The reason is pinned, not just the type: `register` throws `StateError`
      // for a disposed gateway and a missing adapter too, and `start()` throws
      // its own — any of which would leave the absence assertions below green
      // while proving nothing about the credential gate.
      await expectLater(
        registerThenStart(gateway, manager),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(contains('no host-held credential'), contains('codex login'), contains('auth: subscription')),
          ),
        ),
      );

      expect(await containerExists(manager.containerName), isFalse, reason: 'a refused execution created a container');
      expect(
        Directory(manager.generatedStateDir).existsSync(),
        isFalse,
        reason: 'a refused execution created its generated-state directory',
      );
      expect(gateway.liveAuthorityCount, 0);
    });

    test('the same fixture with a stored credential is admitted and does create both', () async {
      // The discriminating half: without it, the absence assertions above would
      // hold for a fixture too broken to create anything either way.
      final store = openSentinelCredentialStore(dataDir);
      writeSentinelCodexCredential(store);
      final gateway = _codexGateway(store);
      final manager = buildContainer(name: 'dartclaw-admitted-${DateTime.now().microsecondsSinceEpoch}');

      await registerThenStart(gateway, manager);

      expect(await containerExists(manager.containerName), isTrue);
      expect(Directory(manager.generatedStateDir).existsSync(), isTrue);
      expect(gateway.liveAuthorityCount, 1);
    });
  });
}

bool _mountSourceMatches(String dockerSource, String hostPath) {
  final absoluteHost = p.absolute(hostPath);
  final hostVariants = {
    absoluteHost,
    Directory(hostPath).resolveSymbolicLinksSync(),
    if (absoluteHost == '/var' || absoluteHost.startsWith('/var/')) '/private$absoluteHost',
  };
  return hostVariants.any((path) => p.equals(dockerSource, path) || p.equals(dockerSource, '/host_mnt$path'));
}

void _writeSkill(Directory workspace, String providerRoot, String name) {
  final directory = Directory(p.join(workspace.path, providerRoot, 'skills', name))..createSync(recursive: true);
  File(
    p.join(directory.path, 'SKILL.md'),
  ).writeAsStringSync('---\nname: $name\ndescription: Unique $name fixture.\n---\n\nUse only for the $name proof.\n');
}

Future<Map<String, dynamic>> _codexSkillsList(ContainerExecutor container, {required String cwd}) async {
  const codexHome = '/tmp/dartclaw-workspace-skill-probe-home';
  final prepareHome = await container.exec(['mkdir', '-p', codexHome], workingDirectory: '/tmp');
  final prepareExit = await prepareHome.exitCode;
  if (prepareExit != 0) throw StateError('Could not create the native Codex proof home (exit $prepareExit)');
  final process = await container.exec(
    [containerCodexExecutable, 'app-server'],
    env: const {'CODEX_HOME': codexHome},
    workingDirectory: cwd,
  );
  final stderr = StringBuffer();
  final stderrSubscription = process.stderr.transform(utf8.decoder).listen(stderr.write);
  final lines = StreamIterator(process.stdout.transform(utf8.decoder).transform(const LineSplitter()));
  final sink = process.stdin;

  void send(Map<String, dynamic> message) => sink.writeln(jsonEncode(message));
  Future<Map<String, dynamic>> response(int id) async {
    while (await lines.moveNext()) {
      final value = jsonDecode(lines.current);
      if (value is Map<String, dynamic> && value['id'] == id) return value;
    }
    throw StateError('Codex app-server exited before response $id: $stderr');
  }

  try {
    send({
      'id': 1,
      'method': 'initialize',
      'params': {
        'clientInfo': {'name': 'dartclaw-workspace-skill-proof', 'version': '1'},
      },
    });
    final initialize = await response(1).timeout(const Duration(seconds: 10));
    if (initialize['error'] != null) throw StateError('Codex initialize failed: ${initialize['error']}');
    send({'method': 'initialized', 'params': {}});
    send({
      'id': 2,
      'method': 'skills/extraRoots/set',
      'params': {
        'extraRoots': ['/workspace/.agents/skills'],
      },
    });
    final setRoots = await response(2).timeout(const Duration(seconds: 10));
    if (setRoots['error'] != null) throw StateError('Codex skills/extraRoots/set failed: ${setRoots['error']}');
    send({
      'id': 3,
      'method': 'skills/list',
      'params': {
        'cwds': [cwd],
        'forceReload': true,
      },
    });
    final listed = await response(3).timeout(const Duration(seconds: 10));
    if (listed['error'] != null) throw StateError('Codex skills/list failed: ${listed['error']}');
    return listed;
  } finally {
    await sink.close();
    process.kill(ProcessSignal.sigterm);
    await process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    await lines.cancel();
    await stderrSubscription.cancel();
  }
}

/// A gateway whose Codex adapter resolves through [store] under a forced
/// `providers.codex.auth: subscription`, exactly as the deployment wires it.
HostGateway _codexGateway(SubscriptionCredentialStore store) {
  final registry = CredentialRegistry(
    credentials: const CredentialsConfig(),
    env: const {},
    providers: const ProvidersConfig(
      entries: {'codex': ProviderEntry(executable: 'codex', auth: ProviderAuth.subscription)},
    ),
    subscriptions: store.readAll(),
  );
  return HostGateway(
    providerAdapters: {
      'codex': OpenAiResponsesAdapter(credential: ProviderCredentialSource(() => registry.resolve('codex'))),
    },
  );
}

/// Reads a container surface, failing loudly when it cannot be read at all.
///
/// A dead container returns empty stdout, which would otherwise satisfy every
/// absence assertion built on it.
Future<String> _readContainer(ContainerManager manager, List<String> command, String label) async {
  final result = await Process.run('docker', ['exec', manager.containerName, ...command]);
  expect(result.exitCode, 0, reason: 'could not read $label: ${result.stderr}');
  return result.stdout as String;
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
