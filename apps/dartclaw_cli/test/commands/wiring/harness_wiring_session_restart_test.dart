import 'dart:io';

import 'package:dartclaw_cli/src/commands/wiring/harness_wiring.dart';
import 'package:dartclaw_cli/src/commands/wiring/security_wiring.dart';
import 'package:dartclaw_cli/src/commands/wiring/storage_wiring.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide HarnessConfig;
import 'package:dartclaw_server/dartclaw_server.dart' show DartclawServer, DartclawServerBuilder;
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

import '../../helpers/harness_wiring_fixture.dart';

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
    writeWorkspacePromptFiles(config.workspaceDir);
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
          final harness = FakeAgentHarness(promptStrategy: PromptStrategy.append);
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
      server =
          (DartclawServerBuilder()
                ..sessions = storage!.sessions
                ..messages = storage!.messages
                ..worker = harnessWiring!.harness
                ..staticDir = tempDir.path
                ..behavior = harnessWiring!.behavior
                ..executions = harnessWiring!.executions
                ..sessionsForTurns = storage!.sessions
                ..config = config)
              .build();
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
    firstWorker.emit(DeltaEvent('Amber remembered'));
    firstWorker.completeSuccess();
    final handle = (await spawnFuture)['sessionId'] as String;
    final storedSession = await storage!.sessions.getByKey(handle);
    expect(storedSession?.provider, 'claude');
    expect(storedSession?.executionMode, ExecutionMode.host, reason: 'containers are disabled in this deployment');
    expect(storedSession?.securityProfile, isNull, reason: 'host execution pins no container profile');

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
  });
}

Future<void> _waitForHarnessCount(List<FakeAgentHarness> harnesses, int count) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (harnesses.length != count && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(harnesses, hasLength(count));
}
