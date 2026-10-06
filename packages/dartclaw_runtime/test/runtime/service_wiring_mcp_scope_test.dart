import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_runtime/src/auth/source_link_token.dart';
import 'package:dartclaw_runtime/src/mcp/mcp_server.dart'
    show McpCallerIdentity, McpCallerPolicy, McpKnowledgeScope, McpProtocolHandler;
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Never _unexpectedExit(int code) => throw StateError('Unexpected exit($code)');

void main() {
  late Directory root;
  late DartclawRuntime runtime;
  late List<Map<String, dynamic>> curationResults;
  late String agentDir;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('service_memory_scope_');
    curationResults = [];
    agentDir = p.join(root.path, 'agents', 'a', 'workspace');
    final config = DartclawConfig(
      server: ServerConfig(
        dataDir: root.path,
        claudeExecutable: Platform.resolvedExecutable,
        baseUrl: 'https://dartclaw.example',
      ),
      governance: const GovernanceConfig(adminSenders: ['admin-a']),
      agent: AgentConfig(
        provider: 'claude',
        definitions: [
          const AgentDefinition(
            id: 'search',
            description: 'Search synthesizer',
            prompt: 'Synthesize supplied candidates.',
            execution: ExecutionMode.host,
          ),
          AgentDefinition(
            id: 'a',
            description: 'Agent A',
            prompt: 'A',
            allowedTools: const {'memory_search', 'memory_read', 'memory_observe', 'memory_apply', 'context_research'},
            workspace: AgentWorkspace.pinned(agentId: 'a', directory: agentDir),
          ),
        ],
      ),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
      ),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'test-key')}),
      gateway: const GatewayConfig(authMode: 'none'),
      memory: MemoryConfig(journalEnabled: true, curationEnabled: true),
      security: const SecurityConfig(contentGuardEnabled: false),
    );
    await seedCanonicalMemory(
      config.workspaceDir,
      topics: const {
        'general': ['owner-service-marker'],
      },
    );
    await WorkspaceService(dataDir: root.path)
        .prepareManagedAgents([AgentWorkspace.pinned(agentId: 'a', directory: agentDir)]);
    await seedCanonicalMemory(
      agentDir,
      topics: const {
        'general': ['agent-service-marker'],
      },
    );
    File(p.join(config.workspaceDir, 'wiki', 'owner.md'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('owner-wiki-boundary-marker shared-service-marker');
    File(p.join(agentDir, 'wiki', 'agent.md'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('agent-wiki-boundary-marker');
    final configFile = File(p.join(root.path, 'dartclaw.yaml'))..writeAsStringSync('# test config\n');
    final searchIndexes = <PostgresFtsTable, InMemoryFullTextIndex>{};
    runtime = await DartclawRuntime.build(
      config,
      dataDir: root.path,
      port: 3000,
      harnessFactory: HarnessFactory()
        ..register(
          'claude',
          (factoryConfig) => _ImmediateHarness(factoryConfig, onCurationResult: curationResults.add),
        ),
      taskBackendFactory: (_) async => openPreparedTaskBackend(),
      taskBackendIsPrepared: true,
      searchIndexFactory: (_, table, {required withinTransaction}) =>
          searchIndexes.putIfAbsent(table, InMemoryFullTextIndex.new),
      stderrLine: (_) {},
      exitFn: _unexpectedExit,
      resolvedConfigPath: configFile.path,
      messageRedactor: MessageRedactor(),
      resolvedAssets: const ResolvedAssets.embedded(),
      runWorkflowSkillsBootstrap: false,
    );
  });

  tearDown(() async {
    await runtime.shutdown();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test(
    'ordinary memory follows the authenticated pinned session while context research stays separately granted',
    () async {
      final agent = await runtime.sessionService.createSession(
        workspace: AgentWorkspace.pinned(agentId: 'a', directory: agentDir),
      );
      final handler = runtime.server!.mcpHandler.scopedTo(
        const _AllowMemoryAndContext(),
        callerIdentity: McpCallerIdentity(authorityId: 'agent:a', sessionId: agent.id, agentId: 'a'),
      );

      final turnId = await runtime.server!.turns.reserveTurn(
        agent.id,
        agentName: 'a',
        workerPolicy: const ExecutionPolicy.host(),
      );
      runtime.server!.turns.executeTurn(
        agent.id,
        turnId,
        const [
          {'role': 'user', 'content': 'agent-runtime-daily-log-marker'},
        ],
        source: 'api',
        agentName: 'a',
      );
      await runtime.server!.turns.waitForOutcome(agent.id, turnId);
      final agentLogs = Directory(p.join(agentDir, 'memory'))
          .listSync()
          .whereType<File>()
          .map((file) => file.readAsStringSync())
          .join();
      expect(agentLogs, contains('agent-runtime-daily-log-marker'));
      final ownerMemoryDir = Directory(p.join(root.path, 'workspace', 'memory'));
      final ownerLogs = ownerMemoryDir.existsSync()
          ? ownerMemoryDir.listSync().whereType<File>().map((file) => file.readAsStringSync()).join()
          : '';
      expect(ownerLogs, isNot(contains('agent-runtime-daily-log-marker')));

      expect(runtime.scheduleService!.runJobNow('memory-journal:a'), RunScheduledJobResult.started);
      for (var attempt = 0; attempt < 100; attempt++) {
        final cron = await runtime.sessionService.listSessions(type: SessionType.cron);
        if (cron.any((session) => session.workspace?.storagePrincipal == 'agent:a')) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final cron = await runtime.sessionService.listSessions(type: SessionType.cron);
      expect(
        cron,
        contains(
          isA<Session>()
              .having((session) => session.workspace?.storagePrincipal, 'principal', 'agent:a')
              .having((session) => session.workspace?.directory, 'directory', agentDir),
        ),
      );
      expect(runtime.scheduleService!.runJobNow('memory-curation:a'), RunScheduledJobResult.started);
      for (var attempt = 0; attempt < 100 && curationResults.isEmpty; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(curationResults.single['canonicalOutcome'], 'rejected');
      expect(
        ((curationResults.single['operations'] as Map)['outside-snapshot'] as Map)['reason'],
        'targetId was not included in the bounded snapshot',
      );

      final search = await _call(handler, 'memory_search', {'query': 'service-marker'});
      expect(search, contains('agent-service-marker'));
      expect(search, isNot(contains('owner-service-marker')));
      final wikiSearch = await _call(handler, 'memory_search', {'query': 'wiki-boundary-marker'});
      expect(wikiSearch, isNot(anyOf(contains('owner-wiki-boundary-marker'), contains('agent-wiki-boundary-marker'))));
      final wikiRead = await _call(handler, 'memory_read', {'locator': 'wiki/agent.md'});
      expect(wikiRead, isNot(contains('agent-wiki-boundary-marker')));
      final observed = await _call(handler, 'memory_observe', {
        'text': 'agent-observed-service-marker',
        'role': 'observation',
      });
      expect(observed, contains('collectionRevision'));
      expect(runtime.server!.mcpHandler.toolNames, contains('context_research'));

      final beforeContext = File(p.join(agentDir, 'MEMORY.md')).readAsBytesSync();
      final researched = await _call(handler, 'context_research', {'query': 'service-marker'});
      expect(
        researched,
        allOf(contains('agent-service-marker'), contains('shared-service-marker'), contains('"layer":"wiki"')),
      );
      expect(researched, isNot(anyOf(contains('owner-service-marker'), contains('agent-wiki-boundary-marker'))));
      expect(File(p.join(agentDir, 'MEMORY.md')).readAsBytesSync(), beforeContext);

      final client = runtime.server!.mcpHandler.scopedTo(
        const _AllowContextOnly(),
        callerIdentity: const McpCallerIdentity(
          authorityId: 'mcp-client:ide',
          knowledgeScope: McpKnowledgeScope.sharedOnly,
        ),
      );
      final clientResearch = await _call(client, 'context_research', {'query': 'service-marker'});
      expect(clientResearch, contains('shared-service-marker'));
      expect(clientResearch, isNot(anyOf(contains('owner-service-marker'), contains('agent-service-marker'))));
      final audit = await AuditLogReader(dataDir: root.path).read(pageSize: 100);
      expect(
        audit.entries,
        contains(
          isA<AuditEntry>()
              .having((entry) => entry.principal, 'principal', 'agent:a')
              .having((entry) => entry.tool, 'tool', 'context_research'),
        ),
      );

      final agentCorpus = MemoryCorpusService(workspaceDir: agentDir);
      final ownerCorpus = MemoryCorpusService(workspaceDir: p.join(root.path, 'workspace'));
      addTearDown(agentCorpus.close);
      addTearDown(ownerCorpus.close);
      expect(
        (await agentCorpus.readCorpus()).observations
            .expand((day) => day.observations)
            .singleWhere((entry) => entry.content == 'agent-observed-service-marker')
            .content,
        'agent-observed-service-marker',
      );
      expect((await ownerCorpus.readCorpus()).observations, isEmpty);

      final denied = runtime.server!.mcpHandler.scopedTo(
        const _AllowMemoryOnly(),
        callerIdentity: McpCallerIdentity(authorityId: 'agent:a', sessionId: agent.id, agentId: 'a'),
      );
      expect(await _callRaw(denied, 'context_research', {'query': 'owner'}), contains('Tool not available'));
    },
  );

  test('agent memory search suppresses stale rows when its workspace index health is degraded', () async {
    final agent = await runtime.sessionService.createSession(
      workspace: AgentWorkspace.pinned(agentId: 'a', directory: agentDir),
    );
    final handler = runtime.server!.mcpHandler.scopedTo(
      const _AllowMemoryOnly(),
      callerIdentity: McpCallerIdentity(authorityId: 'agent:a', sessionId: agent.id, agentId: 'a'),
    );
    expect(await _call(handler, 'memory_search', {'query': 'agent-service-marker'}), contains('agent-service-marker'));
    final corpus = MemoryCorpusService(workspaceDir: agentDir);
    addTearDown(corpus.close);
    final manifest = await corpus.manifest();
    await IndexHealthStore(workspaceDir: agentDir).recordDegraded(
      canonicalRevision: manifest.collectionRevision,
      canonicalFingerprint: manifest.fingerprint,
      stage: 'incrementalProjection',
      reason: StateError('projection failed'),
    );

    final stale = await _call(handler, 'memory_search', {'query': 'agent-service-marker'});

    expect(stale, isNot(contains('agent-service-marker')));
    expect(stale, allOf(contains('"degradedLayers":["memory"]'), contains('"reason":"indexNotCurrent"')));
  });

  test('missing or forged caller binding cannot fall back to owner memory', () async {
    final agent = await runtime.sessionService.createSession(
      workspace: AgentWorkspace.pinned(agentId: 'a', directory: agentDir),
    );
    final missingIdentity = runtime.server!.mcpHandler.scopedTo(const _AllowMemoryOnly());
    final forged = runtime.server!.mcpHandler.scopedTo(
      const _AllowMemoryOnly(),
      callerIdentity: McpCallerIdentity(authorityId: 'agent:b', sessionId: agent.id, agentId: 'b'),
    );
    final forgedCron = runtime.server!.mcpHandler.scopedTo(
      const _AllowMemoryOnly(),
      callerIdentity: McpCallerIdentity(authorityId: 'cron:forged', sessionId: agent.id, agentId: 'cron:forged'),
    );

    expect(await _callRaw(missingIdentity, 'memory_search', {'query': 'owner'}), contains('authenticated caller'));
    final forgedResult = await _callRaw(forged, 'memory_search', {'query': 'owner'});
    expect(forgedResult, allOf(contains('Tool execution failed'), contains('does not match')));
    expect(forgedResult, isNot(contains('owner-service-marker')));
    expect(
      await _callRaw(forgedCron, 'memory_search', {'query': 'owner'}),
      allOf(contains('Tool execution failed'), contains('does not match'), isNot(contains('owner-service-marker'))),
    );

    final missingResearch = runtime.server!.mcpHandler.scopedTo(const _AllowContextOnly());
    final forgedResearch = runtime.server!.mcpHandler.scopedTo(
      const _AllowContextOnly(),
      callerIdentity: McpCallerIdentity(authorityId: 'agent:b', sessionId: agent.id, agentId: 'b'),
    );
    final reclassifiedClient = runtime.server!.mcpHandler.scopedTo(
      const _AllowContextOnly(),
      callerIdentity: const McpCallerIdentity(authorityId: 'mcp-client:ide'),
    );
    expect(await _callRaw(missingResearch, 'context_research', {'query': 'owner'}), contains('authenticated caller'));
    expect(
      await _callRaw(forgedResearch, 'context_research', {'query': 'owner'}),
      allOf(contains('scope denied'), contains('does not match'), isNot(contains('owner-service-marker'))),
    );
    expect(
      await _callRaw(reclassifiedClient, 'context_research', {'query': 'owner'}),
      allOf(contains('scope denied'), contains('cannot acquire private research scope')),
    );
  });

  test('temporary caller context refuses personal and shared durable writes through registered tools', () async {
    final temporary = await runtime.sessionService.createSession(retention: ConversationRetention.process);
    final handler = runtime.server!.mcpHandler.scopedTo(
      const _AllowDurableWrites(),
      callerIdentity: McpCallerIdentity(
        authorityId: 'temporary:${temporary.id}',
        sessionId: temporary.id,
        agentId: 'main',
      ),
    );

    final observe = await _callRaw(handler, 'memory_observe', {
      'text': 'temporary private marker',
      'role': 'observation',
    });
    final wiki = await _callRaw(handler, 'wiki_write', {
      'slug': 'temporary-shared-marker',
      'title': 'Temporary Shared Marker',
      'body': 'This must not become durable shared knowledge.',
      'sources': ['temporary'],
    });
    final kg = await _callRaw(handler, 'kg_add', {
      'entity': 'Temporary shared marker',
      'predicate': 'status',
      'value': 'must not persist',
      'valid_from': '2026-09-22T00:00:00Z',
      'source': 'temporary',
    });

    expect(observe, contains('Temporary conversations cannot write memory'));
    expect(wiki, contains('Temporary conversations cannot write durable knowledge'));
    expect(kg, contains('Temporary conversations cannot write durable knowledge'));
    expect(File(p.join(root.path, 'workspace', 'wiki', 'temporary-shared-marker.md')).existsSync(), isFalse);
    expect(
      await _call(runtime.server!.mcpHandler, 'kg_query', {'entity': 'Temporary shared marker'}),
      contains('"status":"no_result"'),
    );
  });

  test('context_research links wiki and graph sources under base_url and leaves memory sources bare', () async {
    final agent = await runtime.sessionService.createSession(
      workspace: AgentWorkspace.pinned(agentId: 'a', directory: agentDir),
    );
    final handler = runtime.server!.mcpHandler.scopedTo(
      const _AllowMemoryAndContext(),
      callerIdentity: McpCallerIdentity(authorityId: 'agent:a', sessionId: agent.id, agentId: 'a'),
    );

    final researched = jsonDecode(await _call(handler, 'context_research', {'query': 'service-marker'})) as Map;
    final sources = ((researched['packet'] as Map)['sourceList'] as List).cast<Map<String, dynamic>>();

    final wiki = sources.firstWhere((source) => source['layer'] == 'wiki');
    expect(wiki['url'], startsWith('https://dartclaw.example/knowledge/source?t='));
    // auth_mode none: the token carries no signature and names the cited page.
    expect(validateSourceLinkToken(Uri.parse(wiki['url'] as String).queryParameters['t']!), (
      layer: 'wiki',
      locator: 'wiki/owner.md',
    ));
    final memory = sources.where((source) => source['layer'] == 'memory');
    expect(memory, isNotEmpty);
    expect(memory.where((source) => source.containsKey('url')), isEmpty);
  });

  group('shared knowledge write gate', () {
    // The runtime fixture's prepared backend stores no KG rows, so a granted kg_add cannot complete here: the
    // refusal arm runs through the registered tools, and the allow arm through wiki_write.
    final kgAdd = (
      tool: 'kg_add',
      args: <String, dynamic>{
        'entity': 'gate test',
        'predicate': 'status',
        'value': 'recorded',
        'valid_from': '2026-10-06T00:00:00Z',
        'source': 'gate-test',
      },
    );
    final kgInvalidate = (
      tool: 'kg_invalidate',
      args: <String, dynamic>{'id': 1, 'invalidated_at': '2026-10-06T00:00:00Z', 'reason': 'gate-test'},
    );
    ({String tool, Map<String, dynamic> args}) wikiWrite(String slug) => (
      tool: 'wiki_write',
      args: {
        'slug': slug,
        'title': 'Gate Test',
        'body': 'Written during a channel turn.',
        'sources': ['gate-test'],
      },
    );

    TurnProvenance channelTurn(ChannelType type, String sender) => TurnProvenance.channel(
      channelType: type,
      sessionKey: 'agent:main:group:${type.name}:g1',
      recipientId: 'g1',
      senderId: sender,
    );
    McpProtocolHandler asTurn(TurnProvenance? turn) => runtime.server!.mcpHandler.forHarness(() => turn);
    Future<String> run(McpProtocolHandler handler, ({String tool, Map<String, dynamic> args}) call) =>
        _callRaw(handler, call.tool, call.args);
    Future<List<AuditEntry>> gateEntries(String dataDir) async =>
        (await AuditLogReader(dataDir: dataDir).read(pageSize: 200)).entries
            .where((entry) => entry.guard == 'KnowledgeWriteGate')
            .toList();
    File wikiFile(String slug) => File(p.join(root.path, 'workspace', 'wiki', '$slug.md'));

    test(
      'a non-admin channel turn is refused on every shared-write tool and channel, and each attempt is audited',
      () async {
        for (final type in [ChannelType.whatsapp, ChannelType.googlechat]) {
          final handler = asTurn(channelTurn(type, 'sender-b'));
          for (final call in [wikiWrite('denied-${type.name}'), kgAdd, kgInvalidate]) {
            expect(await run(handler, call), contains('admin_senders'), reason: '${call.tool} on ${type.name}');
          }
          expect(wikiFile('denied-${type.name}').existsSync(), isFalse);
        }

        final entries = await gateEntries(root.path);
        expect(entries, hasLength(6));
        expect(entries.map((entry) => entry.decision).toSet(), {'deny'});
        expect(entries.map((entry) => entry.peerId).toSet(), {'sender-b'});
        expect(entries.map((entry) => entry.principal).toSet(), {'sender-b'});
        expect(
          {for (final entry in entries) (entry.tool, entry.channel)},
          {
            for (final tool in ['wiki_write', 'kg_add', 'kg_invalidate'])
              for (final channel in ['whatsapp', 'googlechat']) (tool, channel),
          },
        );
      },
    );

    test('an admin channel turn writes and is audited with its channel and sender', () async {
      final handler = asTurn(channelTurn(ChannelType.whatsapp, 'admin-a'));

      expect(await run(handler, wikiWrite('admin-written')), contains('created'));

      expect(wikiFile('admin-written').existsSync(), isTrue);
      final entries = await gateEntries(root.path);
      expect(entries.map((entry) => (entry.tool, entry.decision, entry.channel, entry.peerId)).toSet(), {
        ('wiki_write', 'allow', 'whatsapp', 'admin-a'),
      });
    });

    test('with no admin_senders configured every channel sender is an admin and is audited', () async {
      final open = await _buildOpenGovernanceRuntime(root);
      addTearDown(open.shutdown);
      final handler = open.server!.mcpHandler.forHarness(() => channelTurn(ChannelType.signal, 'anyone'));

      expect(await run(handler, wikiWrite('open-governance')), contains('created'));

      final entries = await gateEntries(p.join(root.path, 'open'));
      expect(entries.single.decision, 'allow');
      expect(entries.single.peerId, 'anyone');
      expect(entries.single.channel, 'signal');
    });

    test(
      'web chat, scheduled turns, the gateway token and a turn-less caller write as before, unaudited by the gate',
      () async {
        final callers = <String, McpProtocolHandler>{
          'web chat': asTurn(const TurnProvenance.web(sessionKey: 'agent:main:web:')),
          'scheduled turn': asTurn(const TurnProvenance.cron()),
          'no turn': asTurn(null),
          'gateway token': runtime.server!.mcpHandler,
        };

        for (final entry in callers.entries) {
          final slug = 'caller-${entry.key.replaceAll(' ', '-')}';
          expect(await run(entry.value, wikiWrite(slug)), contains('created'), reason: entry.key);
          expect(wikiFile(slug).existsSync(), isTrue, reason: entry.key);
        }
        expect(await gateEntries(root.path), isEmpty);
      },
    );

    test('a temporary conversation is refused with its own message before the gate looks at the sender', () async {
      final temporary = await runtime.sessionService.createSession(retention: ConversationRetention.process);
      final handler = runtime.server!.mcpHandler.scopedTo(
        const _AllowDurableWrites(),
        callerIdentity: McpCallerIdentity(
          authorityId: 'temporary:${temporary.id}',
          sessionId: temporary.id,
          agentId: 'main',
        ),
        activeTurn: () => channelTurn(ChannelType.whatsapp, 'admin-a'),
      );

      expect(
        await run(handler, wikiWrite('temporary-channel')),
        contains('Temporary conversations cannot write durable knowledge'),
      );
      expect(wikiFile('temporary-channel').existsSync(), isFalse);
      expect(await gateEntries(root.path), isEmpty);
    });

    test('memory_observe and memory_apply from a non-admin channel turn are not gated', () async {
      final agent = await runtime.sessionService.createSession(
        workspace: AgentWorkspace.pinned(agentId: 'a', directory: agentDir),
      );
      final handler = runtime.server!.mcpHandler.scopedTo(
        const _AllowMemoryAndContext(),
        callerIdentity: McpCallerIdentity(authorityId: 'agent:a', sessionId: agent.id, agentId: 'a'),
        activeTurn: () => channelTurn(ChannelType.whatsapp, 'sender-b'),
      );

      expect(
        await _call(handler, 'memory_observe', {'text': 'channel observation', 'role': 'observation'}),
        contains('collectionRevision'),
      );
      expect(
        await _callRaw(handler, 'memory_apply', {'expectedRevision': 0, 'operations': []}),
        isNot(contains('admin_senders')),
      );
      expect(await gateEntries(root.path), isEmpty);
    });
  });
}

Future<String> _call(McpProtocolHandler handler, String name, Map<String, dynamic> arguments) async {
  final raw = await _callRaw(handler, name, arguments);
  final decoded = jsonDecode(raw) as Map<String, dynamic>;
  final result = decoded['result'] as Map<String, dynamic>;
  expect(result['isError'], isNull, reason: raw);
  return ((result['content'] as List).single as Map<String, dynamic>)['text'] as String;
}

Future<String> _callRaw(McpProtocolHandler handler, String name, Map<String, dynamic> arguments) async =>
    (await handler.handleRequest(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/call',
        'params': {'name': name, 'arguments': arguments},
      }),
    ))!;

class _AllowMemoryAndContext implements McpCallerPolicy {
  const new();

  @override
  bool allows(String toolName) => toolName.startsWith('memory_') || toolName == 'context_research';

  @override
  void onDenied(String toolName) {}
}

class _AllowMemoryOnly implements McpCallerPolicy {
  const new();

  @override
  bool allows(String toolName) => toolName.startsWith('memory_');

  @override
  void onDenied(String toolName) {}
}

class _AllowContextOnly implements McpCallerPolicy {
  const new();

  @override
  bool allows(String toolName) => toolName == 'context_research';

  @override
  void onDenied(String toolName) {}
}

class _AllowDurableWrites implements McpCallerPolicy {
  const new();

  @override
  bool allows(String toolName) => const {'memory_observe', 'wiki_write', 'kg_add'}.contains(toolName);

  @override
  void onDenied(String toolName) {}
}

class _ImmediateHarness extends FakeAgentHarness {
  new(this.config, {required this.onCurationResult}) : super(supportsNoWorkTools: true);

  final HarnessFactoryConfig config;
  final void Function(Map<String, dynamic> result) onCurationResult;

  @override
  Future<TurnResult> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    String? agentId,
    Map<String, dynamic>? mcpServers,
    String? providerSessionId,
    bool requestProviderSessionResume = false,
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
    Map<String, dynamic>? outputSchema,
  }) async {
    if (agentId == 'cron:memory-curation:a') {
      final prompt = messages.single['content'] as String;
      final revision = int.parse(RegExp(r'expectedRevision (\d+)').firstMatch(prompt)!.group(1)!);
      final result = await config.onContextualMemoryApply!({
        'expectedRevision': revision,
        'operations': [
          {
            'kind': 'remove',
            'correlationId': 'outside-snapshot',
            'targetId': '00000000-0000-4000-8000-0000000000ff',
            'expectedEntryRevision': 1,
            'reason': 'fixture out-of-scope attempt',
          },
        ],
      }, HarnessTurnContext(sessionId: sessionId, turnId: 'curation-turn', source: 'cron', agentName: agentId!));
      final content = (result['content'] as List).single as Map<String, dynamic>;
      onCurationResult(jsonDecode(content['text'] as String) as Map<String, dynamic>);
    }
    emit(ToolUseEvent(toolName: 'file_read', toolId: 'fixture-read', input: const {'path': 'fixture.md'}));
    await Future<void>.delayed(Duration.zero);
    return const TurnResult(finalText: 'Use the supplied owner candidate.');
  }
}

/// A runtime whose governance names no admin senders, so every sender is an admin.
Future<DartclawRuntime> _buildOpenGovernanceRuntime(Directory parent) async {
  final dataDir = Directory(p.join(parent.path, 'open'))..createSync(recursive: true);
  final config = DartclawConfig(
    server: ServerConfig(dataDir: dataDir.path, claudeExecutable: Platform.resolvedExecutable),
    agent: const AgentConfig(provider: 'claude'),
    providers: ProvidersConfig(
      entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0)},
    ),
    credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'test-key')}),
    gateway: const GatewayConfig(authMode: 'none'),
    security: const SecurityConfig(contentGuardEnabled: false),
  );
  final searchIndexes = <PostgresFtsTable, InMemoryFullTextIndex>{};
  return DartclawRuntime.build(
    config,
    dataDir: dataDir.path,
    port: 3000,
    harnessFactory: HarnessFactory()..register('claude', (_) => FakeAgentHarness()),
    taskBackendFactory: (_) async => openPreparedTaskBackend(),
    taskBackendIsPrepared: true,
    searchIndexFactory: (_, table, {required withinTransaction}) =>
        searchIndexes.putIfAbsent(table, InMemoryFullTextIndex.new),
    stderrLine: (_) {},
    exitFn: _unexpectedExit,
    resolvedConfigPath: (File(p.join(dataDir.path, 'dartclaw.yaml'))..writeAsStringSync('# test config\n')).path,
    messageRedactor: MessageRedactor(),
    resolvedAssets: const ResolvedAssets.embedded(),
    runWorkflowSkillsBootstrap: false,
  );
}
