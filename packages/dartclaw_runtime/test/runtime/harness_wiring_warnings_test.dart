import 'dart:io';

import 'package:dartclaw_acp/dartclaw_acp.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/runtime/harness_wiring.dart';
import 'package:dartclaw_runtime/src/runtime/security_wiring.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show ContainerAuthorityLease, GatewayPrincipal;
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'fake_container_authority.dart';
import 'harness_wiring_fixture.dart';

Never _unexpectedExit(int code) {
  throw StateError('Unexpected exit($code) during harness wiring test');
}

/// Stands in for a host that found a container runtime: the real posture needs
/// Docker, and the warning under test reads `containersEnabled` alone.
///
/// Profiles and authority acquisition are faked too so an `execution: container`
/// primary reaches the end of wiring instead of failing on the missing runtime.
class _ContainerCapableSecurityWiring extends SecurityWiring {
  new({required super.config, required super.dataDir, required super.eventBus, required super.exitFn});

  @override
  bool get containersEnabled => true;

  @override
  Set<String> get availableContainerProfiles => const {'workspace', 'restricted'};

  @override
  Future<ContainerAuthorityLease> acquireContainerAuthority(
    GatewayPrincipal principal, {
    Set<String> allowedMcpTools = const {},
    String? artifactsDir,
  }) async => FakeContainerAuthorityLease();
}

/// The posture warnings `HarnessWiring.wire()` emits, split out of
/// `harness_wiring_test.dart`: these assert only on log output, so they need
/// none of that file's execution-admission and ACP scaffolding.
void main() {
  late Directory tempDir;
  late DartclawConfig config;
  late EventBus eventBus;
  StorageWiring? storage;
  SecurityWiring? security;
  HarnessWiring? harnessWiring;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_harness_warnings_');
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
    await writeWorkspacePromptFiles(config.workspaceDir);
    eventBus = EventBus();
  });

  tearDown(() async {
    await harnessWiring?.executions.dispose();
    await security?.dispose();
    await storage?.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  HarnessFactory fakeFactory(Iterable<String> providerIds) {
    final factory = HarnessFactory();
    for (final providerId in providerIds) {
      factory.register(providerId, (_) => FakeAgentHarness(promptStrategy: PromptStrategy.append));
    }
    return factory;
  }

  Future<List<String>> wireAndCollectHarnessMessages(Iterable<String> providerIds) async {
    final records = <LogRecord>[];
    final subscription = Logger('HarnessWiring').onRecord.listen(records.add);
    try {
      storage = await wireTestStorage(config: config, eventBus: eventBus, exitFn: _unexpectedExit);
      security = await wireTestSecurity(
        config: config,
        dataDir: tempDir.path,
        eventBus: eventBus,
        exitFn: _unexpectedExit,
      );
      harnessWiring = await wireTestHarness(
        config: config,
        dataDir: tempDir.path,
        harnessFactory: fakeFactory(providerIds),
        exitFn: _unexpectedExit,
        storage: storage!,
        security: security!,
        eventBus: eventBus,
        harnessRegistrars: const [AcpHarnessRegistrar()],
        serverRefGetter: () => throw UnimplementedError('serverRefGetter should not be called'),
      );
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
      memory: journalEnabled ? MemoryConfig(journalEnabled: true) : config.memory,
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

  group('unhardened primary on channel ingress', () {
    const warningFragment = 'the primary agent runs on the host with every tool while a channel is enabled';

    void configureChannelDeployment({
      ExecutionMode? execution,
      List<String> disallowedTools = const [],
      Map<String, Map<String, dynamic>> channelConfigs = const {
        'signal': {'enabled': true},
      },
    }) {
      config = config.copyWith(
        agent: AgentConfig(provider: 'claude', execution: execution, disallowedTools: disallowedTools),
        channels: ChannelConfig(channelConfigs: channelConfigs),
      );
    }

    Future<List<String>> wireWithContainerCapableHost() async {
      final records = <LogRecord>[];
      final subscription = Logger('HarnessWiring').onRecord.listen(records.add);
      try {
        storage = await wireTestStorage(config: config, eventBus: eventBus, exitFn: _unexpectedExit);
        final capable = _ContainerCapableSecurityWiring(
          config: config,
          dataDir: tempDir.path,
          eventBus: eventBus,
          exitFn: _unexpectedExit,
        );
        await capable.wire(agentDefs: [AgentDefinition.searchAgent()]);
        security = capable;
        harnessWiring = await wireTestHarness(
          config: config,
          dataDir: tempDir.path,
          harnessFactory: fakeFactory(const ['claude']),
          exitFn: _unexpectedExit,
          storage: storage!,
          security: capable,
          eventBus: eventBus,
          serverRefGetter: () => throw UnimplementedError('serverRefGetter should not be called'),
        );
        return records.map((record) => record.message).toList();
      } finally {
        await subscription.cancel();
      }
    }

    test('warns for a host primary with no deny list while a channel is enabled', () async {
      configureChannelDeployment();

      final messages = await wireWithContainerCapableHost();

      final warning = messages.singleWhere((message) => message.contains(warningFragment));
      expect(warning, contains('agent.execution: container'));
      expect(warning, contains('agent.disallowed_tools'));
      expect(warning, contains('docs/guide/security.md § Hardening the primary agent for untrusted channels'));
    });

    test('stays silent when the primary already runs in a container', () async {
      configureChannelDeployment(execution: ExecutionMode.container);

      expect(await wireWithContainerCapableHost(), isNot(contains(contains(warningFragment))));
    });

    test('stays silent when a deny list withholds tools from the primary', () async {
      configureChannelDeployment(disallowedTools: const ['Bash']);

      expect(await wireWithContainerCapableHost(), isNot(contains(contains(warningFragment))));
    });

    test('stays silent when no channel is enabled', () async {
      configureChannelDeployment(
        channelConfigs: const {
          'signal': {'enabled': false},
        },
      );

      expect(await wireWithContainerCapableHost(), isNot(contains(contains(warningFragment))));
    });

    test('stays silent with container isolation off — the host-access warning owns that posture', () async {
      configureChannelDeployment();

      final messages = await wireAndCollectHarnessMessages(['claude']);

      expect(messages, isNot(contains(contains(warningFragment))));
    });
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
}
