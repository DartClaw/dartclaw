import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness, openPreparedTaskBackend;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'harness_wiring_fixture.dart';

Never _unexpectedExit(int code) => throw StateError('Unexpected exit($code)');

final class _ExitCalled implements Exception {
  const new(this.code);

  final int code;
}

Never _exitWithCode(int code) => throw _ExitCalled(code);

const _absentRuntime = 'dartclaw-absent-runtime';

/// A default install with only the vendor CLI login: no stored credential and
/// no API key in the injected environment. The runtime named by the resolved
/// posture is absent on every host, so a composition that reaches the runtime
/// refusal got past the credential check, and one that reports the credential
/// stopped at it.
void main() {
  late Directory tempDir;
  late List<LogRecord> records;
  late StreamSubscription<LogRecord> logSubscription;
  late String loggedInClaude;
  late Map<String, String> environment;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('inferred_posture_credential_');
    records = <LogRecord>[];
    Logger.root.level = Level.ALL;
    logSubscription = Logger.root.onRecord.listen(records.add);
    // Absolute path: a bare name would resolve on the test process's PATH.
    loggedInClaude = p.join(tempDir.path, 'claude');
    File(loggedInClaude).writeAsStringSync('''#!/bin/sh
case "\$1" in
  --version) echo "2.1.0 (Claude Code)" ;;
  auth) echo '{"loggedIn":true}' ;;
esac
''');
    Process.runSync('chmod', ['+x', loggedInClaude]);
    final home = Directory(p.join(tempDir.path, 'home'))..createSync();
    environment = {'HOME': home.path, 'PATH': Platform.environment['PATH'] ?? ''};
  });

  tearDown(() async {
    await logSubscription.cancel();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  DartclawConfig configFor(ContainerConfig container) => DartclawConfig(
    container: container,
    server: ServerConfig(dataDir: p.join(tempDir.path, 'data'), claudeExecutable: loggedInClaude),
    agent: const AgentConfig(provider: 'claude'),
    providers: ProvidersConfig(entries: {'claude': ProviderEntry(executable: loggedInClaude, poolSize: 0)}),
    gateway: const GatewayConfig(authMode: 'none'),
    security: const SecurityConfig(contentGuardEnabled: false),
  );

  test('an inferred posture with only the CLI login composes and admits the primary on the host lane', () async {
    final config = configFor(const ContainerConfig().resolved(enabled: true, runtimeBinary: _absentRuntime));
    final configFile = File(p.join(tempDir.path, 'dartclaw.yaml'))..writeAsStringSync('# test config\n');

    final runtime = await DartclawRuntime.build(
      config,
      dataDir: config.server.dataDir,
      port: 3000,
      runtimeCwd: tempDir.path,
      harnessFactory: HarnessFactory()..register('claude', (_) => FakeAgentHarness()),
      taskBackendFactory: (_) async => openPreparedTaskBackend(),
      taskBackendIsPrepared: true,
      stderrLine: (_) {},
      exitFn: _unexpectedExit,
      resolvedConfigPath: configFile.path,
      messageRedactor: MessageRedactor(),
      resolvedAssets: const ResolvedAssets.embedded(),
      runWorkflowSkillsBootstrap: false,
      environment: environment,
    );
    addTearDown(runtime.shutdown);

    expect(runtime.containerIsolationActive, isFalse);
    final advisory = records.singleWhere(
      (record) => record.level == Level.WARNING && record.message.contains('Container isolation disabled'),
    );
    expect(
      advisory.message,
      allOf(contains('provider claude has no credential a container can use'), isNot(contains(_absentRuntime))),
    );
    expect(
      records.map((record) => record.message),
      contains("Provider 'claude': using binary's own authentication"),
      reason: 'the primary was admitted on the host lane through the CLI login',
    );
  });

  test(
    'an explicit request with containers wired still refuses the container primary, naming the credential',
    () async {
      final config = configFor(const ContainerConfig(enabled: true));
      // The subclass stands in for wired containers, so the real runtime probe
      // (which cannot pass without Docker) is skipped by wiring it disabled.
      final securityConfig = configFor(const ContainerConfig.disabled());
      final eventBus = EventBus();
      final storage = await wireTestStorage(config: config, eventBus: eventBus, exitFn: _unexpectedExit);
      addTearDown(() async {
        await storage.dispose();
        await eventBus.dispose();
      });
      final security = ContainerCapableSecurityWiring(
        config: securityConfig,
        dataDir: tempDir.path,
        runtimeCwd: tempDir.path,
        eventBus: eventBus,
        exitFn: _unexpectedExit,
        auditLogger: GuardAuditLogger(dataDir: tempDir.path),
      );
      await security.wire(agentDefs: [AgentDefinition.searchAgent()]);
      addTearDown(security.dispose);

      // HarnessWiring logs a primary-start failure and exits rather than
      // rethrowing, so the refusal is the severe record and the exit code.
      await expectLater(
        wireTestHarness(
          config: config,
          dataDir: tempDir.path,
          harnessFactory: HarnessFactory()..register('claude', (_) => FakeAgentHarness()),
          exitFn: _exitWithCode,
          storage: storage,
          security: security,
          eventBus: eventBus,
          environment: environment,
          serverRefGetter: () => throw UnimplementedError('serverRefGetter should not be called'),
        ),
        throwsA(isA<_ExitCalled>().having((exit) => exit.code, 'code', 1)),
      );

      final refusal = records.singleWhere((record) => record.message == 'Failed to start harness').error;
      expect(
        refusal,
        isA<StateError>().having(
          (error) => error.message,
          'message',
          allOf(contains('claude setup-token'), contains('dartclaw auth claude')),
        ),
      );
    },
  );
}
