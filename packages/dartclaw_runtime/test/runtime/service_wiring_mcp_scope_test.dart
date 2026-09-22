import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_runtime/src/mcp/mcp_server.dart' show McpCallerIdentity, McpCallerPolicy, McpProtocolHandler;
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Never _unexpectedExit(int code) => throw StateError('Unexpected exit($code)');

void main() {
  late Directory root;
  late DartclawRuntime runtime;
  late List<Map<String, dynamic>> curationResults;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('service_memory_scope_');
    curationResults = [];
    final agentDir = p.join(root.path, 'agent-a');
    final config = DartclawConfig(
      server: ServerConfig(dataDir: root.path, claudeExecutable: Platform.resolvedExecutable),
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
    await seedCanonicalMemory(
      agentDir,
      topics: const {
        'general': ['agent-service-marker'],
      },
    );
    File(p.join(config.workspaceDir, 'wiki', 'owner.md'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('owner-wiki-boundary-marker');
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
        workspace: AgentWorkspace.pinned(agentId: 'a', directory: p.join(root.path, 'agent-a')),
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
      final agentLogs = Directory(p.join(root.path, 'agent-a', 'memory'))
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
              .having((session) => session.workspace?.directory, 'directory', p.join(root.path, 'agent-a')),
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

      final beforeContext = File(p.join(root.path, 'agent-a', 'MEMORY.md')).readAsBytesSync();
      final researched = await _call(handler, 'context_research', {'query': 'owner-wiki-boundary-marker'});
      expect(researched, allOf(contains('owner-wiki-boundary-marker'), contains('"layer":"wiki"')));
      expect(researched, isNot(contains('agent-wiki-boundary-marker')));
      expect(File(p.join(root.path, 'agent-a', 'MEMORY.md')).readAsBytesSync(), beforeContext);
      final audit = await AuditLogReader(dataDir: root.path).read(pageSize: 100);
      expect(
        audit.entries,
        contains(
          isA<AuditEntry>()
              .having((entry) => entry.principal, 'principal', 'agent:a')
              .having((entry) => entry.tool, 'tool', 'context_research'),
        ),
      );

      final agentCorpus = MemoryCorpusService(workspaceDir: p.join(root.path, 'agent-a'));
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
    final agentDir = p.join(root.path, 'agent-a');
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
      workspace: AgentWorkspace.pinned(agentId: 'a', directory: p.join(root.path, 'agent-a')),
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
