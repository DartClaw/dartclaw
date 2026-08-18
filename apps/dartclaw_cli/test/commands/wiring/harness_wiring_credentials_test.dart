import 'dart:io';

import 'package:dartclaw_cli/src/commands/wiring/harness_wiring.dart';
import 'package:dartclaw_cli/src/commands/wiring/security_wiring.dart';
import 'package:dartclaw_cli/src/commands/wiring/storage_wiring.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide HarnessConfig;
import 'package:dartclaw_server/dartclaw_server.dart'
    show
        CredentialHealthMonitor,
        ExecutionAdmission,
        ExecutionRequest,
        ExecutionSurface,
        ProviderStatusService,
        WorkerCreationException;
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import '../../helpers/harness_wiring_fixture.dart';

Never _unexpectedExit(int code) => throw StateError('Unexpected exit($code) during harness wiring test');

const _storedSetupToken = 'sk-ant-oat01-STORED';

/// Which credential a deployment presents on the host boundary, and what a
/// deployment that can present none does at startup.
///
/// The container arm is mediated by the host gateway and holds no credential;
/// this is the other boundary — the real CLI, authenticating itself on whatever
/// the spawn environment carries.
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
    tempDir = Directory.systemTemp.createTempSync('dartclaw_harness_credentials_');
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

  HarnessFactory recordingFactory(Iterable<String> providerIds) {
    final factory = HarnessFactory();
    for (final providerId in providerIds) {
      factory.register(providerId, (factoryConfig) {
        recordedConfigs.add(factoryConfig);
        final harness = FakeAgentHarness(promptStrategy: PromptStrategy.append);
        createdHarnesses.add(harness);
        return harness;
      });
    }
    return factory;
  }

  Future<Map<String, String>> primarySpawnEnvironment({
    Map<String, CredentialEntry> Function()? subscriptions,
    Map<String, String>? environment,
  }) async {
    await wireStorageAndSecurity();
    harnessWiring = await wireTestHarness(
      config: config,
      dataDir: tempDir.path,
      harnessFactory: recordingFactory(const ['claude']),
      exitFn: _unexpectedExit,
      storage: storage!,
      security: security!,
      eventBus: eventBus,
      subscriptionCredentials: subscriptions,
      environment: environment,
      serverRefGetter: () => throw UnimplementedError('serverRefGetter should not be called'),
    );
    return recordedConfigs.first.environment;
  }

  /// Wires with [environment] and a recording exit, returning what startup
  /// logged and which exit codes it took.
  Future<({List<int> exits, List<String> logs})> wireExpectingStartupFailure({
    required Map<String, String> environment,
  }) async {
    final exits = <int>[];
    final logs = <String>[];
    final subscription = Logger.root.onRecord.listen((record) {
      logs.add('${record.message} ${record.error ?? ''}');
    });
    await wireStorageAndSecurity();
    final wiring = HarnessWiring(
      config: config,
      dataDir: tempDir.path,
      port: 3333,
      harnessFactory: recordingFactory(const ['claude', 'codex']),
      exitFn: (code) {
        exits.add(code);
        throw const _StartupExit();
      },
      storage: storage!,
      security: security!,
      messageRedactor: MessageRedactor(),
      eventBus: eventBus,
      environment: environment,
    );
    try {
      await wiring.wire(serverRefGetter: () => throw UnimplementedError('serverRefGetter should not be called'));
    } on _StartupExit {
      // The real exitFn never returns; the marker stands in for that.
    } finally {
      await subscription.cancel();
    }
    return (exits: exits, logs: logs);
  }

  Map<String, CredentialEntry> storedClaudeToken() => {
    'claude': CredentialEntry.subscription(token: _storedSetupToken),
  };

  test('a stored setup-token is what the primary Claude spawn authenticates on', () async {
    config = config.copyWith(credentials: const CredentialsConfig());

    final environment = await primarySpawnEnvironment(subscriptions: storedClaudeToken);

    expect(environment['CLAUDE_CODE_OAUTH_TOKEN'], _storedSetupToken);
    expect(
      environment['ANTHROPIC_API_KEY'],
      isNull,
      reason: 'exactly one credential is presented, so no API key is overlaid alongside it',
    );
    expect(
      environment['CLAUDE_CODE_SUBPROCESS_ENV_SCRUB'],
      '1',
      reason: 'host hardening is unchanged by the credential mode',
    );
  });

  test('an API-key deployment spawns exactly as it did before subscription mediation', () async {
    final environment = await primarySpawnEnvironment();

    expect(environment['ANTHROPIC_API_KEY'], 'anthropic-key');
    expect(environment['CLAUDE_CODE_OAUTH_TOKEN'], isNull);
  });

  test('auth: api_key presents the key even when a setup-token is stored', () async {
    config = config.copyWith(
      providers: ProvidersConfig(
        entries: {
          'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1, auth: ProviderAuth.apiKey),
        },
      ),
    );

    final environment = await primarySpawnEnvironment(subscriptions: storedClaudeToken);

    expect(environment['ANTHROPIC_API_KEY'], 'anthropic-key');
    expect(environment['CLAUDE_CODE_OAUTH_TOKEN'], isNull);
  });

  test('a forced provider auth survives the worker-entry rebuild', () async {
    config = config.copyWith(
      providers: ProvidersConfig(
        entries: {
          'claude': ProviderEntry(
            executable: Platform.resolvedExecutable,
            poolSize: 1,
            auth: ProviderAuth.subscription,
          ),
        },
      ),
    );

    // The forced selection is admission-gated, so it needs the credential it
    // forces before wiring gets as far as the entry rebuild.
    await primarySpawnEnvironment(subscriptions: storedClaudeToken);

    // The rebuild copies field-by-field, so a dropped field would silently
    // downgrade a forced selection to `auto` with the analyzer none the wiser.
    expect(harnessWiring!.providerStatusEntries['claude']!.auth, ProviderAuth.subscription);
  });

  test('a forced subscription selection with nothing stored fails startup with its remediation', () async {
    config = config.copyWith(
      agent: const AgentConfig(provider: 'codex'),
      providers: const ProvidersConfig(
        entries: {'codex': ProviderEntry(executable: 'codex', auth: ProviderAuth.subscription)},
      ),
      credentials: const CredentialsConfig(entries: {'openai': CredentialEntry(apiKey: 'openai-key')}),
    );

    final outcome = await wireExpectingStartupFailure(environment: const {'OPENAI_API_KEY': 'sk-openai-env'});

    expect(outcome.exits, [1]);
    expect(outcome.logs.where((line) => line.contains('auth: subscription')), isNotEmpty);
    expect(outcome.logs.where((line) => line.contains('codex login')), isNotEmpty);
    expect(outcome.logs.where((line) => line.contains('sk-openai-env')), isEmpty);
    expect(createdHarnesses, isEmpty);
  });

  test('an API-key-only deployment starts and presents the API key', () async {
    config = config.copyWith(credentials: const CredentialsConfig.defaults());

    final environment = await primarySpawnEnvironment(
      environment: const {'ANTHROPIC_API_KEY': 'sk-ant-env', 'PATH': '/usr/bin'},
    );

    expect(environment['ANTHROPIC_API_KEY'], 'sk-ant-env');
  });

  test('a selected subscription credential is presented alone, and the API key is not', () async {
    // A JWT-shaped token, so a leak into the spawn environment is caught in the
    // shape the Codex store really holds, not only the `sk-ant-*` one.
    const jwtToken = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJkYXJ0Y2xhdyJ9.c2lnbmF0dXJl';
    config = config.copyWith(
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, auth: ProviderAuth.subscription)},
      ),
      credentials: const CredentialsConfig.defaults(),
    );

    final environment = await primarySpawnEnvironment(
      subscriptions: () => {'claude': CredentialEntry.subscription(token: jwtToken)},
      environment: const {'ANTHROPIC_API_KEY': 'sk-ant-env', 'PATH': '/usr/bin'},
    );

    // Exactly one credential per authority: the API key must not ride along
    // with the subscription token.
    expect(environment.containsKey('ANTHROPIC_API_KEY'), isFalse);
    expect(environment['CLAUDE_CODE_OAUTH_TOKEN'], jwtToken);
  });

  /// Wires a deployment whose default provider holds a stored setup-token and
  /// whose *secondary* [aliasId] resolves to [family], optionally forcing an
  /// [auth] selection nothing in the deployment can satisfy.
  ///
  /// The host worker is the boundary the container gateway never sees: it backs
  /// every logical-agent session, task and schedule, and it spawns the real
  /// vendor CLI, which authenticates itself from the ambient login when the
  /// spawn environment carries nothing.
  Future<void> wireAliasDeployment({required String aliasId, required String family, ProviderAuth? auth}) async {
    config = config.copyWith(
      providers: ProvidersConfig(
        entries: {
          'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1),
          aliasId: ProviderEntry(
            executable: Platform.resolvedExecutable,
            poolSize: 1,
            auth: auth,
            options: {'family': family},
          ),
        },
      ),
      credentials: const CredentialsConfig.defaults(),
    );
    await wireStorageAndSecurity();
    harnessWiring = await wireTestHarness(
      config: config,
      dataDir: tempDir.path,
      harnessFactory: recordingFactory(['claude', aliasId]),
      exitFn: _unexpectedExit,
      storage: storage!,
      security: security!,
      eventBus: eventBus,
      subscriptionCredentials: storedClaudeToken,
      environment: const {'PATH': '/usr/bin'},
      serverRefGetter: () => throw UnimplementedError('serverRefGetter should not be called'),
    );
  }

  /// Asks the coordinator for a host worker on [aliasId], answering the refusal
  /// it raised or `null` when the worker was created.
  Future<Object?> acquireWorkerFailure(String aliasId) async {
    final createdBeforeAcquire = createdHarnesses.length;
    Object? failure;
    try {
      final lease = await harnessWiring!.executions.acquire(
        ExecutionRequest(
          surface: ExecutionSurface.task,
          providerId: aliasId,
          policy: const ExecutionPolicy.host(),
          sessionId: 'alias-session',
          admission: ExecutionAdmission.failFast,
        ),
      );
      addTearDown(() async => lease?.release());
      expect(lease?.runner?.providerId, aliasId);
    } catch (error) {
      failure = error;
      expect(
        createdHarnesses.length,
        createdBeforeAcquire,
        reason: 'a refused credential must not reach the harness factory',
      );
    }
    return failure;
  }

  test('a forced api_key with no key refuses the host worker instead of spawning on the ambient login', () async {
    // The exact `security.md` posture for a less-trusted host agent: `api_key`
    // chosen to keep the turn off the operator's full-account subscription.
    // Presenting nothing is not a refusal — the vendor CLI logs itself in.
    await wireAliasDeployment(aliasId: 'claude-alias', family: 'claude', auth: ProviderAuth.apiKey);

    expect(
      await acquireWorkerFailure('claude-alias'),
      isA<WorkerCreationException>().having(
        (error) => '$error',
        'message',
        allOf(contains('auth: api_key'), contains('ANTHROPIC_API_KEY'), contains('providers.claude-alias.auth')),
      ),
    );
  });

  test('the Codex host worker refuses the same way rather than spawning against ~/.codex', () async {
    await wireAliasDeployment(aliasId: 'codex-alias', family: 'codex', auth: ProviderAuth.apiKey);

    expect(
      await acquireWorkerFailure('codex-alias'),
      isA<WorkerCreationException>().having(
        (error) => '$error',
        'message',
        allOf(contains('auth: api_key'), contains('CODEX_API_KEY'), contains('providers.codex-alias.auth')),
      ),
    );
  });

  test('a host refusal announces credential health, which no gateway reaches on this boundary', () async {
    final events = <CredentialHealthChangedEvent>[];
    final subscription = eventBus.on<CredentialHealthChangedEvent>().listen(events.add);
    addTearDown(subscription.cancel);
    await wireAliasDeployment(aliasId: 'claude-alias', family: 'claude', auth: ProviderAuth.apiKey);
    // The real single writer over the ProviderStatusService the API reads, bound
    // the way `serve` binds it: several wiring steps after this class, and still
    // long before any worker is created.
    final providerStatus = ProviderStatusService(
      providers: config.providers,
      registry: CredentialRegistry(credentials: const CredentialsConfig()),
      defaultProvider: 'claude',
    );
    harnessWiring!.credentialHealth = CredentialHealthMonitor(
      eventBus: eventBus,
      providerStatus: providerStatus,
      resolveCredentials: () => const {},
    );

    expect(await acquireWorkerFailure('claude-alias'), isNotNull);
    await pumpEventQueue();

    expect(events, hasLength(1));
    expect(events.single.providerId, 'claude-alias');
    expect(events.single.state, CredentialHealthState.reauthRequired);
    expect(events.single.remediation, contains('ANTHROPIC_API_KEY'));
    // The provider card must move with the alert, or /settings keeps reporting
    // a provider that cannot run a single turn as healthy.
    final status = providerStatus.all.firstWhere((entry) => entry.id == 'claude-alias').toJson();
    expect(status['credentialHealth'], 'reauth-required');
  });

  test("a secondary provider on auth: auto still admits the vendor CLI's own login", () async {
    // The discriminating half: `noneConfigured` is not a forced selection, so
    // the pre-0.24.2 allowance survives and the worker is still created.
    await wireAliasDeployment(aliasId: 'claude-alias', family: 'claude');

    expect(await acquireWorkerFailure('claude-alias'), isNull);
  });

  test('the same deployment on auth: auto presents the API key instead', () async {
    // The discriminating half of the pair: only the resolution's mode decides
    // which credential is put back, so `auto` with nothing stored must still
    // present the key the forced-subscription case withheld.
    config = config.copyWith(
      providers: ProvidersConfig(entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable)}),
      credentials: const CredentialsConfig.defaults(),
    );

    final environment = await primarySpawnEnvironment(
      environment: const {'ANTHROPIC_API_KEY': 'sk-ant-env', 'PATH': '/usr/bin'},
    );

    expect(environment['ANTHROPIC_API_KEY'], 'sk-ant-env');
  });
}

/// Stands in for the process exit a real startup failure takes.
final class _StartupExit implements Exception {
  const new();
}
