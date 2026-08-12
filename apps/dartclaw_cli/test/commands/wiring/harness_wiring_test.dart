import 'dart:io';

import 'package:dartclaw_cli/src/commands/wiring/harness_wiring.dart';
import 'package:dartclaw_cli/src/commands/wiring/security_wiring.dart';
import 'package:dartclaw_cli/src/commands/wiring/storage_wiring.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide HarnessConfig;
import 'package:dartclaw_server/dartclaw_server.dart'
    show
        DartclawServer,
        DartclawServerBuilder,
        ExecutionAdmission,
        ExecutionRequest,
        ExecutionSurface,
        WorkerCreationException;
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../helpers/harness_wiring_fixture.dart';

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
  late Directory tempDir;
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
    );

    writeWorkspacePromptFiles(config.workspaceDir);

    eventBus = EventBus();
    recordedConfigs = <HarnessFactoryConfig>[];
    createdHarnesses = <FakeAgentHarness>[];
  });

  tearDown(() async {
    await harnessWiring?.executions.dispose();
    await security?.dispose();
    await storage?.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<void> wireStorageAndSecurity() async {
    storage = await wireTestStorage(config: config, eventBus: eventBus, exitFn: _unexpectedExit);
    security = await wireTestSecurity(
      config: config,
      dataDir: tempDir.path,
      eventBus: eventBus,
      exitFn: _unexpectedExit,
    );
  }

  ExecutionRequest executionRequest({
    required String providerId,
    required String sessionId,
    ExecutionPolicy policy = const ExecutionPolicy.host(),
    ExecutionSurface surface = ExecutionSurface.task,
    ExecutionAdmission admission = ExecutionAdmission.wait,
  }) => ExecutionRequest(
    surface: surface,
    providerId: providerId,
    policy: policy,
    sessionId: sessionId,
    admission: admission,
  );

  Future<void> wireHarness(HarnessFactory factory) async {
    harnessWiring = await wireTestHarness(
      config: config,
      dataDir: tempDir.path,
      harnessFactory: factory,
      exitFn: _unexpectedExit,
      storage: storage!,
      security: security!,
      eventBus: eventBus,
      serverRefGetter: () => throw UnimplementedError('serverRefGetter should not be called'),
    );
  }

  /// Wires an unwired [HarnessWiring] so a test can assert on `wire()` itself.
  Future<void> wireHarnessExpectingFailure(HarnessFactory factory, Matcher matcher) async {
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
    try {
      await expectLater(
        harnessWiring!.wire(serverRefGetter: () => throw UnimplementedError('serverRefGetter should not be called')),
        matcher,
      );
    } finally {
      // An unwired instance has no coordinator for tearDown to dispose.
      harnessWiring = null;
    }
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

  test('direct config rejects a blank primary provider', () async {
    config = config.copyWith(agent: const AgentConfig(provider: ' '));
    await wireStorageAndSecurity();

    await expectLater(() => wireHarness(fakeFactory(['claude'])), throwsStateError);
  });

  test('direct config rejects a blank logical-agent provider', () async {
    config = config.copyWith(
      agent: const AgentConfig(
        provider: 'claude',
        definitions: [AgentDefinition(id: 'reviewer', description: 'Review', prompt: 'Review', provider: ' ')],
      ),
    );
    await wireStorageAndSecurity();

    await expectLater(() => wireHarness(fakeFactory(['claude'])), throwsStateError);
  });

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

  test('primary runner keeps interactive prompt while spawned worker gets lean task prompt', () async {
    config = config.copyWith(
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 2)},
      ),
    );
    await wireStorageAndSecurity();

    final factory = fakeFactory(['claude'], onCreate: (_, factoryConfig) => recordedConfigs.add(factoryConfig));
    await wireHarness(factory);
    File(p.join(config.workspaceDir, 'SOUL.md')).writeAsStringSync('Changed after wiring');

    expect(harnessWiring!.executions.runners, hasLength(1));
    expect(createdHarnesses, hasLength(1));

    final workerLease = await harnessWiring!.executions.acquire(
      executionRequest(providerId: 'claude', sessionId: 'task-session'),
    );
    expect(harnessWiring!.executions.runners, hasLength(2));
    expect(recordedConfigs, hasLength(2));
    expect(createdHarnesses, hasLength(2));
    expect(recordedConfigs.first.harnessConfig.mcpServerUrl, 'http://localhost:3333/mcp');
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
    expect(recordedConfigs.last.acpPermissionDecision, isNotNull);
    expect(recordedConfigs.last.acpReverseCallAudit, isNotNull);

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
    expect(taskPrompt, isNot(contains('Changed after wiring')));
    expect(taskPrompt, contains('Tool prompt'));
    expect(taskPrompt, contains('## Agent prompt'));
    expect(taskPrompt, contains('memory_read tool'));
    expect(taskPrompt, isNot(contains('User prompt')));
    expect(taskPrompt, isNot(contains('## Recent error')));
    expect(taskPrompt, isNot(contains('## Recent learning')));
    expect(taskPrompt.length, lessThan(primaryPrompt.length));

    final secondWorkerLease = await harnessWiring!.executions.acquire(
      executionRequest(providerId: 'claude', sessionId: 'other-session'),
    );
    final firstRunner = workerLease!.runner;
    await secondWorkerLease!.release();
    await workerLease.release();
    final reusedLease = await harnessWiring!.executions.acquire(
      executionRequest(providerId: 'claude', sessionId: 'task-session'),
    );
    addTearDown(reusedLease!.release);
    expect(reusedLease.runner, same(firstRunner));
  });

  test('lazy worker ACP decisions use that worker identity and active tool policy', () async {
    config = config.copyWith(
      agent: const AgentConfig(
        provider: 'claude',
        definitions: [
          AgentDefinition(id: 'shell-worker', description: 'Shell worker', prompt: 'Work', allowedTools: {'shell'}),
        ],
      ),
      harness: HarnessConfig(
        acp: AcpConfig(
          agents: {
            'goose': AcpAgentConfig(
              binary: Platform.resolvedExecutable,
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
    );
    await wireStorageAndSecurity();
    final factory = fakeFactory(['claude'], onCreate: (_, factoryConfig) => recordedConfigs.add(factoryConfig));
    await wireHarness(factory);
    factory.register('goose', (factoryConfig) {
      recordedConfigs.add(factoryConfig);
      final harness = FakeAgentHarness(promptStrategy: PromptStrategy.append);
      createdHarnesses.add(harness);
      return harness;
    });

    final readOnlyLease = await harnessWiring!.executions.acquire(
      executionRequest(providerId: 'goose', sessionId: 'read-only-task'),
    );
    final shellLease = await harnessWiring!.executions.acquire(
      executionRequest(providerId: 'goose', sessionId: 'shell-task'),
    );
    addTearDown(() => readOnlyLease?.release());
    addTearDown(() => shellLease?.release());
    readOnlyLease!.runner!.setTaskToolFilter(const ['file_read']);
    shellLease!.runner!.setTaskToolFilter(const ['shell']);

    final readOnlyDecision = recordedConfigs[1].acpPermissionDecision!;
    final shellDecision = recordedConfigs[2].acpPermissionDecision!;
    const shellRequest = AcpPermissionRequest(operation: 'shell', params: {'command': 'pwd'}, agentId: 'shell-worker');

    expect((await readOnlyDecision(shellRequest)).granted, isFalse);
    expect((await shellDecision(shellRequest)).granted, isTrue);
    final identityDenied = await shellDecision(
      const AcpPermissionRequest(operation: 'file_read', params: {'path': 'README.md'}, agentId: 'shell-worker'),
    );
    expect(identityDenied.granted, isFalse);
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

    expect(messages, contains(contains('Security guards are disabled')));
  });

  test('configured tool policy remains active when optional security guards are disabled', () async {
    config = config.copyWith(
      security: const SecurityConfig(guards: GuardConfig(enabled: false)),
      agent: const AgentConfig(
        provider: 'claude',
        definitions: [
          AgentDefinition(id: 'search', description: 'Search', prompt: 'Search', deniedTools: {'sessions_spawn'}),
        ],
      ),
    );

    await wireStorageAndSecurity();
    await wireHarness(fakeFactory(['claude'], onCreate: (_, factoryConfig) => recordedConfigs.add(factoryConfig)));

    final verdict = await recordedConfigs.single.guardChain!.evaluateBeforeToolCall(
      'sessions_spawn',
      const {'agent': 'search', 'message': 'nested'},
      agentId: 'search',
      rawProviderToolName: 'mcp__dartclaw__sessions_spawn',
    );
    expect(verdict, isA<GuardBlock>());
  });

  test('logical agents are not forwarded as provider-native agents', () async {
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

    expect(recordedConfigs.single.harnessConfig.toInitializeFields(), isNot(contains('agents')));
  });

  test('token-authenticated harness reaches the server on its bound loopback host', () async {
    config = config.copyWith(
      gateway: const GatewayConfig(authMode: 'token', token: 'test-token'),
    );

    await wireStorageAndSecurity();
    await wireHarness(fakeFactory(['claude'], onCreate: (_, factoryConfig) => recordedConfigs.add(factoryConfig)));

    expect(recordedConfigs.single.harnessConfig.mcpServerUrl, 'http://localhost:3333/mcp');
  });

  test('authentication-disabled loopback harness uses the standard MCP endpoint', () async {
    await wireStorageAndSecurity();
    await wireHarness(fakeFactory(['claude'], onCreate: (_, factoryConfig) => recordedConfigs.add(factoryConfig)));

    final harnessConfig = recordedConfigs.single.harnessConfig;
    expect(harnessConfig.mcpServerUrl, 'http://localhost:3333/mcp');
    expect(harnessConfig.mcpGatewayToken, isNull);
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

  test('wired logical-agent sessions apply configured persona, model, and effort', () async {
    config = config.copyWith(
      agent: const AgentConfig(
        provider: 'claude',
        definitions: [
          AgentDefinition(
            id: 'search',
            description: 'Search',
            prompt: 'SEARCH PERSONA',
            securityProfile: 'workspace',
            allowedTools: {'web_search', 'web_fetch'},
          ),
          AgentDefinition(
            id: 'summarizer',
            description: 'Summarize',
            prompt: 'SUMMARY PERSONA',
            model: 'custom-model',
            effort: 'low',
          ),
        ],
      ),
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
              ..executions = harnessWiring!.executions
              ..sessionsForTurns = storage!.sessions
              ..config = config)
            .build();

    Future<void> expectLogicalAgentSession({
      required String agent,
      required String persona,
      required String? model,
      required String? effort,
    }) async {
      final resultFuture = harnessWiring!.logicalAgentSessions.handleSessionsSpawn({
        'agent': agent,
        'message': 'Handle this',
      });
      await _pollFor(() => createdHarnesses.length, (length) => length == 2);
      final logicalAgentHarness = createdHarnesses.last;
      await logicalAgentHarness.turnInvoked;
      final internalSessionId = logicalAgentHarness.lastSessionId;
      expect(logicalAgentHarness.lastAgentId, agent);
      expect(logicalAgentHarness.lastSystemPrompt, contains(persona));
      expect(logicalAgentHarness.lastModel, model);
      expect(logicalAgentHarness.lastEffort, effort);
      logicalAgentHarness.emit(DeltaEvent('$agent result'));
      logicalAgentHarness.completeSuccess();
      final result = await resultFuture;
      expect(result['isError'], isNull);
      expect(result['content'], contains(containsPair('text', '$agent result')));
      final sessionId = result['sessionId'] as String;
      final followUpFuture = harnessWiring!.logicalAgentSessions.handleSessionsSend({
        'session_id': sessionId,
        'message': 'Continue this',
      });
      await logicalAgentHarness.turnInvoked;
      expect(createdHarnesses, hasLength(2));
      expect(createdHarnesses.last, same(logicalAgentHarness));
      expect(logicalAgentHarness.lastSessionId, internalSessionId);
      expect(logicalAgentHarness.lastMessages, [
        {'role': 'user', 'content': 'Handle this'},
        {'role': 'assistant', 'content': '$agent result'},
        {'role': 'user', 'content': 'Continue this'},
      ]);
      logicalAgentHarness.emit(DeltaEvent('$agent follow-up'));
      logicalAgentHarness.completeSuccess();
      final followUp = await followUpFuture;
      expect(followUp['isError'], isNull);
      expect(followUp['content'], contains(containsPair('text', '$agent follow-up')));
    }

    await expectLogicalAgentSession(agent: 'search', persona: 'SEARCH PERSONA', model: null, effort: null);
    await expectLogicalAgentSession(
      agent: 'summarizer',
      persona: 'SUMMARY PERSONA',
      model: 'custom-model',
      effort: 'low',
    );
    final sessionsBefore = await storage!.sessions.listSessions(type: SessionType.logicalAgent);
    expect(sessionsBefore, hasLength(2));
    expect(
      (await storage!.sessions.listSessions()).map((session) => session.type),
      isNot(contains(SessionType.logicalAgent)),
    );
    for (final session in sessionsBefore) {
      expect(session.type, SessionType.logicalAgent);
      expect(session.provider, 'claude');
      expect(await storage!.messages.getMessages(session.id), isNotEmpty);
    }
    final unknown = await harnessWiring!.logicalAgentSessions.handleSessionsSend({
      'session_id': 'agent:search:logical:missing',
      'message': 'Do not create this',
    });
    expect(unknown['isError'], isTrue);
    expect((unknown['content'] as List).first['text'], contains('Unknown logical-agent session'));
    expect(await storage!.sessions.listSessions(type: SessionType.logicalAgent), hasLength(sessionsBefore.length));
  });

  test('logical-agent restricted profile fails closed when container isolation is unavailable', () async {
    config = config.copyWith(
      agent: const AgentConfig(
        provider: 'claude',
        definitions: [
          AgentDefinition(id: 'search', description: 'Search', prompt: 'SEARCH PERSONA', securityProfile: 'restricted'),
        ],
      ),
    );
    await wireStorageAndSecurity();
    await wireHarness(fakeFactory(['claude']));
    final result = await harnessWiring!.logicalAgentSessions.handleSessionsSpawn({
      'agent': 'search',
      'message': 'Search safely',
    });
    expect(result['isError'], isTrue);
    expect(
      (result['content'] as List).first['text'],
      allOf(
        contains('logical agent "search"'),
        contains('"restricted"'),
        contains('agent.agents.search.execution: host'),
      ),
      reason: 'the diagnostic names the agent, its container profile, and the accepted remediation',
    );
    expect(createdHarnesses, hasLength(1));
  });

  test('wired logical-agent sessions use the configured provider and trim unset overrides', () async {
    const configuredProviderId = 'OpenAI-Work';
    const providerId = 'openai-work';
    config = config.copyWith(
      agent: const AgentConfig(
        provider: 'claude',
        definitions: [
          AgentDefinition(
            id: 'search',
            description: 'Search',
            prompt: 'SEARCH PERSONA',
            provider: configuredProviderId,
          ),
          AgentDefinition(
            id: 'blank',
            description: 'Blank',
            prompt: '   ',
            provider: configuredProviderId,
            model: '   ',
            effort: '   ',
          ),
        ],
      ),
      providers: ProvidersConfig(
        entries: {
          'claude': ProviderEntry(
            executable: Platform.resolvedExecutable,
            poolSize: 1,
            options: const {'credentials_required': false},
          ),
          configuredProviderId: ProviderEntry(
            executable: Platform.resolvedExecutable,
            poolSize: 1,
            options: const {'family': 'codex', 'approval': 'on-request', 'credentials_required': false},
          ),
        },
      ),
      credentials: const CredentialsConfig(entries: {'openai': CredentialEntry(apiKey: 'openai-key')}),
    );
    await wireStorageAndSecurity();
    final factory = fakeFactory(['claude', providerId]);
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
              ..executions = harnessWiring!.executions
              ..sessionsForTurns = storage!.sessions
              ..config = config)
            .build();

    Future<void> completeLogicalAgentSession(String agentId) async {
      final resultFuture = harnessWiring!.logicalAgentSessions.handleSessionsSpawn({
        'agent': agentId,
        'message': 'Handle this',
      });
      await _pollFor(() => createdHarnesses.length, (length) => length == 2);
      final logicalAgentHarness = createdHarnesses.last;
      await logicalAgentHarness.turnInvoked;
      if (agentId == 'search') {
        expect(logicalAgentHarness.lastSystemPrompt, contains('SEARCH PERSONA'));
        expect(logicalAgentHarness.lastModel, isNull);
        expect(logicalAgentHarness.lastEffort, isNull);
      } else {
        expect(logicalAgentHarness.lastSystemPrompt, isNot('   '));
        expect(logicalAgentHarness.lastModel, isNull);
        expect(logicalAgentHarness.lastEffort, isNull);
      }
      logicalAgentHarness.emit(DeltaEvent('$agentId result'));
      logicalAgentHarness.completeSuccess();
      expect((await resultFuture)['isError'], isNull);
    }

    await completeLogicalAgentSession('search');
    await completeLogicalAgentSession('blank');
    expect(
      (await storage!.sessions.listSessions(type: SessionType.logicalAgent)).map((session) => session.provider),
      everyElement(providerId),
    );
  });

  test('wired logical-agent sessions apply the configured content guard', () async {
    config = config.copyWith(
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: '/bin/echo'),
      agent: const AgentConfig(
        provider: 'claude',
        definitions: [AgentDefinition(id: 'search', description: 'Search', prompt: 'Search')],
      ),
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
              ..executions = harnessWiring!.executions
              ..sessionsForTurns = storage!.sessions
              ..config = config)
            .build();

    final resultFuture = harnessWiring!.logicalAgentSessions.handleSessionsSpawn({
      'agent': 'search',
      'message': 'Handle this',
    });
    await _pollFor(() => createdHarnesses.length, (length) => length == 2);
    final logicalAgentHarness = createdHarnesses.last;
    await logicalAgentHarness.turnInvoked;
    logicalAgentHarness.emit(DeltaEvent('unsafe result'));
    logicalAgentHarness.completeSuccess();

    final result = await resultFuture;
    expect(result['isError'], isTrue);
    expect((result['content'] as List).first['text'], contains('content-guard'));
    expect(await storage!.sessions.listSessions(type: SessionType.logicalAgent), isEmpty);
    expect(await storage!.sessions.listSessions(type: SessionType.archive), hasLength(1));
  });

  test('knowledge-inbox no-tools turn policy blocks tool calls on the acquired worker chain', () async {
    await wireStorageAndSecurity();

    final factory = fakeFactory(['claude'], onCreate: (_, factoryConfig) => recordedConfigs.add(factoryConfig));
    await wireHarness(factory);

    final session = await storage!.sessions.createSession();
    final existingConfigCount = recordedConfigs.length;
    final workerLease = await harnessWiring!.executions
        .acquire(executionRequest(providerId: 'claude', sessionId: session.id))
        .timeout(const Duration(seconds: 2));
    addTearDown(() => workerLease?.release());
    final workerChain = recordedConfigs.skip(existingConfigCount).single.guardChain!;
    final workerRunner = workerLease!.runner!;
    final turnId = await workerRunner
        .reserveAdmittedTurn(session.id, allowedTools: const ['__knowledge_inbox_no_tools__'], readOnly: true)
        .timeout(const Duration(seconds: 2));
    workerRunner.executeTurn(session.id, turnId, [
      {'role': 'user', 'content': 'extract facts'},
    ]);
    final harness = workerRunner.harness as FakeAgentHarness;
    await harness.turnInvoked.timeout(const Duration(seconds: 2));

    // The harness consults its guard chain for every tool call mid-turn; the
    // turn's session-keyed no-tools policy must block.
    final midTurn = await workerChain.evaluateBeforeToolCall('shell', {'command': 'ls'}, sessionId: session.id);
    expect(midTurn.isBlock, isTrue);
    expect(midTurn.message, contains('__knowledge_inbox_no_tools__'));

    // Other sessions on the same chain are unaffected.
    final otherSession = await workerChain.evaluateBeforeToolCall('shell', {'command': 'ls'}, sessionId: 'other');
    expect(otherSession.isBlock, isFalse);

    harness.completeSuccess();
    await workerRunner.waitForOutcome(session.id, turnId).timeout(const Duration(seconds: 2));
    await workerLease.release().timeout(const Duration(seconds: 2));

    // The policy is cleared once the turn settles.
    final postTurn = await workerChain.evaluateBeforeToolCall('shell', {'command': 'ls'}, sessionId: session.id);
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

    expect(harnessWiring!.executions.snapshot.cachedWorkers, 0);
    final codexLease = await harnessWiring!.executions.acquire(
      executionRequest(providerId: 'codex', sessionId: 'codex-task'),
    );
    addTearDown(() => codexLease?.release());
    expect(createdProviderIds, ['claude', 'codex']);
    expect(codexLease!.runner!.providerId, 'codex');
    expect(codexLease.runner!.executionPolicy, const ExecutionPolicy.host());
    expect(harnessWiring!.executions.runners.where((runner) => runner.providerId == 'claude'), hasLength(1));
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
    );

    await wireStorageAndSecurity();

    final factory = fakeFactory(['claude']);
    await wireHarness(factory);

    expect(factory.supports('goose'), isTrue);
    expect(harnessWiring!.executions.snapshot.configuredWorkers, 2);
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
    );

    await wireStorageAndSecurity();

    final factory = fakeFactory(['claude']);
    await wireHarness(factory);

    expect(factory.supports('goose'), isTrue);
    expect(factory.supports('vibe'), isTrue);
    expect(factory.supports('missing_acp_agent'), isFalse);
    expect(
      harnessWiring!.providerStatusEntries['goose']!.options['acp_validation_result'],
      containsPair('securityClassification', 'host_only'),
    );
    expect(harnessWiring!.providerStatusEntries['goose']!.options['acp_validation_owned'], isTrue);
    expect(
      harnessWiring!.providerStatusEntries['vibe']!.options['acp_validation_result'],
      containsPair('securityClassification', 'host_only'),
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
    );

    await wireStorageAndSecurity();

    final factory = fakeFactory(['claude']);
    await wireHarnessExpectingFailure(
      factory,
      throwsA(isA<StateError>().having((error) => error.message, 'message', contains('operation probe evidence'))),
    );
    expect(factory.supports('goose'), isFalse);
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
    );

    await wireStorageAndSecurity();

    final factory = fakeFactory(['claude']);
    await wireHarness(factory);

    expect(factory.supports('goose'), isTrue);
    expect(harnessWiring!.executions.snapshot.configuredWorkers, 2);
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
    );

    await wireStorageAndSecurity();

    final factory = fakeFactory(['claude']);
    await wireHarness(factory);

    expect(factory.supports('goose'), isTrue);
    expect(harnessWiring!.executions.snapshot.configuredWorkers, 3);
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

  test('a container-required ACP registration is rejected at startup with its exact configuration path', () async {
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
    );

    await wireStorageAndSecurity();

    final factory = fakeFactory(['claude']);
    await wireHarnessExpectingFailure(
      factory,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          allOf(contains('harness.acp.agents.goose.topology'), contains('mediation for an ACP client')),
        ),
      ),
    );
    expect(factory.supports('goose'), isFalse, reason: 'a doomed registration never reaches the factory');
  });

  test('a container policy this deployment cannot provide fails closed naming the profile', () async {
    await wireStorageAndSecurity();
    await wireHarness(fakeFactory(['claude']));
    final capacityBefore = harnessWiring!.executions.snapshot.availableWorkers;

    // No container runtime is available here, so authority acquisition fails;
    // the failure must surface as a worker-creation rejection naming the
    // profile rather than escaping raw, and must release the capacity it took.
    await expectLater(
      harnessWiring!.executions.acquire(
        executionRequest(
          providerId: 'claude',
          sessionId: 'claude-task',
          policy: const ExecutionPolicy.container('workspace'),
        ),
      ),
      throwsA(
        isA<WorkerCreationException>().having(
          (error) => error.message,
          'message',
          contains('requires unavailable container profile "workspace"'),
        ),
      ),
    );
    expect(harnessWiring!.executions.snapshot.availableWorkers, capacityBefore);
  });

  test('a host-only ACP registration composes the inventory and is refused a container policy', () async {
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
              requiredBuiltins: const ['developer'],
            ),
          },
        ),
      ),
      providers: const ProvidersConfig(),
    );

    await wireStorageAndSecurity();

    final factory = fakeFactory(['claude']);
    await wireHarness(factory);

    final inventory = harnessWiring!.executionInventory;
    expect(inventory.supports['goose']!.registrationYamlPath, 'harness.acp.agents.goose');
    expect(inventory.supports['goose']!.surfaces, {ProviderLaunchSurface.longLived});
    expect(inventory.supports['claude']!.containerMediationGap, isNull);

    final capacityBefore = harnessWiring!.executions.snapshot.availableWorkers;
    await expectLater(
      harnessWiring!.executions.acquire(
        executionRequest(
          providerId: 'goose',
          sessionId: 'goose-task',
          policy: const ExecutionPolicy.container('workspace'),
        ),
      ),
      throwsA(
        isA<WorkerCreationException>().having(
          (error) => error.message,
          'message',
          allOf(
            contains('"goose" cannot run as container/workspace'),
            contains('harness.acp.agents.goose'),
            contains('Select host execution'),
            isNot(contains('anthropic-key')),
          ),
        ),
      ),
    );
    expect(harnessWiring!.executions.runners.where((runner) => runner.providerId == 'goose'), isEmpty);
    expect(harnessWiring!.executions.snapshot.availableWorkers, capacityBefore, reason: 'capacity is released');
    expect(factory.supports('goose'), isTrue, reason: 'the registration itself stays valid for host execution');
  });
}
