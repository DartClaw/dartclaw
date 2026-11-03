import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show ExecutionAdmission, ExecutionRequest, ExecutionSurface;
import 'package:dartclaw_runtime/src/runtime/harness_wiring.dart';
import 'package:dartclaw_runtime/src/runtime/security_wiring.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'harness_wiring_fixture.dart';

Never _unexpectedExit(int code) => throw StateError('Unexpected exit($code) during harness wiring test');

/// Which gateway token the auth pipeline is wired with.
///
/// The resolved token is both the bearer credential and the HMAC key that signs
/// session cookies, so a blank one authenticates an empty `Bearer ` header and
/// lets anyone mint a cookie against an empty key. `gateway.token` reaching this
/// wiring blank means the configured `${VAR}` did not resolve — the generated
/// token file is the fail-closed answer, never the blank value.
void main() {
  late Directory tempDir;
  late EventBus eventBus;
  StorageWiring? storage;
  SecurityWiring? security;
  HarnessWiring? harnessWiring;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_gateway_token_');
    eventBus = EventBus();
  });

  tearDown(() async {
    await harnessWiring?.executions.dispose();
    await security?.dispose();
    await storage?.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  DartclawConfig configWith(GatewayConfig gateway) => DartclawConfig(
    server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
    agent: const AgentConfig(provider: 'claude'),
    providers: ProvidersConfig(
      entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1)},
    ),
    credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
    gateway: gateway,
  );

  Future<String?> resolveGatewayToken(GatewayConfig gateway) async {
    final config = configWith(gateway);
    await writeWorkspacePromptFiles(config.workspaceDir);
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
      storage: storage!,
      security: security!,
      eventBus: eventBus,
      serverRefGetter: () => throw UnimplementedError('serverRefGetter should not be called'),
    );
    return harnessWiring!.resolvedGatewayToken;
  }

  test('a blank configured token is replaced by a generated one', () async {
    final resolved = await resolveGatewayToken(const GatewayConfig(authMode: 'token', token: ''));

    expect(resolved, isNotNull);
    expect(resolved, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(File(p.join(tempDir.path, 'gateway_token')).readAsStringSync().trim(), resolved);
  });

  test('a whitespace-only configured token is replaced by a generated one', () async {
    final resolved = await resolveGatewayToken(const GatewayConfig(authMode: 'token', token: '   '));

    expect(resolved, matches(RegExp(r'^[0-9a-f]{64}$')));
  });

  test('a configured token is used as-is', () async {
    final resolved = await resolveGatewayToken(GatewayConfig(authMode: 'token', token: 'b' * 64));

    expect(resolved, 'b' * 64);
    expect(File(p.join(tempDir.path, 'gateway_token')).existsSync(), isFalse);
  });

  group('trusted turn context', () {
    late List<HarnessFactoryConfig> configs;
    late List<TurnContextHarness> harnesses;

    Future<void> wireWithRecordingFactory(GatewayConfig gateway) async {
      configs = [];
      harnesses = [];
      final config = configWith(gateway);
      await writeWorkspacePromptFiles(config.workspaceDir);
      storage = await wireTestStorage(config: config, eventBus: eventBus, exitFn: _unexpectedExit);
      security = await wireTestSecurity(
        config: config,
        dataDir: tempDir.path,
        eventBus: eventBus,
        exitFn: _unexpectedExit,
      );
      final factory = HarnessFactory()
        ..register('claude', (factoryConfig) {
          configs.add(factoryConfig);
          final harness = TurnContextHarness();
          harnesses.add(harness);
          return harness;
        });
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

    Future<void> acquireHostWorker() async {
      final lease = await harnessWiring!.executions.acquire(
        const ExecutionRequest(
          surface: ExecutionSurface.task,
          providerId: 'claude',
          policy: ExecutionPolicy.host(),
          sessionId: 'worker-session',
          admission: ExecutionAdmission.failFast,
        ),
      );
      await lease!.release();
    }

    TurnProvenance chatTurn(String sender) => TurnProvenance.channel(
      channelType: ChannelType.googlechat,
      recipientId: 'spaces/AAA',
      sessionKey: 'shared-session',
      senderId: sender,
    );

    test('the primary and a worker harness each present their own minted bearer, never the shared token', () async {
      await wireWithRecordingFactory(GatewayConfig(authMode: 'token', token: 'c' * 64));
      await acquireHostWorker();

      final bearers = [for (final config in configs) config.harnessConfig.mcpGatewayToken];

      expect(bearers, hasLength(2));
      expect(bearers, everyElement(isNotNull));
      expect(bearers.toSet(), hasLength(2));
      expect(bearers, everyElement(isNot('c' * 64)));
      expect(harnessWiring!.mcpBearers.resolve('c' * 64), isNull);
    });

    test('each bearer resolves the turn its own harness is executing, and none outside a turn', () async {
      await wireWithRecordingFactory(GatewayConfig(authMode: 'token', token: 'c' * 64));
      await acquireHostWorker();
      final primaryTurn = chatTurn('users/alice');
      final workerTurn = chatTurn('users/bob');
      final resolvers = [
        for (final config in configs) harnessWiring!.mcpBearers.resolve(config.harnessConfig.mcpGatewayToken!)!,
      ];

      expect([for (final resolve in resolvers) resolve()], [null, null]);
      harnesses[0].setTurnContext(
        HarnessTurnContext(
          sessionId: 'primary-session',
          turnId: 't1',
          source: 'channel',
          agentName: 'main',
          provenance: primaryTurn,
        ),
      );
      harnesses[1].setTurnContext(
        HarnessTurnContext(
          sessionId: 'worker-session',
          turnId: 't2',
          source: 'channel',
          agentName: 'main',
          provenance: workerTurn,
        ),
      );
      expect([for (final resolve in resolvers) resolve()], [primaryTurn, workerTurn]);

      harnesses[1].setTurnContext(null);
      expect([for (final resolve in resolvers) resolve()], [primaryTurn, null]);
    });

    test('a worker bearer stops resolving once its harness is disposed', () async {
      await wireWithRecordingFactory(GatewayConfig(authMode: 'token', token: 'c' * 64));
      await acquireHostWorker();
      final workerBearer = configs.last.harnessConfig.mcpGatewayToken!;
      expect(harnessWiring!.mcpBearers.resolve(workerBearer), isNotNull);

      await harnessWiring!.executions.dispose();

      expect(harnessWiring!.mcpBearers.resolve(workerBearer), isNull);
      expect(harnessWiring!.mcpBearers.resolve(configs.first.harnessConfig.mcpGatewayToken!), isNull);
    });

    test('with authentication disabled the host harnesses still present a minted bearer', () async {
      await wireWithRecordingFactory(const GatewayConfig(authMode: 'none'));

      expect(configs.single.harnessConfig.mcpGatewayToken, isNotNull);
      expect(harnessWiring!.resolvedGatewayToken, isNull);
    });
  });
}
