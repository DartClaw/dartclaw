import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
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
}
