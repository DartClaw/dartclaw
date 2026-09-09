import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show ExecutionRequest, ExecutionSurface;
import 'package:dartclaw_runtime/src/runtime/harness_wiring.dart';
import 'package:dartclaw_runtime/src/runtime/security_wiring.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

import 'harness_wiring_fixture.dart';

void main() {
  late Directory tempDir;
  late DartclawConfig config;
  late EventBus eventBus;
  late List<HarnessFactoryConfig> recordedConfigs;
  late List<FakeAgentHarness> createdHarnesses;
  StorageWiring? storage;
  SecurityWiring? security;
  HarnessWiring? harnessWiring;

  Never unexpectedExit(int code) => throw StateError('Unexpected exit($code)');

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_harness_tool_policy_');
    config = DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      agent: const AgentConfig(provider: 'claude'),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1)},
      ),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      gateway: const GatewayConfig(authMode: 'none'),
      security: const SecurityConfig(contentGuardFailOpen: true),
    );
    eventBus = EventBus();
    recordedConfigs = [];
    createdHarnesses = [];
  });

  tearDown(() async {
    await harnessWiring?.executions.dispose();
    await security?.dispose();
    await storage?.dispose();
    tempDir.deleteSync(recursive: true);
  });

  Future<void> wireStorageAndSecurity() async {
    await writeWorkspacePromptFiles(config.workspaceDir);
    storage = await wireTestStorage(config: config, eventBus: eventBus, exitFn: unexpectedExit);
    security = await wireTestSecurity(
      config: config,
      dataDir: tempDir.path,
      eventBus: eventBus,
      exitFn: unexpectedExit,
    );
  }

  Future<void> wireHarness(HarnessFactory factory) async {
    harnessWiring = await wireTestHarness(
      config: config,
      dataDir: tempDir.path,
      harnessFactory: factory,
      exitFn: unexpectedExit,
      storage: storage!,
      security: security!,
      eventBus: eventBus,
      serverRefGetter: () => throw UnimplementedError(),
    );
  }

  HarnessFactory fakeFactory(
    Iterable<String> providerIds, {
    void Function(String providerId, HarnessFactoryConfig)? onCreate,
    bool supportsNoWorkTools = true,
  }) {
    final factory = HarnessFactory();
    for (final providerId in providerIds) {
      factory.register(providerId, (factoryConfig) {
        onCreate?.call(providerId, factoryConfig);
        final harness = FakeAgentHarness(
          promptStrategy: PromptStrategy.append,
          supportsNoWorkTools: supportsNoWorkTools,
        );
        createdHarnesses.add(harness);
        return harness;
      });
    }
    return factory;
  }

  test('an explicit empty logical-agent policy stays empty and permits only structured output', () async {
    config = config.copyWith(
      agent: const AgentConfig(
        provider: 'claude',
        definitions: [
          AgentDefinition(id: 'broad-agent', description: 'Broad', prompt: 'Work', allowedTools: {'shell'}),
        ],
      ),
    );
    await wireStorageAndSecurity();
    final factory = fakeFactory(['claude'], onCreate: (_, factoryConfig) => recordedConfigs.add(factoryConfig));
    await wireHarness(factory);

    final lease = await harnessWiring!.executions.acquire(
      const ExecutionRequest(
        surface: ExecutionSurface.logicalAgent,
        providerId: 'claude',
        policy: ExecutionPolicy.host(),
        sessionId: 'logical-empty',
        logicalAgentId: 'broad-agent',
        allowedTools: [],
      ),
    );
    addTearDown(() async => lease?.release());

    final factoryConfig = recordedConfigs.last;
    final filter = factoryConfig.guardChain!.guards.whereType<TaskToolFilterGuard>().single;
    filter.setSessionToolFilter('logical-empty', const [], allowClaudeStructuredOutput: true);
    expect(factoryConfig.declaredCanonicalTools, isEmpty);
    expect(filter.denyEmptyAllowlist, isTrue);
    expect(filter.allowedTools, isEmpty);
    for (final tool in [
      'shell',
      'file_read',
      'file_write',
      'web_fetch',
      'web_search',
      'mcp_call',
      'memory_read',
      'memory_apply',
      'sessions_spawn',
      'claude:ToolSearch',
      'claude:Skill',
      'claude:Task',
      'claude:Unknown',
    ]) {
      expect((await factoryConfig.guardChain!.evaluateBeforeToolCall(tool, const {})).isBlock, isTrue, reason: tool);
    }
    expect(
      (await factoryConfig.guardChain!.evaluateBeforeToolCall(
        'claude:StructuredOutput',
        const {},
        rawProviderToolName: 'StructuredOutput',
        sessionId: 'logical-empty',
      )).isPass,
      isTrue,
    );
  });

  test('an incapable aliased harness refuses an empty policy before startup and releases capacity', () async {
    config = config.copyWith(
      providers: ProvidersConfig(
        entries: {
          ...config.providers.entries,
          'codex-alias': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1),
        },
      ),
    );
    await wireStorageAndSecurity();
    final factory = fakeFactory(
      ['claude', 'codex-alias'],
      supportsNoWorkTools: false,
      onCreate: (_, factoryConfig) => recordedConfigs.add(factoryConfig),
    );
    await wireHarness(factory);

    await expectLater(
      harnessWiring!.executions.acquire(
        const ExecutionRequest(
          surface: ExecutionSurface.logicalAgent,
          providerId: 'codex-alias',
          policy: ExecutionPolicy.host(),
          sessionId: 'judge',
          allowedTools: [],
        ),
      ),
      throwsA(
        isA<UnsupportedHarnessCapabilityException>()
            .having((error) => error.provider, 'provider', 'codex-alias')
            .having((error) => error.capability, 'capability', AgentHarness.noWorkToolsCapability),
      ),
    );

    final refused = createdHarnesses.last;
    expect(recordedConfigs.last.declaredCanonicalTools, isEmpty);
    expect(recordedConfigs.last.guardChain!.guards.whereType<TaskToolFilterGuard>().single.denyEmptyAllowlist, isTrue);
    expect(refused.startCalled, isFalse);
    expect(refused.turnCallCount, 0);
    expect(refused.disposeCalled, isTrue);
    expect(harnessWiring!.executions.snapshot.providers['codex-alias']!.active, 0);
  });

  test('an omitted policy does not require the empty-policy capability', () async {
    await wireStorageAndSecurity();
    final factory = fakeFactory(['claude'], supportsNoWorkTools: false);
    await wireHarness(factory);

    final lease = await harnessWiring!.executions.acquire(
      const ExecutionRequest(
        surface: ExecutionSurface.task,
        providerId: 'claude',
        policy: ExecutionPolicy.host(),
        sessionId: 'unrestricted',
      ),
    );
    addTearDown(() => lease?.release());

    expect(lease, isNotNull);
    expect(createdHarnesses.last.startCalled, isTrue);
  });
}
