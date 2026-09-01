@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';

import 'package:dartclaw_runtime/src/runtime/harness_wiring.dart';
import 'package:dartclaw_runtime/src/runtime/security_wiring.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart'
    show ExecutionAdmission, ExecutionRequest, ExecutionSurface, WorkerCreationException;
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

import 'harness_wiring_fixture.dart';

Never _unexpectedExit(int code) {
  throw StateError('Unexpected exit($code) during harness wiring test');
}

final class _TurnTimerFakeTime {
  static final _initialTime = DateTime(2026);
  final _async = FakeAsync(initialTime: _initialTime);

  DateTime now() => _async.getClock(_initialTime).now();

  Timer create(Duration duration, void Function() callback) => _async.run((_) => Timer(duration, callback));

  Future<void> elapse(Duration duration) async {
    await pumpEventQueue();
    _async.elapse(duration);
    await pumpEventQueue();
  }
}

final class _FailingWorkerHarness extends FakeAgentHarness {
  new() : super(promptStrategy: PromptStrategy.append);

  @override
  Future<void> start() async {
    startCalled = true;
    throw StateError('worker factory start failed');
  }

  @override
  Future<void> stop() async {
    stopCalled = true;
    throw StateError('worker stop failed');
  }
}

final class _HarnessWiringFixture {
  new _();

  static Future<_HarnessWiringFixture> create() async {
    final fixture = _HarnessWiringFixture._();
    await fixture._prepare();
    return fixture;
  }

  Future<void> _prepare() async {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_harness_wiring_execution_');
    config = DartclawConfig(
      server: ServerConfig(dataDir: tempDir.path, claudeExecutable: Platform.resolvedExecutable),
      agent: const AgentConfig(provider: 'claude'),
      providers: ProvidersConfig(
        entries: {'claude': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1)},
      ),
      credentials: const CredentialsConfig(entries: {'anthropic': CredentialEntry(apiKey: 'anthropic-key')}),
      gateway: const GatewayConfig(authMode: 'none'),
    );

    await writeWorkspacePromptFiles(config.workspaceDir);
  }

  late final Directory tempDir;
  late DartclawConfig config;
  final eventBus = EventBus();
  final createdHarnesses = <FakeAgentHarness>[];
  final factoryConfigs = <HarnessFactoryConfig>[];
  StorageWiring? storage;
  SecurityWiring? security;
  HarnessWiring? harnessWiring;

  Future<void> dispose() async {
    await harnessWiring?.executions.dispose();
    await security?.dispose();
    await storage?.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  }

  Future<void> wireStorageAndSecurity() async {
    storage = await wireTestStorage(config: config, eventBus: eventBus, exitFn: _unexpectedExit);
    security = await wireTestSecurity(
      config: config,
      dataDir: tempDir.path,
      eventBus: eventBus,
      exitFn: _unexpectedExit,
    );
  }

  Future<void> wireHarness(HarnessFactory factory, {_TurnTimerFakeTime? time}) async {
    harnessWiring = await wireTestHarness(
      config: config,
      dataDir: tempDir.path,
      harnessFactory: factory,
      exitFn: _unexpectedExit,
      storage: storage!,
      security: security!,
      eventBus: eventBus,
      serverRefGetter: () => throw UnimplementedError('serverRefGetter should not be called'),
      turnTimerFactory: time?.create,
      turnNow: time?.now,
    );
  }

  HarnessFactory fakeFactory(Iterable<String> providerIds) {
    final factory = HarnessFactory();
    for (final providerId in providerIds) {
      factory.register(providerId, (config) {
        factoryConfigs.add(config);
        final harness = FakeAgentHarness(promptStrategy: PromptStrategy.append);
        createdHarnesses.add(harness);
        return harness;
      });
    }
    return factory;
  }

  ExecutionRequest executionRequest({
    required String providerId,
    required String sessionId,
    ExecutionSurface surface = ExecutionSurface.task,
    ExecutionAdmission admission = ExecutionAdmission.wait,
  }) => ExecutionRequest(
    surface: surface,
    providerId: providerId,
    policy: const ExecutionPolicy.host(),
    sessionId: sessionId,
    admission: admission,
  );
}

void main() {
  late _HarnessWiringFixture fixture;

  setUp(() async => fixture = await _HarnessWiringFixture.create());
  tearDown(() => fixture.dispose());

  test('configured providers use effective pool_size with independent capacity', () async {
    fixture.config = fixture.config.copyWith(
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
    );

    await fixture.wireStorageAndSecurity();
    await fixture.wireHarness(fixture.fakeFactory(['claude', 'codex']));

    final executions = fixture.harnessWiring!.executions;
    expect(executions.snapshot.configuredWorkers, 2);

    final claudeLease = await executions.acquire(fixture.executionRequest(providerId: 'claude', sessionId: 'claude-1'));
    final codexLease = await executions.acquire(fixture.executionRequest(providerId: 'codex', sessionId: 'codex-1'));
    addTearDown(() async {
      await claudeLease?.release();
      await codexLease?.release();
    });

    expect(claudeLease!.runner.providerId, 'claude');
    expect(codexLease!.runner.providerId, 'codex');
    expect(executions.snapshot.activeWorkers, 2);
    expect(
      await executions.acquire(
        fixture.executionRequest(providerId: 'claude', sessionId: 'claude-2', admission: ExecutionAdmission.failFast),
      ),
      isNull,
    );
    expect(
      await executions.acquire(
        fixture.executionRequest(providerId: 'codex', sessionId: 'codex-2', admission: ExecutionAdmission.failFast),
      ),
      isNull,
    );
  });

  test('non-empty provider config missing default still reserves default capacity', () async {
    fixture.config = fixture.config.copyWith(
      providers: ProvidersConfig(
        entries: {'codex': ProviderEntry(executable: Platform.resolvedExecutable, poolSize: 1)},
      ),
      credentials: const CredentialsConfig(
        entries: {
          'anthropic': CredentialEntry(apiKey: 'anthropic-key'),
          'openai': CredentialEntry(apiKey: 'openai-key'),
        },
      ),
    );

    await fixture.wireStorageAndSecurity();
    await fixture.wireHarness(fixture.fakeFactory(['claude', 'codex']));

    final executions = fixture.harnessWiring!.executions;
    expect(executions.snapshot.configuredWorkers, 2);
    final claudeLease = await executions.acquire(
      fixture.executionRequest(providerId: 'claude', sessionId: 'claude-task'),
    );
    final codexLease = await executions.acquire(fixture.executionRequest(providerId: 'codex', sessionId: 'codex-task'));
    addTearDown(() async {
      await claudeLease?.release();
      await codexLease?.release();
    });
    expect(claudeLease!.runner.providerId, 'claude');
    expect(codexLease!.runner.providerId, 'codex');
  });

  test('worker startup failure disposes after stop failure and surfaces the factory error', () async {
    await fixture.wireStorageAndSecurity();
    final failedWorker = _FailingWorkerHarness();
    var creationCount = 0;
    final factory = HarnessFactory()
      ..register('claude', (_) {
        creationCount++;
        return creationCount == 1 ? FakeAgentHarness(promptStrategy: PromptStrategy.append) : failedWorker;
      });
    await fixture.wireHarness(factory);

    await expectLater(
      fixture.harnessWiring!.executions.acquire(
        fixture.executionRequest(providerId: 'claude', sessionId: 'failed-worker'),
      ),
      throwsA(
        isA<WorkerCreationException>().having(
          (error) => error.message,
          'message',
          contains('worker factory start failed'),
        ),
      ),
    );

    expect(failedWorker.stopCalled, isTrue);
    expect(failedWorker.disposeCalled, isTrue);
    expect(fixture.harnessWiring!.executions.snapshot.activeWorkers, 0);
    expect(fixture.harnessWiring!.executions.snapshot.availableWorkers, 1);
  });

  test('both lanes receive configured budgets and the harness gets the derived backstop', () async {
    final time = _TurnTimerFakeTime();
    const limits = TurnLimitsConfig(
      stallTimeout: Duration(milliseconds: 20),
      stallAction: TurnProgressAction.cancel,
      turnTimeout: Duration(milliseconds: 100),
    );
    fixture.config = fixture.config.copyWith(governance: const GovernanceConfig(turnLimits: limits));

    await fixture.wireStorageAndSecurity();
    await fixture.wireHarness(fixture.fakeFactory(['claude']), time: time);

    final executions = fixture.harnessWiring!.executions;
    expect(executions.primary!.turnLimits, limits);
    expect(fixture.factoryConfigs.single.turnTimeout, const Duration(seconds: 60, milliseconds: 100));

    final chatSession = await fixture.storage!.sessions.createSession();
    final chatRunner = executions.primary!;
    final chatTurnId = await chatRunner.startTurn(chatSession.id, const [
      {'role': 'user', 'content': 'stay silent'},
    ]);
    await fixture.createdHarnesses.single.turnInvoked;
    await time.elapse(const Duration(milliseconds: 20));
    final chatOutcome = await chatRunner.waitForOutcome(chatSession.id, chatTurnId);
    expect(chatOutcome.status, TurnStatus.cancelled);
    expect(chatOutcome.limitBreach, TurnLimitBreach.stall);
    await chatRunner.waitForExecutionSettled(chatSession.id, chatTurnId);

    final workflowSession = await fixture.storage!.sessions.createSession();
    final lease = (await executions.acquire(
      fixture.executionRequest(providerId: 'claude', sessionId: workflowSession.id, surface: ExecutionSurface.workflow),
    ))!;
    addTearDown(lease.release);
    expect(lease.runner.turnLimits, limits);
    expect(fixture.factoryConfigs, hasLength(2));
    expect(
      fixture.factoryConfigs.map((config) => config.turnTimeout),
      everyElement(const Duration(seconds: 60, milliseconds: 100)),
    );

    final workflowRunner = lease.runner;
    final workflowTurnId = await workflowRunner.reserveAdmittedTurn(workflowSession.id);
    final workflowOutcomeFuture = workflowRunner.waitForOutcome(workflowSession.id, workflowTurnId);
    workflowRunner.executeTurn(workflowSession.id, workflowTurnId, const [
      {'role': 'user', 'content': 'keep streaming past the wall clock'},
    ]);
    final workflowHarness = fixture.createdHarnesses.last;
    await workflowHarness.turnInvoked;
    for (var elapsed = 0; elapsed < 90; elapsed += 15) {
      await time.elapse(const Duration(milliseconds: 15));
      workflowHarness.emit(ProviderProgressBridgeEvent(kind: 'provider_turn', text: 'still working'));
    }
    await time.elapse(const Duration(milliseconds: 10));
    final workflowOutcome = await workflowOutcomeFuture;
    expect(workflowOutcome.status, TurnStatus.cancelled);
    expect(workflowOutcome.limitBreach, TurnLimitBreach.turnTimeout);
    await workflowRunner.waitForExecutionSettled(workflowSession.id, workflowTurnId);
  });

  test('disabled wall clock reaches the harness factory as unbounded', () async {
    fixture.config = fixture.config.copyWith(
      governance: const GovernanceConfig(
        turnLimits: TurnLimitsConfig(stallTimeout: Duration.zero, turnTimeout: Duration.zero),
      ),
    );

    await fixture.wireStorageAndSecurity();
    await fixture.wireHarness(fixture.fakeFactory(['claude']));

    expect(fixture.factoryConfigs.single.turnTimeout, Duration.zero);
  });
}
