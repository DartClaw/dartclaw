import 'dart:io';

import 'package:dartclaw_cli/src/commands/wiring/harness_wiring.dart';
import 'package:dartclaw_cli/src/commands/wiring/security_wiring.dart';
import 'package:dartclaw_cli/src/commands/wiring/storage_wiring.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide HarnessConfig;
import 'package:dartclaw_server/dartclaw_server.dart' show DartclawServer, DartclawServerBuilder;
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

Never _unexpectedExit(int code) => throw StateError('Unexpected exit($code) during harness wiring test');

void main() {
  test('logical-agent session resumes persisted history after storage and worker reconstruction', () async {
    final tempDir = Directory.systemTemp.createTempSync('dartclaw_session_restart_');
    final config = DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      agent: const AgentConfig(
        provider: 'claude',
        definitions: [
          AgentDefinition(
            id: 'search',
            description: 'Search',
            prompt: 'SEARCH PERSONA',
            model: 'sonnet',
            effort: 'low',
          ),
        ],
      ),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1)},
      ),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      gateway: const GatewayConfig(authMode: 'none'),
    );
    final workspaceDir = Directory(config.workspaceDir)..createSync(recursive: true);
    for (final entry in const {
      'SOUL.md': 'Soul prompt',
      'USER.md': 'User prompt',
      'TOOLS.md': 'Tool prompt',
      'AGENTS.md': '## Agent prompt',
      'errors.md': '## Recent error',
      'learnings.md': '## Recent learning',
    }.entries) {
      File(p.join(workspaceDir.path, entry.key)).writeAsStringSync(entry.value);
    }
    final eventBus = EventBus();
    final createdHarnesses = <FakeAgentHarness>[];
    StorageWiring? storage;
    SecurityWiring? security;
    HarnessWiring? harnessWiring;

    Future<void> wireStorageAndSecurity() async {
      storage = StorageWiring(
        config: config,
        eventBus: eventBus,
        searchDbFactory: (_) => sqlite3.openInMemory(),
        taskDbFactory: (_) => sqlite3.openInMemory(),
        exitFn: _unexpectedExit,
      );
      await storage!.wire();
      security = SecurityWiring(config: config, dataDir: tempDir.path, eventBus: eventBus, exitFn: _unexpectedExit);
      await security!.wire(agentDefs: config.agent.definitions);
    }

    Future<void> wireRuntime() async {
      final factory = HarnessFactory()
        ..register('claude', (_) {
          final harness = FakeAgentHarness(promptStrategy: PromptStrategy.append);
          createdHarnesses.add(harness);
          return harness;
        });
      late DartclawServer server;
      harnessWiring = HarnessWiring(
        config: config,
        dataDir: tempDir.path,
        port: 3333,
        harnessFactory: factory,
        exitFn: _unexpectedExit,
        storage: storage!,
        security: security!,
        messageRedactor: MessageRedactor(),
        eventBus: eventBus,
      );
      await harnessWiring!.wire(serverRefGetter: () => server);
      server =
          (DartclawServerBuilder()
                ..sessions = storage!.sessions
                ..messages = storage!.messages
                ..worker = harnessWiring!.harness
                ..staticDir = tempDir.path
                ..behavior = harnessWiring!.behavior
                ..pool = harnessWiring!.pool
                ..sessionsForTurns = storage!.sessions
                ..workerPoolCoordinator = harnessWiring!.workerPoolCoordinator
                ..config = config)
              .build();
    }

    addTearDown(() async {
      await harnessWiring?.pool.dispose();
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
    firstWorker.emit(DeltaEvent('Amber remembered'));
    firstWorker.completeSuccess();
    final handle = (await spawnFuture)['sessionId'] as String;
    final storedSession = await storage!.sessions.getByKey(handle);
    expect(storedSession?.provider, 'claude');
    expect(storedSession?.securityProfile, 'workspace');

    await harnessWiring!.pool.dispose();
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
    expect(reconstructedSession?.securityProfile, 'workspace');
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
  });
}

Future<void> _waitForHarnessCount(List<FakeAgentHarness> harnesses, int count) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (harnesses.length != count && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(harnesses, hasLength(count));
}
