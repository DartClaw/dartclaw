import 'dart:io';

import 'package:dartclaw_runtime/src/runtime/harness_wiring.dart';
import 'package:dartclaw_runtime/src/runtime/security_wiring.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show DartclawServer, WorkspaceService;
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';
import 'package:dartclaw_runtime/src/server.dart' show ServerCoreDeps, ServerTurnDeps;
import 'package:dartclaw_runtime/src/server_composition.dart';

import 'harness_wiring_fixture.dart';

Never _unexpectedExit(int code) => throw StateError('Unexpected exit($code) during harness wiring test');

void main() {
  test('logical-agent session resumes persisted history after storage and worker reconstruction', () async {
    final tempDir = Directory.systemTemp.createTempSync('dartclaw_session_restart_');
    final workspace = AgentWorkspace.managed(
      agentId: 'search',
      dataDir: tempDir.path,
      ownerWorkspaceDir: '${tempDir.path}/workspace',
    );
    final config = DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      // No usable content classifier here (claudeExecutable is not claude), and
      // the product default is now fail-closed. Keep these wiring tests on the
      // old effective posture so a classifier error does not block every handoff;
      // the content-guard test below copyWiths this and still blocks on a verdict.
      security: const SecurityConfig(contentGuardFailOpen: true),
      agent: AgentConfig(
        provider: 'claude',
        definitions: [
          AgentDefinition(
            id: 'search',
            description: 'Search',
            prompt: 'SEARCH PERSONA',
            model: 'sonnet',
            effort: 'low',
            allowedTools: {'file_read', 'memory_read'},
            workspace: workspace,
          ),
        ],
      ),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1)},
      ),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      gateway: const GatewayConfig(authMode: 'none'),
    );
    await writeWorkspacePromptFiles(config.workspaceDir);
    await WorkspaceService(dataDir: tempDir.path).prepareManagedAgents([workspace]);
    final eventBus = EventBus();
    final createdHarnesses = <FakeAgentHarness>[];
    StorageWiring? storage;
    SecurityWiring? security;
    HarnessWiring? harnessWiring;

    Future<void> wireStorageAndSecurity() async {
      storage = await wireTestStorage(config: config, eventBus: eventBus, exitFn: _unexpectedExit);
      security = await wireTestSecurity(
        config: config,
        dataDir: tempDir.path,
        eventBus: eventBus,
        exitFn: _unexpectedExit,
      );
    }

    Future<void> wireRuntime() async {
      final factory = HarnessFactory()
        ..register('claude', (_) {
          final harness = FakeAgentHarness(promptStrategy: PromptStrategy.append, supportsNoWorkTools: true);
          createdHarnesses.add(harness);
          return harness;
        });
      late DartclawServer server;
      harnessWiring = await wireTestHarness(
        config: config,
        dataDir: tempDir.path,
        harnessFactory: factory,
        exitFn: _unexpectedExit,
        storage: storage!,
        security: security!,
        eventBus: eventBus,
        serverRefGetter: () => server,
      );
      server = composeServer(
        core: ServerCoreDeps(
          sessions: storage!.sessions,
          messages: storage!.messages,
          worker: harnessWiring!.primaryHarness,
          staticDir: tempDir.path,
          config: config,
        ),
        turn: ServerTurnDeps(
          turns: composeServerTurns(
            sessions: storage!.sessions,
            messages: storage!.messages,
            worker: harnessWiring!.primaryHarness,
            behavior: harnessWiring!.behavior,
            executions: harnessWiring!.executions,
            sessionsForTurns: storage!.sessions,
            config: config,
          ),
          executions: harnessWiring!.executions,
        ),
      );
    }

    addTearDown(() async {
      await harnessWiring?.executions.dispose();
      await security?.dispose();
      await storage?.dispose();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    await wireStorageAndSecurity();
    await wireRuntime();
    final spawnFuture = harnessWiring!.logicalAgentSessions.handleSessionsSpawn({
      'agent': 'search',
      'message': 'Remember amber',
    });
    await _waitForHarnessCount(createdHarnesses, 2);
    final firstWorker = createdHarnesses.last;
    await firstWorker.turnInvoked;
    firstWorker.emit(ToolUseEvent(toolName: 'file_read', toolId: 'read-1', input: const {'path': 'TOOLS.md'}));
    firstWorker.emit(DeltaEvent('Amber remembered'));
    await pumpEventQueue();
    firstWorker.completeSuccess();
    final handle = (await spawnFuture)['sessionId'] as String;
    final storedSession = await storage!.sessions.getByKey(handle);
    expect(storedSession?.provider, 'claude');
    expect(storedSession?.executionMode, ExecutionMode.host, reason: 'containers are disabled in this deployment');
    expect(storedSession?.securityProfile, isNull, reason: 'host execution pins no container profile');
    expect(storedSession?.workspace, workspace);
    final personalFiles = Directory(workspace.directory).listSync(recursive: true).whereType<File>();
    expect(personalFiles.every((file) => !file.readAsStringSync().contains('Remember amber')), isTrue);

    expect(
      () => AgentWorkspace.requireCurrent(
        sessionId: storedSession!.id,
        agentId: 'search',
        pinned: storedSession.workspace,
        configured: null,
      ),
      throwsA(isA<StateError>().having((error) => error.message, 'message', contains('Create a new conversation'))),
    );

    await harnessWiring!.executions.dispose();
    harnessWiring = null;
    await security!.dispose();
    security = null;
    await storage!.dispose();
    storage = null;
    createdHarnesses.clear();

    await wireStorageAndSecurity();
    await wireRuntime();
    final reconstructedSession = await storage!.sessions.getByKey(handle);
    expect(reconstructedSession?.provider, 'claude');
    expect(
      reconstructedSession?.executionMode,
      ExecutionMode.host,
      reason: 'the pinned routing survives storage and worker reconstruction',
    );
    expect(reconstructedSession?.securityProfile, isNull);
    final sendFuture = harnessWiring!.logicalAgentSessions.handleSessionsSend({
      'session_id': handle,
      'message': 'What did I ask you to remember?',
    });
    await _waitForHarnessCount(createdHarnesses, 2);
    final reconstructedWorker = createdHarnesses.last;
    await reconstructedWorker.turnInvoked;
    expect(reconstructedWorker.lastAgentId, 'search');
    expect(reconstructedWorker.lastSystemPrompt, contains('SEARCH PERSONA'));
    expect(reconstructedWorker.lastModel, 'sonnet');
    expect(reconstructedWorker.lastEffort, 'low');
    expect(reconstructedWorker.lastMessages, [
      {'role': 'user', 'content': 'Remember amber'},
      {'role': 'assistant', 'content': 'Amber remembered'},
      {'role': 'user', 'content': 'What did I ask you to remember?'},
    ]);
    reconstructedWorker.emit(DeltaEvent('Amber'));
    reconstructedWorker.completeSuccess();
    expect((await sendFuture)['content'], contains(containsPair('text', 'Amber')));

    final failureFuture = harnessWiring!.logicalAgentSessions.handleSessionsSend({
      'session_id': handle,
      'message': 'Fail without capturing this turn',
    });
    await _waitForHarnessCount(createdHarnesses, 3);
    final failingWorker = createdHarnesses.last;
    await failingWorker.turnInvoked;
    failingWorker.completeError(StateError('READ_ONLY_AGENT_FAILURE_MARKER'));
    expect((await failureFuture)['isError'], isTrue);
    await pumpEventQueue(times: 20);
    expect(
      [config.workspaceDir, workspace.directory]
          .expand((directory) => Directory(directory).listSync(recursive: true).whereType<File>())
          .every((file) => !file.readAsStringSync().contains('READ_ONLY_AGENT_FAILURE_MARKER')),
      isTrue,
    );
  });
}

Future<void> _waitForHarnessCount(List<FakeAgentHarness> harnesses, int count) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (harnesses.length != count && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(harnesses, hasLength(count));
}
