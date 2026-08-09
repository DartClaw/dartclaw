import 'dart:io';

import 'package:dartclaw_cli/src/commands/wiring/harness_wiring.dart';
import 'package:dartclaw_cli/src/commands/wiring/security_wiring.dart';
import 'package:dartclaw_cli/src/commands/wiring/storage_wiring.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide HarnessConfig;
import 'package:dartclaw_server/dartclaw_server.dart'
    show DartclawServer, DartclawServerBuilder, TurnRunnerCancellation;
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

Never _unexpectedExit(int code) {
  throw StateError('Unexpected exit($code) during harness wiring test');
}

/// Polls [read] until [isReady] holds, then returns that value.
///
/// The turn-monitor thresholds under test are milliseconds apart, so a fixed
/// delay sized just past the threshold loses the race under parallel test load.
/// The cap stays far below the 120 s default `stuckAfter`, so reaching the state
/// still proves the configured threshold is the one in effect.
Future<T> _pollFor<T>(T Function() read, bool Function(T) isReady) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  var value = read();
  while (!isReady(value) && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    value = read();
  }
  return value;
}

void main() {
  group('provider-aware delegated model defaults', () {
    final search = AgentDefinition.searchAgent();
    const custom = AgentDefinition(id: 'summarizer', description: 'Summarize', prompt: 'Summarize');
    const explicit = AgentDefinition(id: 'search', description: 'Search', prompt: 'Search', model: 'custom-model');

    test('resolves omitted search model by provider family', () {
      expect(resolveAgentModel(search, 'claude'), 'sonnet');
      expect(resolveAgentModel(search, 'codex'), 'gpt-5.6-luna');
    });

    test('preserves explicit and non-search model behavior', () {
      expect(resolveAgentModel(explicit, 'codex'), 'custom-model');
      expect(resolveAgentModel(custom, 'claude'), isNull);
    });
  });

  late Directory tempDir;
  late Directory workspaceDir;
  late DartclawConfig config;
  late EventBus eventBus;
  late List<HarnessFactoryConfig> recordedConfigs;
  late List<FakeAgentHarness> createdHarnesses;
  StorageWiring? storage;
  SecurityWiring? security;
  HarnessWiring? harnessWiring;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_harness_wiring_');
    config = DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      agent: const AgentConfig(provider: 'claude'),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1)},
      ),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      gateway: const GatewayConfig(authMode: 'none'),
      tasks: const TaskConfig(maxConcurrent: 1),
    );

    workspaceDir = Directory(config.workspaceDir)..createSync(recursive: true);
    File(p.join(workspaceDir.path, 'SOUL.md')).writeAsStringSync('Soul prompt');
    File(p.join(workspaceDir.path, 'USER.md')).writeAsStringSync('User prompt');
    File(p.join(workspaceDir.path, 'TOOLS.md')).writeAsStringSync('Tool prompt');
    File(p.join(workspaceDir.path, 'AGENTS.md')).writeAsStringSync('## Agent prompt');
    File(p.join(workspaceDir.path, 'errors.md')).writeAsStringSync('## Recent error');
    File(p.join(workspaceDir.path, 'learnings.md')).writeAsStringSync('## Recent learning');

    eventBus = EventBus();
    recordedConfigs = <HarnessFactoryConfig>[];
    createdHarnesses = <FakeAgentHarness>[];
  });

  tearDown(() async {
    await harnessWiring?.pool.dispose();
    await security?.dispose();
    await storage?.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

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
    await security!.wire(
      agentDefs: config.agent.definitions.isNotEmpty ? config.agent.definitions : [AgentDefinition.searchAgent()],
    );
  }

  Future<void> wireHarness(HarnessFactory factory) async {
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
    await harnessWiring!.wire(serverRefGetter: () => throw UnimplementedError('serverRefGetter should not be called'));
  }

  HarnessFactory fakeFactory(
    Iterable<String> providerIds, {
    void Function(String providerId, HarnessFactoryConfig)? onCreate,
  }) {
    final factory = HarnessFactory();
    for (final providerId in providerIds) {
      factory.register(providerId, (factoryConfig) {
        onCreate?.call(providerId, factoryConfig);
        final harness = FakeAgentHarness(promptStrategy: PromptStrategy.append);
        createdHarnesses.add(harness);
        return harness;
      });
    }
    return factory;
  }

  Future<List<String>> wireAndCollectHarnessMessages(Iterable<String> providerIds) async {
    final records = <LogRecord>[];
    final subscription = Logger('HarnessWiring').onRecord.listen(records.add);
    try {
      await wireStorageAndSecurity();
      await wireHarness(fakeFactory(providerIds));
      return records.map((record) => record.message).toList();
    } finally {
      await subscription.cancel();
    }
  }

  void configureCodex({
    String providerId = 'codex',
    Map<String, dynamic> options = const {},
    bool restricted = true,
    bool journalEnabled = false,
  }) {
    config = config.copyWith(
      memory: journalEnabled ? const MemoryConfig(journalEnabled: true) : config.memory,
      agent: AgentConfig(
        provider: providerId,
        definitions: [
          AgentDefinition(
            id: 'worker',
            description: 'Worker',
            prompt: 'Work',
            allowedTools: restricted ? const {'web_search'} : const {},
          ),
        ],
      ),
      providers: ProvidersConfig(
        entries: {providerId: ProviderEntry(executable: Platform.resolvedExecutable, options: options)},
      ),
      credentials: const CredentialsConfig(entries: {'openai': CredentialEntry(apiKey: 'openai-key')}),
    );
  }

  test('primary runner keeps interactive prompt while spawned task runner gets lean task prompt', () async {
    await wireStorageAndSecurity();

    final factory = fakeFactory(['claude'], onCreate: (_, factoryConfig) => recordedConfigs.add(factoryConfig));
    await wireHarness(factory);

    expect(harnessWiring!.pool.size, 1);
    expect(harnessWiring!.onSpawnNeeded, isNotNull);

    await harnessWiring!.onSpawnNeeded!(null);

    expect(harnessWiring!.pool.size, 2);
    expect(recordedConfigs, hasLength(2));
    expect(createdHarnesses, hasLength(2));
    expect(recordedConfigs.first.harnessConfig.mcpServerUrl, isNull);
    expect(recordedConfigs.first.harnessConfig.mcpGatewayToken, isNull);

    // Primary and task harnesses each get a layered chain: all base security
    // guards plus their own per-runner TaskToolFilterGuard.
    final primaryChain = recordedConfigs.first.guardChain!;
    final taskChain = recordedConfigs.last.guardChain!;
    expect(primaryChain, isNot(same(security!.guardChain)));
    expect(primaryChain.guards.map((g) => g.name), containsAll(security!.guardChain!.guards.map((g) => g.name)));
    expect(primaryChain.guards.whereType<TaskToolFilterGuard>(), hasLength(1));
    expect(taskChain.guards.whereType<TaskToolFilterGuard>(), hasLength(1));
    expect(
      primaryChain.guards.whereType<TaskToolFilterGuard>().single,
      isNot(same(taskChain.guards.whereType<TaskToolFilterGuard>().single)),
    );
    expect(recordedConfigs.first.acpPermissionDecision, isNotNull);
    expect(recordedConfigs.first.acpReverseCallAudit, isNotNull);

    final primaryPrompt = recordedConfigs.first.harnessConfig.appendSystemPrompt ?? '';
    final taskPrompt = recordedConfigs.last.harnessConfig.appendSystemPrompt ?? '';

    expect(primaryPrompt, contains('Soul prompt'));
    expect(primaryPrompt, contains('User prompt'));
    expect(primaryPrompt, contains('Tool prompt'));
    expect(primaryPrompt, contains('## Agent prompt'));
    expect(primaryPrompt, contains('## Recent error'));
    expect(primaryPrompt, contains('## Recent learning'));
    expect(primaryPrompt, contains('memory_read tool'));

    expect(taskPrompt, contains('Soul prompt'));
    expect(taskPrompt, contains('Tool prompt'));
    expect(taskPrompt, contains('## Agent prompt'));
    expect(taskPrompt, contains('memory_read tool'));
    expect(taskPrompt, isNot(contains('User prompt')));
    expect(taskPrompt, isNot(contains('## Recent error')));
    expect(taskPrompt, isNot(contains('## Recent learning')));
    expect(taskPrompt.length, lessThan(primaryPrompt.length));
  });

  test('warns when sandboxed agents use Codex without broad approval interception', () async {
    configureCodex(options: const {'approval': 'unless-allow-listed'});
    final messages = await wireAndCollectHarnessMessages(['codex']);

    expect(messages, contains(contains('Codex harness uses approval: unless-allow-listed')));
  });

  test('warns for a session-local journal policy with a Codex alias using approval never', () async {
    const providerId = 'openai-work';
    configureCodex(
      providerId: providerId,
      options: const {'family': 'codex', 'approval': ' never ', 'credentials_required': false},
      restricted: false,
      journalEnabled: true,
    );
    final messages = await wireAndCollectHarnessMessages([providerId]);

    expect(messages, contains(contains('Codex harness uses approval: never')));
  });

  test('does not warn for unrestricted agents with Codex approval never', () async {
    configureCodex(options: const {'approval': 'never'}, restricted: false);
    final messages = await wireAndCollectHarnessMessages(['codex']);

    expect(messages, isNot(contains(contains('Codex harness uses approval: never'))));
  });

  test('does not warn when sandboxed agents use enabled guards and Codex approval on-request', () async {
    configureCodex(options: const {'approval': ' on-request '});
    final messages = await wireAndCollectHarnessMessages(['codex']);

    expect(messages, isNot(contains(contains('host tool-policy enforcement'))));
  });

  test('warns when a restricted Codex provider does not declare an approval posture', () async {
    configureCodex();
    final messages = await wireAndCollectHarnessMessages(['codex']);

    expect(messages, contains(contains('approval: not explicitly set')));
  });

  test('warns instead of throwing for a non-string Codex approval option', () async {
    const providerId = 'openai-work';
    configureCodex(
      providerId: providerId,
      options: const {'family': 'codex', 'approval': 42, 'credentials_required': false},
    );
    final messages = await wireAndCollectHarnessMessages([providerId]);

    expect(messages, contains(contains('approval: not explicitly set')));
  });

  test('warns when a restricted Codex approval option is blank', () async {
    configureCodex(options: const {'approval': '   '});
    final messages = await wireAndCollectHarnessMessages(['codex']);

    expect(messages, contains(contains('approval: not explicitly set')));
  });

  test('warns when agent tool policies are configured while guards are disabled', () async {
    config = config.copyWith(
      security: const SecurityConfig(guards: GuardConfig(enabled: false)),
      agent: AgentConfig(
        provider: 'claude',
        definitions: const [
          AgentDefinition(id: 'search', description: 'Search', prompt: 'Search', allowedTools: {'web_search'}),
        ],
      ),
    );
    final messages = await wireAndCollectHarnessMessages(['claude']);

    expect(messages, contains(contains('security guards are disabled')));
  });

  test('translates agent tool grants and scopes own MCP names by semantic grant', () async {
    config = config.copyWith(
      gateway: const GatewayConfig(authMode: 'token', token: 'test-token'),
      search: const SearchConfig(providers: {'brave': SearchProviderEntry(enabled: true, apiKey: 'brave-key')}),
      agent: AgentConfig(
        provider: 'claude',
        definitions: const [
          AgentDefinition(
            id: 'search',
            description: 'Search',
            prompt: 'Search',
            allowedTools: {'WebSearch', 'WebFetch'},
          ),
          AgentDefinition(
            id: 'worker',
            description: 'Worker',
            prompt: 'Work',
            allowedTools: {'shell', 'file_read', 'Grep'},
          ),
          AgentDefinition(id: 'unrestricted', description: 'Unrestricted', prompt: 'Work'),
        ],
      ),
    );

    await wireStorageAndSecurity();
    await wireHarness(fakeFactory(['claude'], onCreate: (_, factoryConfig) => recordedConfigs.add(factoryConfig)));

    final agents = recordedConfigs.single.harnessConfig.agents!;
    final search = agents['search'] as Map<String, dynamic>;
    expect(search['model'], 'sonnet');
    expect(
      search['tools'],
      containsAll(['WebSearch', 'WebFetch', 'mcp__dartclaw__web_fetch', 'mcp__dartclaw__brave_search']),
    );
    expect(search['tools'], isNot(contains('mcp__dartclaw__memory_save')));
    final worker = agents['worker'] as Map<String, dynamic>;
    expect(worker['tools'], ['Bash', 'Read', 'Grep']);
    expect((agents['unrestricted'] as Map<String, dynamic>), isNot(contains('tools')));
  });

  test('token-authenticated harness reaches the server on its bound loopback host', () async {
    config = config.copyWith(
      gateway: const GatewayConfig(authMode: 'token', token: 'test-token'),
    );

    await wireStorageAndSecurity();
    await wireHarness(fakeFactory(['claude'], onCreate: (_, factoryConfig) => recordedConfigs.add(factoryConfig)));

    expect(recordedConfigs.single.harnessConfig.mcpServerUrl, 'http://localhost:3333/mcp');
  });

  test('authentication-disabled journal advertises exact own MCP tools', () async {
    config = config.copyWith(
      memory: const MemoryConfig(journalEnabled: true),
      search: const SearchConfig(providers: {'brave': SearchProviderEntry(enabled: true, apiKey: 'brave-key')}),
      agent: AgentConfig(
        provider: 'claude',
        definitions: const [
          AgentDefinition(
            id: 'search',
            description: 'Search',
            prompt: 'Search',
            allowedTools: {'web_search', 'web_fetch', 'memory_save'},
          ),
        ],
      ),
    );

    await wireStorageAndSecurity();
    await wireHarness(fakeFactory(['claude'], onCreate: (_, factoryConfig) => recordedConfigs.add(factoryConfig)));

    final harnessConfig = recordedConfigs.single.harnessConfig;
    expect(harnessConfig.mcpServerUrl, 'http://localhost:3333/mcp');
    expect(harnessConfig.mcpGatewayToken, isNull);
    expect(
      (harnessConfig.agents!['search'] as Map<String, dynamic>)['tools'],
      containsAll(['mcp__dartclaw__web_fetch', 'mcp__dartclaw__brave_search', 'mcp__dartclaw__memory_save']),
    );
  });

  test('unknown search providers do not suppress the native search tool', () async {
    config = config.copyWith(
      gateway: const GatewayConfig(authMode: 'token', token: 'test-token'),
      search: const SearchConfig(providers: {'unknown': SearchProviderEntry(enabled: true, apiKey: 'key')}),
    );

    await wireStorageAndSecurity();
    await wireHarness(fakeFactory(['claude'], onCreate: (_, factoryConfig) => recordedConfigs.add(factoryConfig)));

    expect(recordedConfigs.single.harnessConfig.disallowedTools, isNot(contains('WebSearch')));
  });

  test('authentication-disabled non-loopback harness does not advertise an unauthenticated MCP endpoint', () async {
    config = config.copyWith(
      server: ServerConfig(dataDir: tempDir.path, host: '0.0.0.0'),
    );

    await wireStorageAndSecurity();
    await wireHarness(fakeFactory(['claude'], onCreate: (_, factoryConfig) => recordedConfigs.add(factoryConfig)));

    expect(recordedConfigs.single.harnessConfig.mcpServerUrl, isNull);
  });

  test('wired session delegation applies configured persona, model, and effort', () async {
    final builtInSearch = AgentDefinition.searchAgent();
    config = config.copyWith(
      agent: AgentConfig(
        provider: 'claude',
        definitions: [
          builtInSearch,
          const AgentDefinition(
            id: 'summarizer',
            description: 'Summarize',
            prompt: 'SUMMARY PERSONA',
            model: 'custom-model',
            effort: 'low',
          ),
        ],
      ),
      tasks: const TaskConfig(maxConcurrent: 2),
    );
    await wireStorageAndSecurity();
    final factory = fakeFactory(['claude']);
    late DartclawServer wiredServer;
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
    await harnessWiring!.wire(serverRefGetter: () => wiredServer);
    wiredServer =
        (DartclawServerBuilder()
              ..sessions = storage!.sessions
              ..messages = storage!.messages
              ..worker = harnessWiring!.harness
              ..staticDir = tempDir.path
              ..behavior = harnessWiring!.behavior
              ..pool = harnessWiring!.pool
              ..sessionsForTurns = storage!.sessions
              ..runnerPoolCoordinator = harnessWiring!.runnerPoolCoordinator
              ..config = config)
            .build();

    Future<void> expectDelegation({
      required String agent,
      required String persona,
      required String model,
      required String? effort,
    }) async {
      final resultFuture = harnessWiring!.sessionDelegate.handleSessionsSpawn({
        'agent': agent,
        'message': 'Delegate this',
      });
      await _pollFor(() => createdHarnesses.length, (length) => length == 2);
      final delegatedHarness = createdHarnesses.last;
      await delegatedHarness.turnInvoked;
      final internalSessionId = delegatedHarness.lastSessionId;
      expect(delegatedHarness.lastAgentId, agent);
      expect(delegatedHarness.lastSystemPrompt, contains(persona));
      expect(delegatedHarness.lastModel, model);
      expect(delegatedHarness.lastEffort, effort);
      delegatedHarness.emit(DeltaEvent('$agent result'));
      delegatedHarness.completeSuccess();
      final result = await resultFuture;
      expect(result['isError'], isNull);
      expect(result['content'], contains(containsPair('text', '$agent result')));

      final sessionId = result['sessionId'] as String;
      final followUpFuture = harnessWiring!.sessionDelegate.handleSessionsSend({
        'session_id': sessionId,
        'message': 'Continue this',
      });
      await delegatedHarness.turnInvoked;
      expect(delegatedHarness.lastSessionId, internalSessionId);
      expect(delegatedHarness.lastMessages, [
        {'role': 'user', 'content': 'Delegate this'},
        {'role': 'assistant', 'content': '$agent result'},
        {'role': 'user', 'content': 'Continue this'},
      ]);
      delegatedHarness.emit(DeltaEvent('$agent follow-up'));
      delegatedHarness.completeSuccess();
      final followUp = await followUpFuture;
      expect(followUp['isError'], isNull);
      expect(followUp['content'], contains(containsPair('text', '$agent follow-up')));
    }

    await expectDelegation(agent: 'search', persona: builtInSearch.prompt, model: 'sonnet', effort: null);
    await expectDelegation(agent: 'summarizer', persona: 'SUMMARY PERSONA', model: 'custom-model', effort: 'low');

    final sessionsBefore = await storage!.sessions.listSessions(type: SessionType.delegated);
    expect(sessionsBefore, hasLength(2));
    expect(
      (await storage!.sessions.listSessions()).map((session) => session.type),
      isNot(contains(SessionType.delegated)),
    );
    for (final session in sessionsBefore) {
      expect(session.type, SessionType.delegated);
      expect(session.provider, 'claude');
      expect(await storage!.messages.getMessages(session.id), isNotEmpty);
    }
    final unknown = await harnessWiring!.sessionDelegate.handleSessionsSend({
      'session_id': 'agent:search:delegated:missing',
      'message': 'Do not create this',
    });
    expect(unknown['isError'], isTrue);
    expect((unknown['content'] as List).first['text'], contains('Unknown delegated session'));
    expect(await storage!.sessions.listSessions(type: SessionType.delegated), hasLength(sessionsBefore.length));
  });

  test('delegated session resumes persisted history after storage and worker reconstruction', () async {
    config = config.copyWith(
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
    );

    Future<void> wireRuntime() async {
      final factory = fakeFactory(['claude']);
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
                ..runnerPoolCoordinator = harnessWiring!.runnerPoolCoordinator
                ..config = config)
              .build();
    }

    await wireStorageAndSecurity();
    await wireRuntime();

    final spawnFuture = harnessWiring!.sessionDelegate.handleSessionsSpawn({
      'agent': 'search',
      'message': 'Remember amber',
    });
    await _pollFor(() => createdHarnesses.length, (length) => length == 2);
    final firstWorker = createdHarnesses.last;
    await firstWorker.turnInvoked;
    firstWorker.emit(DeltaEvent('Amber remembered'));
    firstWorker.completeSuccess();
    final spawned = await spawnFuture;
    final handle = spawned['sessionId'] as String;

    await harnessWiring!.pool.dispose();
    harnessWiring = null;
    await security!.dispose();
    security = null;
    await storage!.dispose();
    storage = null;
    createdHarnesses.clear();

    await wireStorageAndSecurity();
    await wireRuntime();

    final sendFuture = harnessWiring!.sessionDelegate.handleSessionsSend({
      'session_id': handle,
      'message': 'What did I ask you to remember?',
    });
    await _pollFor(() => createdHarnesses.length, (length) => length == 2);
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
    final sent = await sendFuture;
    expect(sent['isError'], isNull);
    expect(sent['content'], contains(containsPair('text', 'Amber')));
  });

  test('wired delegation resolves a Codex provider alias and trims unset overrides', () async {
    const providerId = 'openai-work';
    config = config.copyWith(
      agent: const AgentConfig(
        provider: providerId,
        definitions: [
          AgentDefinition(id: 'search', description: 'Search', prompt: 'SEARCH PERSONA'),
          AgentDefinition(id: 'blank', description: 'Blank', prompt: '   ', model: '   ', effort: '   '),
        ],
      ),
      providers: ProvidersConfig(
        entries: {
          providerId: ProviderEntry(
            executable: Platform.resolvedExecutable,
            poolSize: 1,
            options: const {'family': 'codex', 'approval': 'on-request', 'credentials_required': false},
          ),
        },
      ),
      credentials: const CredentialsConfig(entries: {'openai': CredentialEntry(apiKey: 'openai-key')}),
    );
    await wireStorageAndSecurity();
    final factory = fakeFactory([providerId]);
    late DartclawServer wiredServer;
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
    await harnessWiring!.wire(serverRefGetter: () => wiredServer);
    wiredServer =
        (DartclawServerBuilder()
              ..sessions = storage!.sessions
              ..messages = storage!.messages
              ..worker = harnessWiring!.harness
              ..staticDir = tempDir.path
              ..behavior = harnessWiring!.behavior
              ..pool = harnessWiring!.pool
              ..sessionsForTurns = storage!.sessions
              ..runnerPoolCoordinator = harnessWiring!.runnerPoolCoordinator
              ..config = config)
            .build();

    Future<void> completeDelegation(String agentId) async {
      final resultFuture = harnessWiring!.sessionDelegate.handleSessionsSpawn({
        'agent': agentId,
        'message': 'Delegate this',
      });
      await _pollFor(() => createdHarnesses.length, (length) => length == 2);
      final delegatedHarness = createdHarnesses.last;
      await delegatedHarness.turnInvoked;
      if (agentId == 'search') {
        expect(delegatedHarness.lastSystemPrompt, contains('SEARCH PERSONA'));
        expect(delegatedHarness.lastModel, 'gpt-5.6-luna');
        expect(delegatedHarness.lastEffort, isNull);
      } else {
        expect(delegatedHarness.lastSystemPrompt, isNot('   '));
        expect(delegatedHarness.lastModel, isNull);
        expect(delegatedHarness.lastEffort, isNull);
      }
      delegatedHarness.emit(DeltaEvent('$agentId result'));
      delegatedHarness.completeSuccess();
      expect((await resultFuture)['isError'], isNull);
    }

    await completeDelegation('search');
    await completeDelegation('blank');
  });

  test('wired delegation applies the configured content guard', () async {
    config = config.copyWith(
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: '/bin/echo'),
      agent: const AgentConfig(
        provider: 'claude',
        definitions: [AgentDefinition(id: 'search', description: 'Search', prompt: 'Search')],
      ),
      tasks: const TaskConfig(maxConcurrent: 1),
    );
    await wireStorageAndSecurity();
    final factory = fakeFactory(['claude']);
    late DartclawServer wiredServer;
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
    await harnessWiring!.wire(serverRefGetter: () => wiredServer);
    wiredServer =
        (DartclawServerBuilder()
              ..sessions = storage!.sessions
              ..messages = storage!.messages
              ..worker = harnessWiring!.harness
              ..staticDir = tempDir.path
              ..behavior = harnessWiring!.behavior
              ..pool = harnessWiring!.pool
              ..sessionsForTurns = storage!.sessions
              ..runnerPoolCoordinator = harnessWiring!.runnerPoolCoordinator
              ..config = config)
            .build();

    final resultFuture = harnessWiring!.sessionDelegate.handleSessionsSpawn({
      'agent': 'search',
      'message': 'Delegate this',
    });
    await _pollFor(() => createdHarnesses.length, (length) => length == 2);
    final delegatedHarness = createdHarnesses.last;
    await delegatedHarness.turnInvoked;
    delegatedHarness.emit(DeltaEvent('unsafe result'));
    delegatedHarness.completeSuccess();

    final result = await resultFuture;
    expect(result['isError'], isTrue);
    expect((result['content'] as List).first['text'], contains('content-guard'));
    expect(await storage!.sessions.listSessions(type: SessionType.delegated), isEmpty);
    expect(await storage!.sessions.listSessions(type: SessionType.archive), hasLength(1));
  });

  test('knowledge-inbox no-tools turn policy blocks tool calls on the primary harness chain', () async {
    await wireStorageAndSecurity();

    final factory = fakeFactory(['claude'], onCreate: (_, factoryConfig) => recordedConfigs.add(factoryConfig));
    await wireHarness(factory);

    final primaryChain = recordedConfigs.single.guardChain!;
    final session = await storage!.sessions.createSession();
    final turnId = await harnessWiring!.pool.primary.startTurn(
      session.id,
      [
        {'role': 'user', 'content': 'extract facts'},
      ],
      allowedTools: const ['__knowledge_inbox_no_tools__'],
      readOnly: true,
    );
    final harness = createdHarnesses.single;
    await harness.turnInvoked;

    // The harness consults its guard chain for every tool call mid-turn; the
    // turn's session-keyed no-tools policy must block.
    final midTurn = await primaryChain.evaluateBeforeToolCall('shell', {'command': 'ls'}, sessionId: session.id);
    expect(midTurn.isBlock, isTrue);
    expect(midTurn.message, contains('__knowledge_inbox_no_tools__'));

    // Other sessions on the same chain are unaffected.
    final otherSession = await primaryChain.evaluateBeforeToolCall('shell', {'command': 'ls'}, sessionId: 'other');
    expect(otherSession.isBlock, isFalse);

    harness.completeSuccess();
    await harnessWiring!.pool.primary.waitForOutcome(session.id, turnId);

    // The policy is cleared once the turn settles.
    final postTurn = await primaryChain.evaluateBeforeToolCall('shell', {'command': 'ls'}, sessionId: session.id);
    expect(postTurn.isBlock, isFalse);
  });

  test('guards hot-reload keeps the primary tool filter and picks up rebuilt base guards', () async {
    await wireStorageAndSecurity();

    final factory = fakeFactory(['claude'], onCreate: (_, factoryConfig) => recordedConfigs.add(factoryConfig));
    await wireHarness(factory);

    final primaryChain = recordedConfigs.single.guardChain!;
    final filterBefore = primaryChain.guards.whereType<TaskToolFilterGuard>().single;
    final sanitizerBefore = primaryChain.guards.whereType<InputSanitizer>().single;

    security!.reconfigure(
      ConfigDelta(
        previous: config,
        current: const DartclawConfig(security: SecurityConfig(guards: GuardConfig(enabled: true, failOpen: false))),
        changedKeys: const {'security.*'},
      ),
    );

    // Base guards were rebuilt (new instances) and reach the primary chain
    // live; the per-runner filter survives the rebuild as the same instance.
    expect(primaryChain.guards.whereType<InputSanitizer>().single, isNot(same(sanitizerBefore)));
    expect(primaryChain.guards.whereType<TaskToolFilterGuard>().single, same(filterBefore));

    filterBefore.setSessionToolFilter('session-1', const ['__knowledge_inbox_no_tools__']);
    final verdict = await primaryChain.evaluateBeforeToolCall('shell', {'command': 'ls'}, sessionId: 'session-1');
    expect(verdict.isBlock, isTrue);
  });

  test('provider-specific lazy spawn consumes the requested provider entry', () async {
    config = config.copyWith(
      providers: ProvidersConfig(
        entries: {
          'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1),
          'codex': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1),
        },
      ),
      credentials: const CredentialsConfig(
        entries: {
          'anthropic': CredentialEntry(apiKey: 'anthropic-key'),
          'openai': CredentialEntry(apiKey: 'openai-key'),
        },
      ),
      tasks: const TaskConfig(maxConcurrent: 2),
    );

    await wireStorageAndSecurity();
    final createdProviderIds = <String>[];
    final factory = fakeFactory(
      ['claude', 'codex'],
      onCreate: (providerId, factoryConfig) {
        createdProviderIds.add(providerId);
        recordedConfigs.add(factoryConfig);
      },
    );
    await wireHarness(factory);

    await harnessWiring!.onSpawnNeeded!('codex');

    expect(createdProviderIds, ['claude', 'codex']);
    expect(harnessWiring!.pool.hasTaskRunnerForProvider('codex'), isTrue);
    expect(harnessWiring!.pool.hasTaskRunnerForProvider('claude'), isFalse);

    await harnessWiring!.onSpawnNeeded!('missing');
    expect(createdProviderIds, ['claude', 'codex']);
  });

  test('configured ACP agents register provider identity and default pool capacity', () async {
    final records = <LogRecord>[];
    final subscription = Logger('HarnessWiring').onRecord.listen(records.add);
    addTearDown(subscription.cancel);
    config = config.copyWith(
      harness: HarnessConfig(
        acp: AcpConfig(
          agents: {
            'goose': AcpAgentConfig(
              binary: Platform.resolvedExecutable,
              args: const ['acp'],
              topology: AcpAgentTopology.direct,
              modelProvider: 'anthropic',
              verification: 'a0_1_goose_direct',
              requiresGuardMediation: false,
              requiredBuiltins: const ['developer'],
            ),
          },
        ),
      ),
      tasks: const TaskConfig(maxConcurrent: 10),
    );

    await wireStorageAndSecurity();

    final factory = fakeFactory(['claude']);
    await wireHarness(factory);

    expect(factory.supports('goose'), isTrue);
    expect(harnessWiring!.pool.maxConcurrentTasks, 2);
    expect(harnessWiring!.onSpawnNeeded, isNotNull);
    expect(
      records.map((record) => record.message),
      contains(contains('Tool-restricted agent or job turns are configured for an ACP')),
    );
  });

  test('configured Goose and Vibe ACP agents register without unknown-provider fallback', () async {
    config = config.copyWith(
      harness: HarnessConfig(
        acp: AcpConfig(
          agents: {
            'goose': AcpAgentConfig(
              binary: Platform.resolvedExecutable,
              args: const ['acp', '--with-builtin', 'developer'],
              topology: AcpAgentTopology.direct,
              modelProvider: 'anthropic',
              verification: 'a0_1_goose_direct',
              requiresGuardMediation: false,
              requiredBuiltins: const ['developer'],
            ),
            'vibe': AcpAgentConfig(
              binary: Platform.resolvedExecutable,
              topology: AcpAgentTopology.direct,
              modelProvider: 'mistral',
              verification: 'vibe_acp_direct_probe',
              requiresGuardMediation: false,
            ),
          },
        ),
      ),
      credentials: const CredentialsConfig(
        entries: {
          'anthropic': CredentialEntry(apiKey: 'anthropic-key'),
          'mistral': CredentialEntry(apiKey: 'mistral-key'),
        },
      ),
      tasks: const TaskConfig(maxConcurrent: 10),
    );

    await wireStorageAndSecurity();

    final factory = fakeFactory(['claude']);
    await wireHarness(factory);

    expect(factory.supports('goose'), isTrue);
    expect(factory.supports('vibe'), isTrue);
    expect(factory.supports('missing_acp_agent'), isFalse);
    expect(
      harnessWiring!.providerStatusEntries['goose']!.options['acp_validation_result'],
      containsPair('securityClassification', 'container_isolation_only'),
    );
    expect(harnessWiring!.providerStatusEntries['goose']!.options['acp_validation_owned'], isTrue);
    expect(
      harnessWiring!.providerStatusEntries['vibe']!.options['acp_validation_result'],
      containsPair('securityClassification', 'container_isolation_only'),
    );
  });

  test('guarded ACP agent without runtime probe evidence fails before registration', () async {
    config = config.copyWith(
      harness: HarnessConfig(
        acp: AcpConfig(
          agents: {
            'goose': AcpAgentConfig(
              binary: Platform.resolvedExecutable,
              args: const ['acp', '--with-builtin', 'developer'],
              topology: AcpAgentTopology.direct,
              modelProvider: 'anthropic',
              verification: 'a0_1_goose_direct',
              requiresGuardMediation: true,
              requiredBuiltins: const ['developer'],
            ),
          },
        ),
      ),
      tasks: const TaskConfig(maxConcurrent: 10),
    );

    await wireStorageAndSecurity();

    final factory = fakeFactory(['claude']);
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

    await expectLater(
      harnessWiring!.wire(serverRefGetter: () => throw UnimplementedError('serverRefGetter should not be called')),
      throwsA(isA<StateError>().having((error) => error.message, 'message', contains('operation probe evidence'))),
    );
    expect(factory.supports('goose'), isFalse);
    harnessWiring = null;
  });

  test('ACP model_provider credentials are passed to the ACP process environment', () async {
    final envFile = File(p.join(tempDir.path, 'acp-env.txt'));
    final shimFile = File(p.join(tempDir.path, 'fake_acp.dart'));
    shimFile.writeAsStringSync('''
import 'dart:convert';
import 'dart:io';

void main(List<String> args) async {
  File(args.single).writeAsStringSync(Platform.environment['ANTHROPIC_API_KEY'] ?? '');
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': {
          'protocolVersion': 1,
          'auth': {'status': 'authenticated'},
        },
      }));
    }
  }
}
''');
    config = config.copyWith(
      agent: const AgentConfig(provider: 'goose'),
      harness: HarnessConfig(
        acp: AcpConfig(
          agents: {
            'goose': AcpAgentConfig(
              binary: Platform.resolvedExecutable,
              args: [shimFile.path, envFile.path],
              topology: AcpAgentTopology.direct,
              modelProvider: 'anthropic',
              verification: 'a0_1_goose_direct',
              requiresGuardMediation: false,
              requiredBuiltins: const ['developer'],
            ),
          },
        ),
      ),
      providers: const ProvidersConfig(),
      tasks: const TaskConfig(maxConcurrent: 0),
    );

    await wireStorageAndSecurity();
    await wireHarness(HarnessFactory());

    expect(envFile.readAsStringSync(), 'anthropic-key');
  });

  test('ACP agents are included in task capacity when providers section is absent', () async {
    config = config.copyWith(
      harness: HarnessConfig(
        acp: AcpConfig(
          agents: {
            'goose': AcpAgentConfig(
              binary: Platform.resolvedExecutable,
              args: const ['acp'],
              topology: AcpAgentTopology.direct,
              modelProvider: 'anthropic',
              verification: 'a0_1_goose_direct',
              requiresGuardMediation: false,
              requiredBuiltins: const ['developer'],
            ),
          },
        ),
      ),
      providers: const ProvidersConfig(),
      tasks: const TaskConfig(maxConcurrent: 10),
    );

    await wireStorageAndSecurity();

    final factory = fakeFactory(['claude']);
    await wireHarness(factory);

    expect(factory.supports('goose'), isTrue);
    expect(harnessWiring!.pool.maxConcurrentTasks, 2);
  });

  test('providers pool_size overrides configured ACP agent default capacity', () async {
    config = config.copyWith(
      harness: HarnessConfig(
        acp: AcpConfig(
          agents: {
            'goose': AcpAgentConfig(
              binary: Platform.resolvedExecutable,
              args: const ['acp'],
              topology: AcpAgentTopology.direct,
              modelProvider: 'anthropic',
              verification: 'a0_1_goose_direct',
              requiresGuardMediation: false,
              requiredBuiltins: const ['developer'],
            ),
          },
        ),
      ),
      providers: ProvidersConfig(
        entries: {
          'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1),
          'goose': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 2),
        },
      ),
      tasks: const TaskConfig(maxConcurrent: 10),
    );

    await wireStorageAndSecurity();

    final factory = fakeFactory(['claude']);
    await wireHarness(factory);

    expect(factory.supports('goose'), isTrue);
    expect(harnessWiring!.pool.maxConcurrentTasks, 3);
    final gooseHarness = factory.create(
      'goose',
      const HarnessFactoryConfig(cwd: '/', executable: '/wrong/provider/executable'),
    );
    addTearDown(gooseHarness.dispose);
    expect(
      gooseHarness,
      isA<AcpHarness>().having((harness) => harness.executable, 'executable', Platform.resolvedExecutable),
    );
  });

  test('container-required ACP spawn fails closed when the configured profile is unavailable', () async {
    config = config.copyWith(
      harness: HarnessConfig(
        acp: AcpConfig(
          agents: {
            'goose': AcpAgentConfig(
              binary: Platform.resolvedExecutable,
              topology: AcpAgentTopology.relay,
              containerIsolationRequired: true,
              containerProfile: AcpContainerProfile.restricted,
            ),
          },
        ),
      ),
      providers: const ProvidersConfig(),
      tasks: const TaskConfig(maxConcurrent: 10),
    );

    await wireStorageAndSecurity();

    final factory = fakeFactory(['claude']);
    await wireHarness(factory);

    expect(await harnessWiring!.onSpawnNeeded!('goose'), isFalse);
    expect(harnessWiring!.pool.hasTaskRunnerForProvider('goose'), isFalse);
  });

  test('configured providers use effective pool_size with independent capacity', () async {
    config = config.copyWith(
      providers: ProvidersConfig(
        entries: {
          'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 0),
          'codex': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1),
        },
      ),
      credentials: const CredentialsConfig(
        entries: {
          'anthropic': CredentialEntry(apiKey: 'anthropic-key'),
          'openai': CredentialEntry(apiKey: 'openai-key'),
        },
      ),
      tasks: const TaskConfig(maxConcurrent: 10),
    );

    await wireStorageAndSecurity();

    final factory = fakeFactory(['claude', 'codex']);
    await wireHarness(factory);

    expect(harnessWiring!.pool.maxConcurrentTasks, 2);

    await harnessWiring!.onSpawnNeeded!('claude');
    await harnessWiring!.onSpawnNeeded!('codex');

    final claudeRunner = harnessWiring!.pool.tryAcquireForProvider('claude');
    final codexRunner = harnessWiring!.pool.tryAcquireForProvider('codex');

    expect(claudeRunner, isNotNull);
    expect(codexRunner, isNotNull);
    expect(harnessWiring!.pool.tryAcquireForProvider('claude'), isNull);
    expect(harnessWiring!.pool.tryAcquireForProvider('codex'), isNull);
  });

  test('non-empty provider config missing default still reserves default capacity', () async {
    config = config.copyWith(
      providers: ProvidersConfig(
        entries: {'codex': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1)},
      ),
      credentials: const CredentialsConfig(
        entries: {
          'anthropic': CredentialEntry(apiKey: 'anthropic-key'),
          'openai': CredentialEntry(apiKey: 'openai-key'),
        },
      ),
      tasks: const TaskConfig(maxConcurrent: 10),
    );

    await wireStorageAndSecurity();

    final factory = fakeFactory(['claude', 'codex']);
    await wireHarness(factory);

    expect(harnessWiring!.pool.maxConcurrentTasks, 2);
    await harnessWiring!.onSpawnNeeded!('claude');
    await harnessWiring!.onSpawnNeeded!('codex');

    expect(harnessWiring!.pool.hasTaskRunnerForProvider('claude'), isTrue);
    expect(harnessWiring!.pool.hasTaskRunnerForProvider('codex'), isTrue);
  });

  test('wired runners use configured turn monitor thresholds and worker timeout', () async {
    config = config.copyWith(
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable, workerTimeout: 3),
      harness: const HarnessConfig(
        turnMonitor: TurnMonitorConfig(
          waitWarningAfter: Duration(milliseconds: 10),
          stuckAfter: Duration(milliseconds: 25),
        ),
      ),
    );

    await wireStorageAndSecurity();

    final factory = fakeFactory(['claude'], onCreate: (_, factoryConfig) => recordedConfigs.add(factoryConfig));
    await wireHarness(factory);

    final session = await storage!.sessions.createSession();
    final firstTurnId = await harnessWiring!.pool.primary.reserveTurn(session.id);
    final firstOutcome = harnessWiring!.pool.primary.waitForOutcome(session.id, firstTurnId).catchError((_) {
      return TurnOutcome(
        turnId: firstTurnId,
        sessionId: session.id,
        status: TurnStatus.cancelled,
        completedAt: DateTime.now(),
      );
    });
    final queuedReserve = harnessWiring!.pool.primary.reserveTurn(session.id);

    final primaryStatus = await _pollFor(
      () => harnessWiring!.pool.primary.turnStatus(session.id),
      (status) => status.state.name == 'stuck',
    );
    expect(primaryStatus.state.name, 'stuck');
    expect(primaryStatus.globalTimeoutAt, isNotNull);

    harnessWiring!.pool.primary.releaseTurn(session.id, firstTurnId);
    await firstOutcome;
    final secondTurnId = await queuedReserve.timeout(const Duration(seconds: 1));
    final secondOutcome = harnessWiring!.pool.primary.waitForOutcome(session.id, secondTurnId).catchError((_) {
      return TurnOutcome(
        turnId: secondTurnId,
        sessionId: session.id,
        status: TurnStatus.cancelled,
        completedAt: DateTime.now(),
      );
    });
    harnessWiring!.pool.primary.releaseTurn(session.id, secondTurnId);
    await secondOutcome;

    await harnessWiring!.onSpawnNeeded!(null);
    final taskRunner = harnessWiring!.pool.runners.last;
    final taskSession = await storage!.sessions.createSession();
    final taskFirstTurnId = await taskRunner.reserveTurn(taskSession.id);
    final taskFirstOutcome = taskRunner.waitForOutcome(taskSession.id, taskFirstTurnId).catchError((_) {
      return TurnOutcome(
        turnId: taskFirstTurnId,
        sessionId: taskSession.id,
        status: TurnStatus.cancelled,
        completedAt: DateTime.now(),
      );
    });
    final taskQueuedReserve = taskRunner.reserveTurn(taskSession.id);

    final taskStatus = await _pollFor(
      () => taskRunner.turnStatus(taskSession.id),
      (status) => status.state.name == 'stuck',
    );
    expect(taskStatus.state.name, 'stuck');
    expect(taskStatus.globalTimeoutAt, isNotNull);

    taskRunner.releaseTurn(taskSession.id, taskFirstTurnId);
    await taskFirstOutcome;
    final taskSecondTurnId = await taskQueuedReserve.timeout(const Duration(seconds: 1));
    final taskSecondOutcome = taskRunner.waitForOutcome(taskSession.id, taskSecondTurnId).catchError((_) {
      return TurnOutcome(
        turnId: taskSecondTurnId,
        sessionId: taskSession.id,
        status: TurnStatus.cancelled,
        completedAt: DateTime.now(),
      );
    });
    taskRunner.releaseTurn(taskSession.id, taskSecondTurnId);
    await taskSecondOutcome;
  });
}
