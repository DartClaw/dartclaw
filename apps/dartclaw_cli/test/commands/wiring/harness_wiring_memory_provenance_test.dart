import 'dart:io';

import 'package:dartclaw_cli/src/commands/wiring/harness_wiring.dart';
import 'package:dartclaw_cli/src/commands/wiring/security_wiring.dart';
import 'package:dartclaw_cli/src/commands/wiring/storage_wiring.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide HarnessConfig;
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

import '../../helpers/harness_wiring_fixture.dart';

Never _unexpectedExit(int code) => throw StateError('Unexpected exit($code)');

void main() {
  late Directory tempDir;
  late DartclawConfig config;
  late EventBus eventBus;
  late StorageWiring storage;
  late SecurityWiring security;
  late HarnessWiring harnessWiring;
  late HarnessFactoryConfig factoryConfig;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_memory_provenance_');
    config = DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      agent: const AgentConfig(provider: 'claude'),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1)},
      ),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      gateway: const GatewayConfig(authMode: 'none'),
    );
    writeWorkspacePromptFiles(config.workspaceDir);
    eventBus = EventBus();
    storage = await wireTestStorage(config: config, eventBus: eventBus, exitFn: _unexpectedExit);
    security = await wireTestSecurity(
      config: config,
      dataDir: tempDir.path,
      eventBus: eventBus,
      exitFn: _unexpectedExit,
    );
    final factory = HarnessFactory()
      ..register('claude', (config) {
        factoryConfig = config;
        return FakeAgentHarness(promptStrategy: PromptStrategy.append);
      });
    harnessWiring = await wireTestHarness(
      config: config,
      dataDir: tempDir.path,
      harnessFactory: factory,
      exitFn: _unexpectedExit,
      storage: storage,
      security: security,
      eventBus: eventBus,
      serverRefGetter: () => throw UnimplementedError(),
    );
  });

  tearDown(() async {
    await harnessWiring.executions.dispose();
    await security.dispose();
    await storage.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('direct capture callbacks persist host turn and journal provenance', () async {
    final revision = (await storage.memoryCorpus.readCorpus()).index.metadata.revision;
    await factoryConfig.onContextualMemoryApply!({
      'expectedRevision': revision,
      'operations': [
        {
          'kind': 'add',
          'correlationId': 'preference',
          'topic': 'preferences',
          'content': 'Primary remembered preference',
        },
      ],
    }, const HarnessTurnContext(sessionId: 'session-1', turnId: 'turn-1', source: 'web', agentName: 'main'));
    await factoryConfig.onContextualMemoryObserve!(
      {'text': 'Journal learning', 'role': 'learning'},
      const HarnessTurnContext(
        sessionId: 'journal-session',
        turnId: 'journal-turn',
        source: 'cron',
        agentName: 'cron:memory-journal',
      ),
    );

    final corpus = await storage.memoryCorpus.readCorpus();
    final primary = corpus.topics.single.entries.single.provenance;
    final journal = corpus.learnings!.entries.singleWhere((entry) => entry.content == 'Journal learning').provenance;
    expect(primary.originKind, MemoryOriginKind.turn);
    expect(primary.sourceLocator, 'session:session-1');
    expect(primary.sourceEvent, 'turn:turn-1');
    expect(primary.sessionRef, 'session-1');
    expect(journal.originKind, MemoryOriginKind.journal);
    expect(journal.sourceLocator, 'memory-journal');
    expect(journal.sourceEvent, 'turn:journal-turn');
    expect(journal.caller, 'cron:memory-journal');
    expect(journal.sessionRef, 'journal-session');
  });
}
