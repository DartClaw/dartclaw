@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart'
    show
        ContainerManager,
        DartclawServer,
        ExecutionEvent,
        ExecutionEventKind,
        ExecutionRequest,
        ExecutionSurface,
        WorkerCreationException,
        WorkspaceService;
import 'package:dartclaw_runtime/src/behavior/behavior_file_service.dart';
import 'package:dartclaw_runtime/src/container/security_profile.dart';
import 'package:dartclaw_runtime/src/execution_policy_resolver.dart';
import 'package:dartclaw_runtime/src/server.dart' show ServerCoreDeps, ServerTurnDeps;
import 'package:dartclaw_runtime/src/server_composition.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../runtime/harness_wiring_fixture.dart';
import 'container_integration_support.dart';

Never _unexpectedExit(int code) => throw StateError('Unexpected exit($code)');

void main() {
  late Directory dataDir;
  late Directory ownerDir;
  late Directory agentADir;
  late Directory agentBDir;

  setUp(() async {
    dataDir = Directory.systemTemp.createTempSync('agent_workspace_execution_');
    dataDir = Directory(dataDir.resolveSymbolicLinksSync());
    ownerDir = Directory(p.join(dataDir.path, 'workspace'))..createSync();
    final workspaceA = AgentWorkspace.managed(agentId: 'a', dataDir: dataDir.path, ownerWorkspaceDir: ownerDir.path);
    final workspaceB = AgentWorkspace.managed(agentId: 'b', dataDir: dataDir.path, ownerWorkspaceDir: ownerDir.path);
    await WorkspaceService(dataDir: dataDir.path).prepareManagedAgents([workspaceA, workspaceB]);
    agentADir = Directory(workspaceA.directory);
    agentBDir = Directory(workspaceB.directory);
  });

  tearDown(() {
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
  });

  test('configured and absent agents preserve identity, history, and prompt isolation across restart', () async {
    File(p.join(ownerDir.path, 'SOUL.md')).writeAsStringSync('OWNER SOUL');
    File(p.join(ownerDir.path, 'USER.md')).writeAsStringSync('OWNER USER');
    File(p.join(agentADir.path, 'SOUL.md')).writeAsStringSync('AGENT A SOUL');
    File(p.join(agentADir.path, 'TOOLS.md')).writeAsStringSync('AGENT A TOOLS');
    File(p.join(agentBDir.path, 'SOUL.md')).writeAsStringSync('AGENT B SOUL');
    const agentAId = 'a';
    const agentBId = 'b';
    final workspaceA = AgentWorkspace(agentId: agentAId, directory: agentADir.path);
    final workspaceB = AgentWorkspace(agentId: agentBId, directory: agentBDir.path);
    final sessionsDir = p.join(dataDir.path, 'sessions');
    final sessions = SessionService(baseDir: sessionsDir);
    final messages = MessageService(baseDir: sessionsDir);

    final sessionA = await sessions.getOrCreateByKey(
      'agent:a:logical:conversation-a',
      type: SessionType.logicalAgent,
      workspace: workspaceA,
    );
    final sessionB = await sessions.getOrCreateByKey(
      'agent:b:logical:conversation-b',
      type: SessionType.logicalAgent,
      workspace: workspaceB,
    );
    final sessionC = await sessions.getOrCreateByKey('agent:c:logical:conversation-c', type: SessionType.logicalAgent);
    final legacy = await sessions.getOrCreateByKey('agent:a:logical:legacy', type: SessionType.logicalAgent);
    await messages.insertMessage(sessionId: sessionA.id, role: 'user', content: 'A HISTORY MARKER');
    await messages.insertMessage(sessionId: sessionB.id, role: 'user', content: 'B HISTORY MARKER');
    await messages.insertMessage(sessionId: sessionC.id, role: 'user', content: 'C HISTORY MARKER');
    await messages.insertMessage(sessionId: legacy.id, role: 'user', content: 'LEGACY HISTORY MARKER');

    final restarted = SessionService(baseDir: sessionsDir);
    final loadedA = await restarted.getByKey('agent:a:logical:conversation-a');
    final loadedB = await restarted.getByKey('agent:b:logical:conversation-b');
    final loadedC = await restarted.getByKey('agent:c:logical:conversation-c');
    expect(loadedA?.workspace?.storagePrincipal, 'agent:a');
    expect(loadedA?.workspace?.directory, agentADir.path);
    expect(loadedB?.workspace?.storagePrincipal, 'agent:b');
    expect(loadedB?.workspace?.directory, agentBDir.path);
    expect(loadedC?.workspace, isNull);

    final baseBehavior = BehaviorFileService(workspaceDir: ownerDir.path);
    final promptA = await baseBehavior
        .forAgentWorkspace(loadedA!.workspace)
        .composeSystemPrompt(scope: PromptScope.primary);
    final promptB = await baseBehavior
        .forAgentWorkspace(loadedB!.workspace)
        .composeSystemPrompt(scope: PromptScope.primary);
    final promptC = await baseBehavior
        .forAgentWorkspace(loadedC!.workspace)
        .composeSystemPrompt(scope: PromptScope.primary);
    expect(promptA, allOf(contains('AGENT A SOUL'), contains('AGENT A TOOLS'), isNot(contains('OWNER'))));
    expect(promptB, allOf(contains('AGENT B SOUL'), isNot(contains('AGENT A')), isNot(contains('OWNER'))));
    expect(promptC, allOf(contains(BehaviorFileService.defaultPrompt), isNot(contains('OWNER'))));

    final movedA = AgentWorkspace(agentId: 'a', directory: p.join(dataDir.path, 'agents', 'a-moved'));
    await expectLater(
      restarted.getOrCreateByKey('agent:a:logical:conversation-a', type: SessionType.logicalAgent, workspace: movedA),
      throwsA(isA<StateError>().having((error) => error.message, 'message', contains('Create a new conversation'))),
    );
    await expectLater(
      restarted.getOrCreateByKey('agent:a:logical:legacy', type: SessionType.logicalAgent, workspace: workspaceA),
      throwsA(isA<StateError>().having((error) => error.message, 'message', contains('Create a new conversation'))),
    );

    expect((await messages.getMessages(sessionA.id)).single.content, 'A HISTORY MARKER');
    expect((await messages.getMessages(sessionB.id)).single.content, 'B HISTORY MARKER');
    expect((await messages.getMessages(sessionC.id)).single.content, 'C HISTORY MARKER');
    expect((await messages.getMessages(legacy.id)).single.content, 'LEGACY HISTORY MARKER');
    expect((await restarted.getSession(sessionA.id))?.workspace, workspaceA);
    expect((await restarted.getSession(legacy.id))?.workspace, isNull);
  });

  test('retired paths refuse while pathless agents derive managed homes', () async {
    final nested = Directory(p.join(agentADir.path, 'nested'))..createSync();
    final yaml =
        '''
data_dir: "${dataDir.path}"
agent:
  agents:
    healthy:
      tools: [Read]
    unsafe:
      workspace: "${nested.path}"
      tools: [Read]
    absent:
      tools: [Read]
''';
    final config = DartclawConfig.load(
      configPath: 'dartclaw.yaml',
      fileReader: (path) => path == 'dartclaw.yaml' ? yaml : null,
      env: const {'HOME': '/home/user'},
      resolveStoredCredentials: false,
    );
    final definitions = {for (final definition in config.agent.definitions) definition.id: definition};
    final dispatched = <String>[];
    final service = LogicalAgentSessionService(
      agents: definitions,
      dispatch: ({required sessionId, required message, required agentId, required createSession}) async {
        dispatched.add(agentId);
        return '$agentId response';
      },
    );

    final unsafe = await service.handleSessionsSpawn({'agent': 'unsafe', 'message': 'run'});
    final healthy = await service.handleSessionsSpawn({'agent': 'healthy', 'message': 'run'});
    final absent = await service.handleSessionsSpawn({'agent': 'absent', 'message': 'run'});

    expect(unsafe['isError'], isTrue);
    expect(unsafe['content'].toString(), allOf(contains('unsafe'), contains('workspace is no longer supported')));
    expect(healthy, isNot(contains('isError')));
    expect(absent, isNot(contains('isError')));
    expect(dispatched, ['healthy', 'absent']);
    expect(definitions['healthy']?.workspace?.directory, p.join(dataDir.path, 'agents', 'healthy', 'workspace'));
    expect(definitions['absent']?.workspace?.directory, p.join(dataDir.path, 'agents', 'absent', 'workspace'));
    expect(
      definitions['unsafe']?.workspace,
      isNull,
      reason: 'a retired explicit path is never treated as a managed binding',
    );
    expect(definitions['unsafe']?.workspaceConfigurationError, isNotNull);
  });

  test('production harness and turn admission use the pinned workspace while a project changes only cwd', () async {
    File(p.join(ownerDir.path, 'SOUL.md')).writeAsStringSync('OWNER SOUL');
    File(p.join(agentADir.path, 'SOUL.md')).writeAsStringSync('AGENT A SOUL');
    File(p.join(agentADir.path, 'USER.md')).writeAsStringSync('AGENT A USER');
    File(p.join(agentADir.path, 'TOOLS.md')).writeAsStringSync('AGENT A TOOLS');
    File(p.join(agentBDir.path, 'SOUL.md')).writeAsStringSync('AGENT B SOUL');
    File(p.join(agentBDir.path, 'USER.md')).writeAsStringSync('AGENT B USER');
    File(p.join(agentBDir.path, 'TOOLS.md')).writeAsStringSync('AGENT B TOOLS');
    final workspace = AgentWorkspace.managed(agentId: 'a', dataDir: dataDir.path, ownerWorkspaceDir: ownerDir.path);
    final workspaceB = AgentWorkspace.managed(agentId: 'b', dataDir: dataDir.path, ownerWorkspaceDir: ownerDir.path);
    final helperWorkspace = AgentWorkspace.managed(
      agentId: 'helper',
      dataDir: dataDir.path,
      ownerWorkspaceDir: ownerDir.path,
    );
    await WorkspaceService(dataDir: dataDir.path).prepareManagedAgents([helperWorkspace]);
    final workspaceBOutputSchema = parseOutputSchema(const {
      'type': 'object',
      'properties': {
        'result': {'type': 'string'},
      },
      'required': ['result'],
    }, yamlPath: 'agent.agents.b.output_schema');
    final project = Directory(p.join(dataDir.path, 'projects', 'authorized'))..createSync(recursive: true);
    final config = DartclawConfig(
      server: ServerConfig(dataDir: dataDir.path, claudeExecutable: Platform.resolvedExecutable),
      security: const SecurityConfig(contentGuardFailOpen: true),
      agent: AgentConfig(
        provider: 'claude',
        definitions: [
          AgentDefinition(id: 'a', description: 'A', prompt: 'EXPLICIT A SOUL', workspace: workspace),
          AgentDefinition(
            id: 'b',
            description: 'B',
            prompt: '',
            workspace: workspaceB,
            outputSchema: workspaceBOutputSchema,
          ),
          AgentDefinition(
            id: 'helper',
            description: 'Helper',
            prompt: '',
            allowedTools: const {'web_search'},
            workspace: helperWorkspace,
          ),
        ],
      ),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1)},
      ),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      gateway: const GatewayConfig(authMode: 'none'),
    );
    final eventBus = EventBus();
    final createdHarnesses = <FakeAgentHarness>[];
    final harnessConfigs = <FakeAgentHarness, HarnessFactoryConfig>{};
    final factory = HarnessFactory()
      ..register('claude', (config) {
        final harness = FakeAgentHarness(promptStrategy: PromptStrategy.append, supportsNoWorkTools: true);
        createdHarnesses.add(harness);
        harnessConfigs[harness] = config;
        return harness;
      });
    String capturedPrompt(FakeAgentHarness harness) => [
      harnessConfigs[harness]?.harnessConfig.appendSystemPrompt,
      harness.lastSystemPrompt,
    ].whereType<String>().join('\n\n');
    final storage = await wireTestStorage(config: config, eventBus: eventBus, exitFn: _unexpectedExit);
    final security = await wireTestSecurity(
      config: config,
      dataDir: dataDir.path,
      eventBus: eventBus,
      exitFn: _unexpectedExit,
    );
    late DartclawServer server;
    final harnessWiring = await wireTestHarness(
      config: config,
      dataDir: dataDir.path,
      harnessFactory: factory,
      exitFn: _unexpectedExit,
      storage: storage,
      security: security,
      eventBus: eventBus,
      serverRefGetter: () => server,
    );
    server = composeServer(
      core: ServerCoreDeps(
        sessions: storage.sessions,
        messages: storage.messages,
        worker: harnessWiring.primaryHarness,
        staticDir: dataDir.path,
        config: config,
      ),
      turn: ServerTurnDeps(
        turns: composeServerTurns(
          sessions: storage.sessions,
          messages: storage.messages,
          worker: harnessWiring.primaryHarness,
          behavior: harnessWiring.behavior,
          executions: harnessWiring.executions,
          sessionsForTurns: storage.sessions,
          config: config,
        ),
        executions: harnessWiring.executions,
      ),
    );
    addTearDown(() async {
      await harnessWiring.executions.dispose();
      await security.dispose();
      await storage.dispose();
    });
    final events = <ExecutionEvent>[];
    final eventSubscription = harnessWiring.executions.events.listen(events.add);
    addTearDown(eventSubscription.cancel);

    File(p.join(ownerDir.path, 'SOUL.md')).writeAsStringSync('CHANGED OWNER SOUL');
    File(p.join(agentADir.path, 'USER.md')).writeAsStringSync('CHANGED AGENT A USER');
    File(p.join(agentADir.path, 'TOOLS.md')).writeAsStringSync('CHANGED AGENT A TOOLS');
    File(p.join(agentBDir.path, 'SOUL.md')).writeAsStringSync('CHANGED AGENT B SOUL');
    File(p.join(agentBDir.path, 'USER.md')).writeAsStringSync('CHANGED AGENT B USER');
    File(p.join(agentBDir.path, 'TOOLS.md')).writeAsStringSync('CHANGED AGENT B TOOLS');

    final spawn = harnessWiring.logicalAgentSessions.handleSessionsSpawn({'agent': 'a', 'message': 'first'});
    await _waitFor(() => createdHarnesses.any((harness) => harness.turnCallCount == 1));
    final worker = createdHarnesses.lastWhere((harness) => harness.turnCallCount == 1);
    expect(worker.lastAgentId, 'a');
    expect(worker.lastDirectory, agentADir.path);
    expect(harnessConfigs[worker]?.skillWorkspaceDir, agentADir.path);
    expect(harnessConfigs[worker]?.declaredWritableRoots, contains(agentADir.path));
    expect(harnessConfigs[worker]?.declaredWritableRoots, isNot(contains(p.dirname(agentADir.path))));
    expect(
      harnessConfigs[worker]?.declaredWritableRoots,
      isNot(contains(p.join(p.dirname(agentADir.path), 'identity.json'))),
    );
    expect(
      capturedPrompt(worker),
      allOf(
        contains('EXPLICIT A SOUL'),
        contains('AGENT A USER'),
        contains('AGENT A TOOLS'),
        isNot(contains('CHANGED AGENT A')),
        isNot(contains('AGENT A SOUL')),
        isNot(contains('OWNER')),
      ),
    );
    worker.emit(DeltaEvent('first response'));
    worker.completeSuccess();
    final handle = (await spawn)['sessionId'] as String;
    final storedAgentSession = await storage.sessions.getByKey(handle);
    expect(storedAgentSession?.workspace, workspace);
    final sessionId = storedAgentSession!.id;

    final callsBeforeProject = {for (final harness in createdHarnesses) harness: harness.turnCallCount};
    final turnId = await server.turns.reserveTurn(
      sessionId,
      directory: project.path,
      workerPolicy: const ExecutionPolicy.host(),
    );
    server.turns.executeTurn(sessionId, turnId, const [
      {'role': 'user', 'content': 'project turn'},
    ]);
    await _waitFor(
      () =>
          createdHarnesses.fold<int>(0, (sum, harness) => sum + harness.turnCallCount) ==
          callsBeforeProject.values.fold<int>(0, (sum, count) => sum + count) + 1,
    );
    final projectWorker = createdHarnesses.firstWhere(
      (harness) => harness.turnCallCount > (callsBeforeProject[harness] ?? 0),
    );

    expect(projectWorker.lastAgentId, 'a');
    expect(projectWorker.lastDirectory, project.path);
    expect(harnessConfigs[projectWorker]?.skillWorkspaceDir, agentADir.path);
    expect(harnessConfigs[projectWorker]?.declaredWritableRoots, contains(agentADir.path));
    expect(
      events.where((event) => event.kind == ExecutionEventKind.acquired).last.request.workspace?.storagePrincipal,
      'agent:a',
    );
    expect(
      events.where((event) => event.kind == ExecutionEventKind.acquired).last.request.workspace?.directory,
      agentADir.path,
    );
    projectWorker.emit(DeltaEvent('project response'));
    projectWorker.completeSuccess();
    await server.turns.waitForOutcome(sessionId, turnId);

    final staleKey = SessionKey.logicalAgentSession(agentId: 'a', conversationId: 'stale-workspace');
    final stale = await storage.sessions.getOrCreateByKey(
      staleKey,
      type: SessionType.logicalAgent,
      workspace: AgentWorkspace.pinned(agentId: 'a', directory: agentBDir.path),
    );
    await expectLater(
      server.turns.reserveTurn(stale.id, workerPolicy: const ExecutionPolicy.host()),
      throwsA(isA<StateError>().having((error) => error.message, 'message', contains('Create a new conversation'))),
    );
    final legacyKey = SessionKey.logicalAgentSession(agentId: 'a', conversationId: 'legacy-workspace');
    final legacy = await storage.sessions.getOrCreateByKey(legacyKey, type: SessionType.logicalAgent);
    await expectLater(
      server.turns.reserveTurn(legacy.id, workerPolicy: const ExecutionPolicy.host()),
      throwsA(isA<StateError>().having((error) => error.message, 'message', contains('Create a new conversation'))),
    );

    final beforeB = createdHarnesses.fold<int>(0, (sum, harness) => sum + harness.turnCallCount);
    final spawnB = harnessWiring.logicalAgentSessions.handleSessionsSpawn({'agent': 'b', 'message': 'schema'});
    await _waitFor(() => createdHarnesses.fold<int>(0, (sum, harness) => sum + harness.turnCallCount) == beforeB + 1);
    final workerB = createdHarnesses.last;
    expect(workerB.lastDirectory, agentBDir.path);
    expect(harnessConfigs[workerB]?.skillWorkspaceDir, agentBDir.path);
    expect(harnessConfigs[workerB]?.declaredWritableRoots, contains(agentBDir.path));
    expect(harnessConfigs[workerB]?.declaredWritableRoots, isNot(contains(p.dirname(agentBDir.path))));
    expect(
      capturedPrompt(workerB),
      allOf(
        contains('AGENT B SOUL'),
        contains('AGENT B USER'),
        contains('AGENT B TOOLS'),
        isNot(contains('CHANGED AGENT B')),
        contains('Respond with only the JSON value described by this schema'),
        isNot(contains('OWNER')),
      ),
    );
    workerB.emit(DeltaEvent('{"result":"ok"}'));
    workerB.completeSuccess();
    expect((await spawnB)['content'].toString(), contains('{"result":"ok"}'));

    final ownerTask = await storage.sessions.createSession(type: SessionType.task);
    final beforeOwner = {for (final harness in createdHarnesses) harness: harness.turnCallCount};
    final ownerTurnId = await server.turns.reserveTurn(
      ownerTask.id,
      agentName: 'main',
      workerPolicy: const ExecutionPolicy.host(),
    );
    server.turns.executeTurn(ownerTask.id, ownerTurnId, const [
      {'role': 'user', 'content': 'owner task'},
    ]);
    await _waitFor(
      () =>
          createdHarnesses.fold<int>(0, (sum, harness) => sum + harness.turnCallCount) ==
          beforeOwner.values.fold<int>(0, (sum, count) => sum + count) + 1,
    );
    final ownerWorker = createdHarnesses.firstWhere((harness) => harness.turnCallCount > (beforeOwner[harness] ?? 0));
    expect(capturedPrompt(ownerWorker), allOf(contains('OWNER SOUL'), isNot(contains('CHANGED OWNER'))));
    ownerWorker.emit(DeltaEvent('owner response'));
    ownerWorker.completeSuccess();
    await server.turns.waitForOutcome(ownerTask.id, ownerTurnId);

    final beforeAbsent = createdHarnesses.fold<int>(0, (sum, harness) => sum + harness.turnCallCount);
    final absentSpawn = harnessWiring.logicalAgentSessions.handleSessionsSpawn({'agent': 'helper', 'message': 'plain'});
    await _waitFor(
      () => createdHarnesses.fold<int>(0, (sum, harness) => sum + harness.turnCallCount) == beforeAbsent + 1,
    );
    final absentWorker = createdHarnesses.last;
    expect(absentWorker, isNot(same(ownerWorker)));
    expect(absentWorker.lastDirectory, helperWorkspace.directory);
    expect(harnessConfigs[absentWorker]?.skillWorkspaceDir, helperWorkspace.directory);
    expect(harnessConfigs[absentWorker]?.declaredWritableRoots, isNot(contains(ownerDir.path)));
    expect(capturedPrompt(absentWorker), allOf(contains(BehaviorFileService.defaultPrompt), isNot(contains('OWNER'))));
    expect(events.where((event) => event.kind == ExecutionEventKind.acquired).last.request.workspace, helperWorkspace);
    absentWorker.emit(DeltaEvent('plain response'));
    absentWorker.completeSuccess();
    await absentSpawn;

    final capacityBefore = harnessWiring.executions.snapshot.availableWorkers;
    await expectLater(
      harnessWiring.executions.acquire(
        ExecutionRequest(
          surface: ExecutionSurface.logicalAgent,
          providerId: 'claude',
          policy: const ExecutionPolicy.container('workspace'),
          sessionId: sessionId,
          logicalAgentId: 'a',
          workspace: workspace,
          allowedTools: const [],
        ),
      ),
      throwsA(
        isA<WorkerCreationException>().having(
          (error) => error.message,
          'message',
          contains('requires unavailable container profile "workspace"'),
        ),
      ),
    );
    expect(harnessWiring.executions.snapshot.availableWorkers, capacityBefore);

    final hostWarnings = ExecutionPolicyResolver(
      config: DartclawConfig(
        server: ServerConfig(dataDir: dataDir.path),
        container: const ContainerConfig(enabled: true),
        agent: const AgentConfig(execution: ExecutionMode.host),
      ),
      availableContainerProfiles: const {'workspace'},
    ).hostOverrideWarnings();
    expect(hostWarnings, [contains('runs directly on the host')]);
    final managedHomes = [p.dirname(agentADir.path), p.dirname(agentBDir.path), p.dirname(helperWorkspace.directory)];
    for (final factoryConfig in harnessConfigs.values) {
      for (final home in managedHomes) {
        expect(factoryConfig.declaredWritableRoots, isNot(contains(home)));
      }
      expect(factoryConfig.declaredWritableRoots, everyElement(isNot(endsWith('${p.separator}identity.json'))));
    }
  });

  test('enforced workspace confinement mounts no identity marker and denies marker writes', () async {
    if (!await dockerAvailable()) {
      throw StateError('Docker is required for the enforced workspace confinement proof');
    }
    final checkoutRoot = await repoRoot();
    await ensureAgentImage(checkoutRoot);
    final marker = File(p.join(p.dirname(agentADir.path), 'identity.json'));
    final before = marker.readAsBytesSync();
    final manager = ContainerManager(
      ownerLabel: ContainerManager.ownerLabel(dataDir.path),
      config: const ContainerConfig(enabled: true, image: agentProbeImage),
      containerName: 'dartclaw-managed-marker-${DateTime.now().microsecondsSinceEpoch}',
      profileId: 'workspace',
      workspaceMounts: SecurityProfile.workspace(workspaceDir: agentADir.path, projectDir: null).workspaceMounts,
      generatedStateDir: p.join(dataDir.path, 'containers', 'managed-marker'),
      hasMcpBridge: false,
      buildContextDir: checkoutRoot,
      workingDir: '/workspace',
    );
    addTearDown(manager.stop);

    await manager.start();
    final inspected = await Process.run('docker', ['inspect', '--format', '{{json .Mounts}}', manager.containerName]);
    expect(inspected.exitCode, 0, reason: inspected.stderr.toString());
    final mounts = (jsonDecode(inspected.stdout as String) as List<Object?>).cast<Map<String, Object?>>();
    final sources = mounts.map((mount) => mount['Source'] as String).toList();
    expect(sources.any((source) => p.equals(source, agentADir.path)), isTrue);
    expect(sources.any((source) => p.equals(source, p.dirname(agentADir.path))), isFalse);
    expect(sources.any((source) => p.equals(source, marker.path)), isFalse);

    final allowed = await Process.run('docker', [
      'exec',
      manager.containerName,
      'sh',
      '-c',
      'printf allowed > /workspace/allowed.txt',
    ]);
    expect(allowed.exitCode, 0, reason: allowed.stderr.toString());
    final denied = await Process.run('docker', [
      'exec',
      manager.containerName,
      'sh',
      '-c',
      'printf denied > /workspace/../identity.json',
    ]);
    expect(denied.exitCode, isNot(0));
    expect(marker.readAsBytesSync(), before);
  });
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue);
}
