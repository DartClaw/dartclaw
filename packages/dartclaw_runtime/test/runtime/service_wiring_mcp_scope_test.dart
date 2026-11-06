import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_runtime/src/auth/source_link_token.dart';
import 'package:dartclaw_runtime/src/mcp/mcp_server.dart'
    show McpCaller, McpCallerIdentity, McpCallerPolicy, McpKnowledgeScope, McpProtocolHandler, mcpStewardPrincipal;
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' show Request;
import 'package:test/test.dart';

import '../mcp/mcp_test_support.dart' show harnessRunning;

Never _unexpectedExit(int code) => throw StateError('Unexpected exit($code)');

void main() {
  late Directory root;
  late DartclawRuntime runtime;
  late List<Map<String, dynamic>> curationResults;
  late String agentDir;
  // What a host harness does mid-turn: call back into `/mcp` with the bearer it was spawned with.
  Future<void> Function(_ImmediateHarness harness)? duringTurn;

  setUp(() async {
    duringTurn = null;
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
          (factoryConfig) =>
              _ImmediateHarness(factoryConfig, duringTurn: (harness) async => await duringTurn?.call(harness)),
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
      final handler = _asCaller(
        runtime.server!.mcpHandler,
        const _AllowMemoryAndContext(),
        McpCallerIdentity(authorityId: 'agent:a', sessionId: agent.id, agentId: 'a'),
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
      duringTurn = (harness) async {
        if (harness.activeTurnContext?.agentName != 'cron:memory-curation:a') return;
        final prompt = harness.lastMessages!.single['content'] as String;
        final revision = int.parse(RegExp(r'expectedRevision (\d+)').firstMatch(prompt)!.group(1)!);
        final raw = await _mcpCall(runtime, harness.bearer, 'memory_apply', {
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
        });
        final result = (jsonDecode(raw) as Map<String, dynamic>)['result'] as Map<String, dynamic>;
        expect(result['isError'], isNull, reason: raw);
        curationResults.add(
          jsonDecode(((result['content'] as List).single as Map<String, dynamic>)['text'] as String)
              as Map<String, dynamic>,
        );
      };
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

      final client = _asCaller(
        runtime.server!.mcpHandler,
        const _AllowContextOnly(),
        const McpCallerIdentity(authorityId: 'mcp-client:ide', knowledgeScope: McpKnowledgeScope.sharedOnly),
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

      final denied = _asCaller(
        runtime.server!.mcpHandler,
        const _AllowMemoryOnly(),
        McpCallerIdentity(authorityId: 'agent:a', sessionId: agent.id, agentId: 'a'),
      );
      expect(await _callRaw(denied, 'context_research', {'query': 'owner'}), contains('Tool not available'));
    },
  );

  test('agent memory search suppresses stale rows when its workspace index health is degraded', () async {
    final agent = await runtime.sessionService.createSession(
      workspace: AgentWorkspace.pinned(agentId: 'a', directory: agentDir),
    );
    final handler = _asCaller(
      runtime.server!.mcpHandler,
      const _AllowMemoryOnly(),
      McpCallerIdentity(authorityId: 'agent:a', sessionId: agent.id, agentId: 'a'),
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
    final missingIdentity = _asCaller(runtime.server!.mcpHandler, const _AllowMemoryOnly());
    final forged = _asCaller(
      runtime.server!.mcpHandler,
      const _AllowMemoryOnly(),
      McpCallerIdentity(authorityId: 'agent:b', sessionId: agent.id, agentId: 'b'),
    );
    final forgedCron = _asCaller(
      runtime.server!.mcpHandler,
      const _AllowMemoryOnly(),
      McpCallerIdentity(authorityId: 'cron:forged', sessionId: agent.id, agentId: 'cron:forged'),
    );

    // The steward's authority id alone is not the deployment: only `McpCaller.deployment` reaches owner scope.
    final stewardNamed = _asCaller(
      runtime.server!.mcpHandler,
      const _AllowMemoryOnly(),
      const McpCallerIdentity(authorityId: mcpStewardPrincipal),
    );

    expect(await _callRaw(missingIdentity, 'memory_search', {'query': 'owner'}), contains('authenticated caller'));
    expect(
      await _callRaw(stewardNamed, 'memory_search', {'query': 'owner'}),
      allOf(contains('requires a pinned session workspace'), isNot(contains('owner-service-marker'))),
    );
    final forgedResult = await _callRaw(forged, 'memory_search', {'query': 'owner'});
    expect(forgedResult, allOf(contains('Tool execution failed'), contains('does not match')));
    expect(forgedResult, isNot(contains('owner-service-marker')));
    expect(
      await _callRaw(forgedCron, 'memory_search', {'query': 'owner'}),
      allOf(contains('Tool execution failed'), contains('does not match'), isNot(contains('owner-service-marker'))),
    );

    final missingResearch = _asCaller(runtime.server!.mcpHandler, const _AllowContextOnly());
    final forgedResearch = _asCaller(
      runtime.server!.mcpHandler,
      const _AllowContextOnly(),
      McpCallerIdentity(authorityId: 'agent:b', sessionId: agent.id, agentId: 'b'),
    );
    final reclassifiedClient = _asCaller(
      runtime.server!.mcpHandler,
      const _AllowContextOnly(),
      const McpCallerIdentity(authorityId: 'mcp-client:ide'),
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
    final handler = _asCaller(
      runtime.server!.mcpHandler,
      const _AllowDurableWrites(),
      McpCallerIdentity(authorityId: 'temporary:${temporary.id}', sessionId: temporary.id, agentId: 'main'),
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
    final handler = _asCaller(
      runtime.server!.mcpHandler,
      const _AllowMemoryAndContext(),
      McpCallerIdentity(authorityId: 'agent:a', sessionId: agent.id, agentId: 'a'),
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

  group('host harness bearer', () {
    // A host harness (the `claude` or `codex` CLI DartClaw spawns) calls `/mcp` with the bearer minted for it. The
    // call runs through the real server route, so the bearer, the identity it resolves and the tool are all live.
    Future<String> mcpCall(String bearer, String tool, Map<String, dynamic> arguments) =>
        _mcpCall(runtime, bearer, tool, arguments);

    // Runs one turn, as a logical agent's spawned session or as the owner's chat, and has the harness running it
    // research from inside it. Other turns the research itself starts (the synthesizer's) are left alone.
    Future<String> researchDuringTurn({
      String? agent,
      Future<void> Function(_ImmediateHarness harness)? beforeCall,
    }) async {
      late String answer;
      duringTurn = (harness) async {
        if (harness.activeTurnContext?.agentName != (agent ?? 'main')) return;
        await beforeCall?.call(harness);
        answer = await mcpCall(harness.bearer, 'context_research', {'query': 'service-marker'});
      };
      if (agent != null) {
        await _callRaw(runtime.server!.mcpHandler, 'sessions_spawn', {'agent': agent, 'message': 'research'});
        return answer;
      }
      final owner = await runtime.sessionService.createSession();
      final turnId = await runtime.server!.turns.reserveTurn(
        owner.id,
        agentName: 'main',
        workerPolicy: const ExecutionPolicy.host(),
      );
      runtime.server!.turns.executeTurn(
        owner.id,
        turnId,
        const [
          {'role': 'user', 'content': 'research'},
        ],
        source: 'api',
        agentName: 'main',
      );
      await runtime.server!.turns.waitForOutcome(owner.id, turnId);
      return answer;
    }

    test('a logical agent researches its own private scope plus the shared sources', () async {
      final answer = await researchDuringTurn(agent: 'a');

      expect(answer, isNot(contains('"isError":true')));
      expect(answer, allOf(contains('agent-service-marker'), contains('shared-service-marker')));
      expect(answer, isNot(anyOf(contains('owner-service-marker'), contains('agent-wiki-boundary-marker'))));
    });

    test('the owner researches owner scope, never an agent private scope', () async {
      final answer = await researchDuringTurn();

      expect(answer, isNot(contains('"isError":true')));
      expect(answer, allOf(contains('owner-service-marker'), contains('shared-service-marker')));
      expect(answer, isNot(contains('agent-service-marker')));
    });

    test('an agent bearer is refused for a turn bound to the owner session, so it never reads owner memory', () async {
      final owner = await runtime.sessionService.createSession();

      final answer = await researchDuringTurn(
        agent: 'a',
        beforeCall: (harness) async => harness.setTurnContext(
          HarnessTurnContext(sessionId: owner.id, turnId: 'forged', source: 'api', agentName: 'a'),
        ),
      );

      expect(answer, allOf(contains('"isError":true'), contains('no pinned memory workspace')));
      expect(answer, isNot(anyOf(contains('owner-service-marker'), contains('shared-service-marker'))));
    });

    test('a bearer is refused for a contextual tool once its turn has ended', () async {
      late String bearer;
      await researchDuringTurn(agent: 'a', beforeCall: (harness) async => bearer = harness.bearer);

      final answer = await mcpCall(bearer, 'context_research', {'query': 'service-marker'});

      expect(answer, allOf(contains('"isError":true'), contains('authenticated caller')));
      expect(answer, isNot(anyOf(contains('owner-service-marker'), contains('agent-service-marker'))));
    });

    test('an agent memory journal and curation run through /mcp and land in the agent corpus', () async {
      final answers = <String, String>{};
      duringTurn = (harness) async {
        switch (harness.activeTurnContext?.agentName) {
          case 'cron:memory-journal:a':
            answers['journal'] = await mcpCall(harness.bearer, 'memory_observe', {
              'text': 'agent-journal-marker',
              'role': 'observation',
            });
          case 'cron:memory-curation:a':
            final prompt = harness.lastMessages!.single['content'] as String;
            final revision = int.parse(RegExp(r'expectedRevision (\d+)').firstMatch(prompt)!.group(1)!);
            answers['curation'] = await mcpCall(harness.bearer, 'memory_apply', {
              'expectedRevision': revision,
              'operations': [
                {'kind': 'add', 'correlationId': 'curated', 'topic': 'general', 'content': 'agent-curated-marker'},
              ],
            });
        }
      };

      Future<void> runJob(String jobId, String answer) async {
        expect(runtime.scheduleService!.runJobNow(jobId), RunScheduledJobResult.started);
        for (var attempt = 0; attempt < 200 && !answers.containsKey(answer); attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }

      await runJob('memory-journal:a', 'journal');
      await runJob('memory-curation:a', 'curation');

      expect(answers['journal'], isNot(contains('"isError":true')));
      expect(answers['curation'], isNot(contains('"isError":true')));
      final agentCorpus = MemoryCorpusService(workspaceDir: agentDir);
      final ownerCorpus = MemoryCorpusService(workspaceDir: p.join(root.path, 'workspace'));
      addTearDown(agentCorpus.close);
      addTearDown(ownerCorpus.close);
      final agent = await agentCorpus.readCorpus();
      final journal = agent.observations
          .expand((day) => day.observations)
          .singleWhere((entry) => entry.content == 'agent-journal-marker');
      expect(
        (journal.provenance.originKind, journal.provenance.sourceLocator),
        (MemoryOriginKind.journal, 'memory-journal:a'),
      );
      final curated = agent.topics
          .expand((topic) => topic.entries)
          .singleWhere((entry) => entry.content == 'agent-curated-marker');
      expect(
        (curated.provenance.originKind, curated.provenance.sourceLocator),
        (MemoryOriginKind.curation, 'memory-curation:a'),
      );
      final owner = await ownerCorpus.readCorpus();
      expect(
        owner.observations.expand((day) => day.observations).map((entry) => entry.content),
        isNot(contains('agent-journal-marker')),
      );
      expect(
        owner.topics.expand((topic) => topic.entries).map((entry) => entry.content),
        isNot(contains('agent-curated-marker')),
      );
    });

    test('a turn that only claims a scheduled job, with no cron provenance, is refused agent memory', () async {
      final agentSession = await runtime.sessionService.createSession(
        type: SessionType.cron,
        workspace: AgentWorkspace.pinned(agentId: 'a', directory: agentDir),
      );
      late String answer;
      duringTurn = (harness) async {
        if (harness.activeTurnContext?.agentName != 'main') return;
        // The primary harness names the agent's journal job and session, but the host fired no cron turn.
        harness.setTurnContext(
          HarnessTurnContext(
            sessionId: agentSession.id,
            turnId: 'forged',
            source: 'cron',
            agentName: 'cron:memory-journal:a',
            provenance: const TurnProvenance.web(sessionKey: 'agent:main:web:forged'),
          ),
        );
        answer = await mcpCall(harness.bearer, 'memory_observe', {
          'text': 'forged-journal-marker',
          'role': 'observation',
        });
      };
      final owner = await runtime.sessionService.createSession();
      final turnId = await runtime.server!.turns.reserveTurn(
        owner.id,
        agentName: 'main',
        workerPolicy: const ExecutionPolicy.host(),
      );
      runtime.server!.turns.executeTurn(
        owner.id,
        turnId,
        const [
          {'role': 'user', 'content': 'forge'},
        ],
        source: 'api',
        agentName: 'main',
      );
      await runtime.server!.turns.waitForOutcome(owner.id, turnId);

      expect(answer, allOf(contains('"isError":true'), contains('does not match the pinned session workspace')));
      final agentCorpus = MemoryCorpusService(workspaceDir: agentDir);
      addTearDown(agentCorpus.close);
      expect(
        (await agentCorpus.readCorpus()).observations.expand((day) => day.observations).map((entry) => entry.content),
        isNot(contains('forged-journal-marker')),
      );
    });

    test(
      'the shared deployment credential researches and searches owner scope, never an agent private scope',
      () async {
        final research = await _call(runtime.server!.mcpHandler, 'context_research', {'query': 'service-marker'});
        final search = await _call(runtime.server!.mcpHandler, 'memory_search', {'query': 'service-marker'});

        for (final answer in [research, search]) {
          expect(answer, contains('owner-service-marker'));
          expect(answer, isNot(contains('agent-service-marker')));
        }
        expect(research, contains('shared-service-marker'));
      },
    );
  });

  test(
    'a container caller on an agent cron session journals into the agent corpus only under cron provenance',
    () async {
      final cronSession = await runtime.sessionService.createSession(
        type: SessionType.cron,
        workspace: AgentWorkspace.pinned(agentId: 'a', directory: agentDir),
      );
      // What the bridge resolves for a scheduled container turn: the authority's session, no logical agent.
      final identity = McpCallerIdentity(authorityId: 'container-authority', sessionId: cronSession.id);
      final scheduled = _asCaller(
        runtime.server!.mcpHandler,
        const _AllowMemoryOnly(),
        identity,
        () => const TurnProvenance.cron(jobId: 'memory-journal:a'),
      );
      final unscheduled = _asCaller(runtime.server!.mcpHandler, const _AllowMemoryOnly(), identity);
      final sessionless = _asCaller(
        runtime.server!.mcpHandler,
        const _AllowMemoryOnly(),
        const McpCallerIdentity(authorityId: 'primary'),
        () => const TurnProvenance.cron(jobId: 'memory-journal:a'),
      );

      expect(
        await _call(scheduled, 'memory_observe', {'text': 'container-journal-marker', 'role': 'observation'}),
        contains('collectionRevision'),
      );
      expect(
        await _callRaw(unscheduled, 'memory_observe', {'text': 'container-forged-marker', 'role': 'observation'}),
        allOf(contains('"isError":true'), contains('does not match the pinned session workspace')),
      );
      expect(
        await _callRaw(sessionless, 'memory_observe', {'text': 'container-forged-marker', 'role': 'observation'}),
        allOf(contains('"isError":true'), contains('requires a pinned session workspace')),
      );

      final agentCorpus = MemoryCorpusService(workspaceDir: agentDir);
      addTearDown(agentCorpus.close);
      final observations = (await agentCorpus.readCorpus()).observations.expand((day) => day.observations).toList();
      final journal = observations.singleWhere((entry) => entry.content == 'container-journal-marker');
      expect(
        (journal.provenance.originKind, journal.provenance.sourceLocator),
        (MemoryOriginKind.journal, 'memory-journal:a'),
      );
      expect(observations.map((entry) => entry.content), isNot(contains('container-forged-marker')));
    },
  );

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
    McpProtocolHandler asTurn(TurnProvenance? turn) => runtime.server!.mcpHandler.forCaller(harnessRunning(() => turn));
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
      final handler = open.server!.mcpHandler.forCaller(
        harnessRunning(() => channelTurn(ChannelType.signal, 'anyone')),
      );

      expect(await run(handler, wikiWrite('open-governance')), contains('created'));

      final entries = await gateEntries(p.join(root.path, 'open'));
      expect(entries.single.decision, 'allow');
      expect(entries.single.peerId, 'anyone');
      expect(entries.single.channel, 'signal');
    });

    test('web chat, scheduled turns and the gateway token write as before, unaudited by the gate', () async {
      final callers = <String, McpProtocolHandler>{
        'web chat': asTurn(const TurnProvenance.web(sessionKey: 'agent:main:web:')),
        'scheduled turn': asTurn(const TurnProvenance.cron(jobId: 'test-job')),
        'gateway token': runtime.server!.mcpHandler,
      };

      for (final entry in callers.entries) {
        final slug = 'caller-${entry.key.replaceAll(' ', '-')}';
        expect(await run(entry.value, wikiWrite(slug)), contains('created'), reason: entry.key);
        expect(wikiFile(slug).existsSync(), isTrue, reason: entry.key);
      }
      expect(await gateEntries(root.path), isEmpty);
    });

    test('a temporary conversation is refused with its own message before the gate looks at the sender', () async {
      final temporary = await runtime.sessionService.createSession(retention: ConversationRetention.process);
      final handler = _asCaller(
        runtime.server!.mcpHandler,
        const _AllowDurableWrites(),
        McpCallerIdentity(authorityId: 'temporary:${temporary.id}', sessionId: temporary.id, agentId: 'main'),
        () => channelTurn(ChannelType.whatsapp, 'admin-a'),
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
      final handler = _asCaller(
        runtime.server!.mcpHandler,
        const _AllowMemoryAndContext(),
        McpCallerIdentity(authorityId: 'agent:a', sessionId: agent.id, agentId: 'a'),
        () => channelTurn(ChannelType.whatsapp, 'sender-b'),
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

Future<String> _mcpCall(DartclawRuntime runtime, String bearer, String tool, Map<String, dynamic> arguments) async {
  final response = await runtime.server!.handler(
    Request(
      'POST',
      Uri.parse('http://localhost/mcp'),
      headers: {'host': 'localhost', 'authorization': 'Bearer $bearer', 'content-type': 'application/json'},
      body: jsonEncode({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/call',
        'params': {'name': tool, 'arguments': arguments},
      }),
    ),
  );
  expect(response.statusCode, 200);
  return response.readAsString();
}

/// A transport-authenticated caller the way the container bridge resolves one: [identity], [policy], the guard chain
/// judging the call under its names.
McpProtocolHandler _asCaller(
  McpProtocolHandler root,
  McpCallerPolicy policy, [
  McpCallerIdentity? identity,
  TurnProvenance? Function()? turn,
]) =>
    root.forCaller(McpCaller(identity: () => identity, turn: turn ?? () => null, policy: policy, guardsAsCaller: true));

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

class _ImmediateHarness extends FakeAgentHarness implements HarnessTurnContextSink {
  new(this.config, {required this.duringTurn}) : super(supportsNoWorkTools: true);

  final HarnessFactoryConfig config;
  final Future<void> Function(_ImmediateHarness harness) duringTurn;

  @override
  HarnessTurnContext? activeTurnContext;

  @override
  void setTurnContext(HarnessTurnContext? context) => activeTurnContext = context;

  String get bearer => config.harnessConfig.mcpGatewayToken!;

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
    lastMessages = messages;
    await duringTurn(this);
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
