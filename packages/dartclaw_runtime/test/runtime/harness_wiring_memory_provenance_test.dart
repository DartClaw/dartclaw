import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_runtime/dartclaw_runtime.dart' show MemoryJournal, memoryCurationJobId;
import 'package:dartclaw_runtime/src/mcp/mcp_server.dart' show McpCallerContext, mcpStewardPrincipal;
import 'package:dartclaw_runtime/src/mcp/memory_tools.dart' show MemoryApplyTool, MemoryObserveTool;
import 'package:dartclaw_runtime/src/memory_handlers.dart' show MemoryCaptureContext;
import 'package:dartclaw_runtime/src/runtime/harness_wiring.dart';
import 'package:dartclaw_runtime/src/runtime/security_wiring.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

import 'harness_wiring_fixture.dart';

const _captureContext = MemoryCaptureContext(sourceLocator: 'test:native-locators');

Never _unexpectedExit(int code) => throw StateError('Unexpected exit($code)');

void main() {
  late Directory tempDir;
  late DartclawConfig config;
  late EventBus eventBus;
  late StorageWiring storage;
  late SecurityWiring security;
  late HarnessWiring harnessWiring;

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
      ..register('claude', (_) => FakeAgentHarness(promptStrategy: PromptStrategy.append));
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

  test('memory tools persist host turn, journal, and curation provenance', () async {
    final primarySession = await storage.sessions.createSession();
    final journalSession = await storage.sessions.createSession();
    final curationSession = await storage.sessions.createSession();
    final revision = (await storage.memoryCorpus.readCorpus()).index.metadata.revision;
    final apply = harnessWiring.semanticMcpTools.whereType<MemoryApplyTool>().single;
    final observe = harnessWiring.semanticMcpTools.whereType<MemoryObserveTool>().single;
    McpCallerContext callerIn(String sessionId, String turnId, {TurnProvenance? turn}) => McpCallerContext(
      authorityId: mcpStewardPrincipal,
      sourceEvent: 'turn:$turnId',
      sessionId: sessionId,
      turn: turn,
    );

    await apply.callWithContext({
      'expectedRevision': revision,
      'operations': [
        {
          'kind': 'add',
          'correlationId': 'preference',
          'topic': 'preferences',
          'content': 'Primary remembered preference',
        },
      ],
    }, callerIn(primarySession.id, 'turn-1', turn: TurnProvenance.web(sessionKey: 'agent:main:web:abc')));
    await observe.callWithContext({
      'text': 'Journal learning',
      'role': 'learning',
    }, callerIn(journalSession.id, 'journal-turn', turn: const TurnProvenance.cron(jobId: MemoryJournal.jobId)));

    // Without its own branch a curation write inherits the generic turn origin, and
    // the corpus silently loses the distinction it records today.
    await apply.callWithContext({
      'expectedRevision': (await storage.memoryCorpus.readCorpus()).index.metadata.revision,
      'operations': [
        {'kind': 'add', 'correlationId': 'curated', 'topic': 'preferences', 'content': 'Curated remembered preference'},
      ],
    }, callerIn(curationSession.id, 'curation-turn', turn: const TurnProvenance.cron(jobId: memoryCurationJobId)));

    final corpus = await storage.memoryCorpus.readCorpus();
    final topicEntries = corpus.topics.expand((topic) => topic.entries).toList();
    final primary = topicEntries.singleWhere((entry) => entry.content == 'Primary remembered preference').provenance;
    final curated = topicEntries.singleWhere((entry) => entry.content == 'Curated remembered preference').provenance;
    final journal = corpus.learnings!.entries.singleWhere((entry) => entry.content == 'Journal learning').provenance;
    expect(primary.originKind, MemoryOriginKind.turn);
    expect(primary.sourceLocator, 'session:${primarySession.id}');
    expect(primary.sourceEvent, 'turn:turn-1');
    expect(primary.sessionRef, primarySession.id);
    expect(journal.originKind, MemoryOriginKind.journal);
    expect(journal.sourceLocator, 'memory-journal');
    expect(journal.sourceEvent, 'turn:journal-turn');
    expect(journal.caller, 'cron:memory-journal');
    expect(journal.sessionRef, journalSession.id);
    expect(curated.originKind, MemoryOriginKind.curation);
    expect(curated.sourceLocator, 'memory-curation');
    expect(curated.sourceEvent, 'turn:curation-turn');
    expect(curated.caller, 'cron:memory-curation');
    expect(curated.sessionRef, curationSession.id);
  });

  test('production memory handlers reopen native KG and inbox locators', () async {
    final factId = await storage.kg.addFact(
      entity: 'Falcon',
      predicate: 'status',
      value: 'green',
      validFrom: '2026-08-12T00:00:00Z',
      source: 'wiki/falcon.md',
    );
    Directory('${config.workspaceDir}/inbox').createSync();
    File('${config.workspaceDir}/inbox/note.md').writeAsStringSync('Native inbox detail');

    final fact = _decode(await harnessWiring.memoryHandlers.read({'locator': '$factId'}, _captureContext));
    final inbox = _decode(await harnessWiring.memoryHandlers.read({'locator': 'inbox/note.md'}, _captureContext));

    expect(((fact['results'] as List).single as Map)['role'], 'kg');
    expect(((inbox['results'] as List).single as Map)['content'], 'Native inbox detail');
  });
}

Map<String, dynamic> _decode(Map<String, dynamic> response) =>
    jsonDecode(((response['content'] as List).single as Map<String, dynamic>)['text'] as String)
        as Map<String, dynamic>;
