import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_runtime/src/runtime/harness_wiring.dart';
import 'package:dartclaw_runtime/src/runtime/security_wiring.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

import 'harness_wiring_fixture.dart';

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
    await writeWorkspacePromptFiles(config.workspaceDir);
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

  test('direct capture callbacks persist host turn, journal, and curation provenance', () async {
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

    // Without its own branch a curation write inherits the generic turn origin, and
    // the corpus silently loses the distinction it records today.
    await factoryConfig.onContextualMemoryApply!(
      {
        'expectedRevision': (await storage.memoryCorpus.readCorpus()).index.metadata.revision,
        'operations': [
          {
            'kind': 'add',
            'correlationId': 'curated',
            'topic': 'preferences',
            'content': 'Curated remembered preference',
          },
        ],
      },
      const HarnessTurnContext(
        sessionId: 'curation-session',
        turnId: 'curation-turn',
        source: 'cron',
        agentName: 'cron:memory-curation',
      ),
    );

    final corpus = await storage.memoryCorpus.readCorpus();
    final topicEntries = corpus.topics.expand((topic) => topic.entries).toList();
    final primary = topicEntries.singleWhere((entry) => entry.content == 'Primary remembered preference').provenance;
    final curated = topicEntries.singleWhere((entry) => entry.content == 'Curated remembered preference').provenance;
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
    expect(curated.originKind, MemoryOriginKind.curation);
    expect(curated.sourceLocator, 'memory-curation');
    expect(curated.sourceEvent, 'turn:curation-turn');
    expect(curated.caller, 'cron:memory-curation');
    expect(curated.sessionRef, 'curation-session');
  });

  test('production memory handlers reopen native KG and inbox locators', () async {
    final factId = storage.kg.addFact(
      entity: 'Falcon',
      predicate: 'status',
      value: 'green',
      validFrom: '2026-08-12T00:00:00Z',
      source: 'wiki/falcon.md',
    );
    Directory('${config.workspaceDir}/inbox').createSync();
    File('${config.workspaceDir}/inbox/note.md').writeAsStringSync('Native inbox detail');

    final fact = _decode(await harnessWiring.memoryHandlers.onRead({'locator': '$factId'}));
    final inbox = _decode(await harnessWiring.memoryHandlers.onRead({'locator': 'inbox/note.md'}));

    expect(((fact['results'] as List).single as Map)['role'], 'kg');
    expect(((inbox['results'] as List).single as Map)['content'], 'Native inbox detail');
  });
}

Map<String, dynamic> _decode(Map<String, dynamic> response) =>
    jsonDecode(((response['content'] as List).single as Map<String, dynamic>)['text'] as String)
        as Map<String, dynamic>;
