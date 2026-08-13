import 'dart:io';

import 'package:dartclaw_cli/src/commands/wiring/harness_wiring.dart';
import 'package:dartclaw_cli/src/commands/wiring/security_wiring.dart';
import 'package:dartclaw_cli/src/commands/wiring/storage_wiring.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide HarnessConfig;
import 'package:dartclaw_server/dartclaw_server.dart'
    show
        ContainerAuthorityLease,
        ExecutionAdmission,
        ExecutionRequest,
        ExecutionSurface,
        GatewayPrincipal,
        containerGeneratedStatePath;
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import '../../helpers/harness_wiring_fixture.dart';

Never _unexpectedExit(int code) {
  throw StateError('Unexpected exit($code) during harness wiring test');
}

const _memoryMcpTools = {'memory_apply', 'memory_observe', 'memory_search', 'memory_read'};

/// A deployment whose container profiles are available without a container
/// runtime, recording the host-tool grant every authority is created with.
///
/// Authority acquisition is the only seam that sees the grant, and the real one
/// needs Docker, so the grants are read here instead.
class _GrantRecordingSecurityWiring extends SecurityWiring {
  new({required super.config, required super.dataDir, required super.eventBus, required super.exitFn});

  final grants = <({String sessionId, String? taskId, Set<String> allowedMcpTools})>[];

  @override
  Set<String> get availableContainerProfiles => const {'workspace', 'restricted'};

  @override
  Future<ContainerAuthorityLease> acquireContainerAuthority(
    GatewayPrincipal principal, {
    Set<String> allowedMcpTools = const {},
    String? artifactsDir,
  }) async {
    grants.add((sessionId: principal.sessionId, taskId: principal.taskId, allowedMcpTools: allowedMcpTools));
    return _FakeLease();
  }
}

class _FakeLease implements ContainerAuthorityLease {
  @override
  final ContainerExecutor container = _FakeContainer();

  @override
  Future<void> release() async {}
}

class _FakeContainer implements ContainerExecutor {
  @override
  final String profileId = 'workspace';

  @override
  final String workingDir = '/project';

  @override
  final bool hasProjectMount = true;

  @override
  final String generatedStateDir = '/tmp/dartclaw-fake-authority';

  @override
  final String providerBridgeUrl = 'http://127.0.0.1:8080';

  @override
  final String? mcpBridgeUrl = 'http://127.0.0.1:8081/mcp';

  @override
  Future<void> start() async {}

  @override
  Future<Process> exec(List<String> command, {Map<String, String>? env, String? workingDirectory}) =>
      throw UnimplementedError('The fake authority never spawns');

  @override
  String? containerPathForHostPath(String hostPath) => containerGeneratedStatePath;
}

void main() {
  late Directory tempDir;
  late DartclawConfig config;
  late EventBus eventBus;
  late List<HarnessFactoryConfig> recordedConfigs;
  StorageWiring? storage;
  _GrantRecordingSecurityWiring? security;
  HarnessWiring? harnessWiring;

  const braveSearch = SearchConfig(providers: {'brave': SearchProviderEntry(enabled: true, apiKey: 'brave-key')});

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_bridged_grant_');
    config = DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      agent: const AgentConfig(provider: 'claude'),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 2)},
      ),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      gateway: const GatewayConfig(authMode: 'none'),
      search: braveSearch,
    );
    writeWorkspacePromptFiles(config.workspaceDir);
    eventBus = EventBus();
    recordedConfigs = <HarnessFactoryConfig>[];
  });

  tearDown(() async {
    await harnessWiring?.executions.dispose();
    await security?.dispose();
    await storage?.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  HarnessFactory fakeFactory() {
    final factory = HarnessFactory();
    factory.register('claude', (factoryConfig) {
      recordedConfigs.add(factoryConfig);
      return FakeAgentHarness(promptStrategy: PromptStrategy.append);
    });
    return factory;
  }

  Future<List<LogRecord>> wireAll() async {
    storage = await wireTestStorage(config: config, eventBus: eventBus, exitFn: _unexpectedExit);
    security = _GrantRecordingSecurityWiring(
      config: config,
      dataDir: tempDir.path,
      eventBus: eventBus,
      exitFn: _unexpectedExit,
    );
    final records = <LogRecord>[];
    final subscription = Logger('HarnessWiring').onRecord.listen(records.add);
    try {
      await security!.wire(agentDefs: config.agent.definitions);
      harnessWiring = HarnessWiring(
        config: config,
        dataDir: tempDir.path,
        port: 3333,
        harnessFactory: fakeFactory(),
        exitFn: _unexpectedExit,
        storage: storage!,
        security: security!,
        messageRedactor: MessageRedactor(),
        eventBus: eventBus,
      );
      await harnessWiring!.wire(
        serverRefGetter: () => throw UnimplementedError('serverRefGetter should not be called'),
      );
      return records;
    } finally {
      await subscription.cancel();
    }
  }

  test('a research task in a container is granted the host tools its own policy allows', () async {
    await wireAll();

    final lease = await harnessWiring!.executions.acquire(
      ExecutionRequest(
        surface: ExecutionSurface.task,
        providerId: 'claude',
        policy: const ExecutionPolicy.container('restricted'),
        sessionId: 'research-session',
        admission: ExecutionAdmission.failFast,
        taskId: 'research-task',
        allowedTools: const ['web_search', 'web_fetch'],
      ),
    );
    addTearDown(() async => lease?.release());

    final grant = security!.grants.singleWhere((entry) => entry.taskId == 'research-task');
    expect(grant.allowedMcpTools, {
      'web_search',
      'web_fetch',
    }, reason: 'background work carries no agent definition, so its own tool policy is what authorizes host tools');
  });

  test('a task with no tool policy is granted nothing, and the capability loss is named', () async {
    final records = <LogRecord>[];
    final subscription = Logger('HarnessWiring').onRecord.listen(records.add);
    addTearDown(subscription.cancel);
    await wireAll();

    final lease = await harnessWiring!.executions.acquire(
      ExecutionRequest(
        surface: ExecutionSurface.task,
        providerId: 'claude',
        policy: const ExecutionPolicy.container('restricted'),
        sessionId: 'plain-session',
        admission: ExecutionAdmission.failFast,
        taskId: 'plain-task',
      ),
    );
    addTearDown(() async => lease?.release());

    expect(security!.grants.singleWhere((entry) => entry.taskId == 'plain-task').allowedMcpTools, isEmpty);
    expect(
      records.map((record) => record.message),
      contains(allOf(contains('no host MCP tools'), contains('restricted'), contains('allowed_tools'))),
      reason: 'silent capability loss is the failure mode this diagnostic exists for',
    );
  });

  test('a containerized primary keeps the deployment capability tools but not session spawning', () async {
    config = config.copyWith(
      agent: const AgentConfig(provider: 'claude', execution: ExecutionMode.container),
    );

    await wireAll();

    final grant = security!.grants.singleWhere((entry) => entry.sessionId == 'primary');
    expect(grant.allowedMcpTools, {'web_search', 'web_fetch', ..._memoryMcpTools});
    expect(
      grant.allowedMcpTools,
      isNot(anyOf(contains('sessions_spawn'), contains('sessions_send'))),
      reason: 'orchestrating other executions is not a capability a container keeps',
    );
    expect(
      recordedConfigs.first.harnessConfig.disallowedTools,
      containsAll(['WebFetch', 'WebSearch']),
      reason: 'the bridged tools replace the native ones',
    );
  });

  test('a provider-native-spelled global deny still subtracts from the primary bridged grant', () async {
    config = config.copyWith(
      agent: const AgentConfig(
        provider: 'claude',
        execution: ExecutionMode.container,
        // `WebSearch` is the spelling the harness --disallowedTools flag needs;
        // the grant is derived from canonical names, so it must normalize before
        // subtracting or the operator's deny silently does nothing.
        disallowedTools: ['WebSearch'],
      ),
    );

    await wireAll();

    final grant = security!.grants.singleWhere((entry) => entry.sessionId == 'primary');
    expect(grant.allowedMcpTools, {
      'web_fetch',
      ..._memoryMcpTools,
    }, reason: 'a native-spelled global deny of WebSearch must remove the canonical web_search grant');
  });

  test('a provider-native-spelled task allow-list still grants the canonical bridged tool', () async {
    await wireAll();

    final lease = await harnessWiring!.executions.acquire(
      ExecutionRequest(
        surface: ExecutionSurface.task,
        providerId: 'claude',
        policy: const ExecutionPolicy.container('restricted'),
        sessionId: 'native-allow-session',
        admission: ExecutionAdmission.failFast,
        taskId: 'native-allow-task',
        // Provider-native spelling; the host guard chain normalizes it, so the
        // bridged grant must too or the allow-list collapses to an empty grant.
        allowedTools: const ['WebFetch'],
      ),
    );
    addTearDown(() async => lease?.release());

    expect(security!.grants.singleWhere((entry) => entry.taskId == 'native-allow-task').allowedMcpTools, {
      'web_fetch',
    }, reason: 'a native-spelled allow of WebFetch must resolve to the canonical web_fetch grant, not nothing');
  });

  test('a containerized primary granted no bridged search still loses its native search', () async {
    config = config.copyWith(
      agent: const AgentConfig(provider: 'claude', execution: ExecutionMode.container),
      search: const SearchConfig(),
    );

    await wireAll();

    final grant = security!.grants.singleWhere((entry) => entry.sessionId == 'primary');
    expect(grant.allowedMcpTools, {'web_fetch', ..._memoryMcpTools});
    expect(
      recordedConfigs.first.harnessConfig.disallowedTools,
      containsAll(['WebFetch', 'WebSearch']),
      reason:
          'the native tools run at the provider, so the host gateway refuses them from any container profile — '
          'keeping one only moves the failure to the agent first calling it',
    );
  });

  test('an ordinary workspace-container task never declares the tools the gateway refuses', () async {
    final records = <LogRecord>[];
    final subscription = Logger('HarnessWiring').onRecord.listen(records.add);
    addTearDown(subscription.cancel);
    await wireAll();

    final lease = await harnessWiring!.executions.acquire(
      ExecutionRequest(
        surface: ExecutionSurface.task,
        providerId: 'claude',
        policy: const ExecutionPolicy.container('workspace'),
        sessionId: 'coding-session',
        admission: ExecutionAdmission.failFast,
        taskId: 'coding-task',
      ),
    );
    addTearDown(() async => lease?.release());

    final workerConfig = recordedConfigs.last;
    expect(workerConfig.containerManager, isNotNull);
    expect(
      workerConfig.harnessConfig.disallowedTools,
      containsAll(['WebFetch', 'WebSearch']),
      reason:
          'the harness layer must not enable what the gateway 403s — otherwise every default containerized turn '
          'fails on its first provider request',
    );
    expect(
      records.map((record) => record.message),
      isNot(contains(contains('no host MCP tools'))),
      reason: 'a workspace coding task with no tool policy is the intended default, not a capability loss to warn on',
    );
  });

  test('an agent allowed a tool this deployment cannot serve is reported at startup, not at its first turn', () async {
    config = config.copyWith(
      search: const SearchConfig(),
      agent: const AgentConfig(
        provider: 'claude',
        definitions: [
          AgentDefinition(
            id: 'search',
            description: 'Search',
            prompt: 'Search',
            allowedTools: {'web_search', 'web_fetch'},
          ),
        ],
      ),
    );

    final records = await wireAll();

    expect(
      records.map((record) => record.message),
      contains(
        allOf(
          contains('Agent "search"'),
          contains('web_search'),
          contains('registers no such tool'),
          contains('search.providers'),
        ),
      ),
    );

    final lease = await harnessWiring!.executions.acquire(
      ExecutionRequest(
        surface: ExecutionSurface.logicalAgent,
        providerId: 'claude',
        policy: const ExecutionPolicy.container('restricted'),
        sessionId: 'agent-session',
        admission: ExecutionAdmission.failFast,
        logicalAgentId: 'search',
      ),
    );
    addTearDown(() async => lease?.release());

    expect(security!.grants.singleWhere((entry) => entry.sessionId == 'agent-session').allowedMcpTools, {
      'web_fetch',
    }, reason: 'an unservable canonical is dropped rather than granted against nothing');
  });

  test('the workflow one-shot grant resolver subtracts the deployment-wide deny', () async {
    config = config.copyWith(
      agent: const AgentConfig(provider: 'claude', disallowedTools: ['web_fetch']),
    );

    await wireAll();

    expect(harnessWiring!.workflowBridgedMcpTools(const ['web_fetch', 'web_search']), {
      'web_search',
    }, reason: 'agent.disallowed_tools must bound a containerized workflow step — pre-fix it subtracted nothing');
  });

  test('the workflow one-shot grant resolver normalizes a native-spelled deny before subtracting', () async {
    config = config.copyWith(
      agent: const AgentConfig(provider: 'claude', disallowedTools: ['WebFetch']),
    );

    await wireAll();

    expect(harnessWiring!.workflowBridgedMcpTools(const ['web_fetch', 'web_search']), {
      'web_search',
    }, reason: 'a native-spelled global deny of WebFetch must remove the canonical web_fetch grant');
  });

  test('the workflow one-shot grant resolver drops an unservable grant so no MCP bridge is falsely declared', () async {
    // No search providers configured, so web_search is unservable. Pre-fix the
    // workflow site intersected nothing, silently declaring an MCP bridge that
    // denies everything.
    config = config.copyWith(search: const SearchConfig());

    await wireAll();

    expect(
      harnessWiring!.workflowBridgedMcpTools(const ['web_search']),
      isEmpty,
      reason: 'an unservable canonical must not become a grant (empty grant → hasMcpBridge false)',
    );
  });
}
