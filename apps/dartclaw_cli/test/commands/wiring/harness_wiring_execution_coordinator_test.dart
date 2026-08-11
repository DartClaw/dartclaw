import 'dart:io';

import 'package:dartclaw_cli/src/commands/wiring/harness_wiring.dart';
import 'package:dartclaw_cli/src/commands/wiring/security_wiring.dart';
import 'package:dartclaw_cli/src/commands/wiring/storage_wiring.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide HarnessConfig;
import 'package:dartclaw_server/dartclaw_server.dart'
    show ExecutionAdmission, ExecutionRequest, ExecutionSurface, TurnRunnerCancellation, WorkerCreationException;
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

import '../../helpers/harness_wiring_fixture.dart';

Never _unexpectedExit(int code) {
  throw StateError('Unexpected exit($code) during harness wiring test');
}

final class _FailingWorkerHarness extends FakeAgentHarness {
  _FailingWorkerHarness() : super(promptStrategy: PromptStrategy.append);

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

Future<T> _pollFor<T>(T Function() read, bool Function(T) isReady) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  var value = read();
  while (!isReady(value) && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    value = read();
  }
  return value;
}

final class _HarnessWiringFixture {
  _HarnessWiringFixture() {
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

    writeWorkspacePromptFiles(config.workspaceDir);
  }

  late final Directory tempDir;
  late DartclawConfig config;
  final eventBus = EventBus();
  final createdHarnesses = <FakeAgentHarness>[];
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

  HarnessFactory fakeFactory(Iterable<String> providerIds) {
    final factory = HarnessFactory();
    for (final providerId in providerIds) {
      factory.register(providerId, (_) {
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

  setUp(() => fixture = _HarnessWiringFixture());
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

    expect(claudeLease!.runner!.providerId, 'claude');
    expect(codexLease!.runner!.providerId, 'codex');
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
    expect(claudeLease!.runner!.providerId, 'claude');
    expect(codexLease!.runner!.providerId, 'codex');
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

  test('wired runners use configured turn monitor thresholds and worker timeout', () async {
    fixture.config = fixture.config.copyWith(
      server: ServerConfig(
        dataDir: fixture.tempDir.path,
        claudeExecutable: Platform.resolvedExecutable,
        workerTimeout: 3,
      ),
      harness: const HarnessConfig(
        turnMonitor: TurnMonitorConfig(
          waitWarningAfter: Duration(milliseconds: 10),
          stuckAfter: Duration(milliseconds: 25),
        ),
      ),
    );

    await fixture.wireStorageAndSecurity();
    await fixture.wireHarness(fixture.fakeFactory(['claude']));

    final executions = fixture.harnessWiring!.executions;
    final serializationLease = await executions.acquire(
      fixture.executionRequest(
        providerId: 'claude',
        sessionId: 'primary-serialization',
        surface: ExecutionSurface.interactive,
      ),
    );
    expect(executions.snapshot.primaryActive, isTrue);
    expect(
      await executions.acquire(
        fixture.executionRequest(
          providerId: 'claude',
          sessionId: 'blocked-primary',
          surface: ExecutionSurface.interactive,
          admission: ExecutionAdmission.failFast,
        ),
      ),
      isNull,
    );
    await serializationLease!.release();

    final primarySession = await fixture.storage!.sessions.createSession();
    final primaryLease = await executions.acquire(
      fixture.executionRequest(
        providerId: 'claude',
        sessionId: primarySession.id,
        surface: ExecutionSurface.interactive,
      ),
    );
    final primaryExecution = primaryLease!;
    final primaryRunner = primaryExecution.runner!;
    final primaryTurnId = await primaryRunner.reserveAdmittedTurn(primarySession.id);
    final primaryOutcome = primaryRunner.waitForOutcome(primarySession.id, primaryTurnId);
    primaryRunner.executeTurn(primarySession.id, primaryTurnId, const [
      {'role': 'user', 'content': 'wait on primary'},
    ]);
    final primaryHarness = primaryRunner.harness as FakeAgentHarness;
    await primaryHarness.turnInvoked;
    final queuedPrimaryLease = executions.acquire(
      fixture.executionRequest(
        providerId: 'claude',
        sessionId: primarySession.id,
        surface: ExecutionSurface.interactive,
      ),
    );
    addTearDown(() async {
      if (primaryHarness.hasPendingTurn) primaryHarness.completeSuccess();
      await primaryOutcome;
      await primaryExecution.release();
      await (await queuedPrimaryLease)?.release();
    });

    final primaryStatus = await _pollFor(
      () => primaryRunner.turnStatus(primarySession.id),
      (status) => status.state.name == 'stuck',
    );
    expect(primaryStatus.state.name, 'stuck');
    expect(primaryStatus.globalTimeoutAt, isNotNull);

    primaryHarness.completeSuccess();
    await primaryOutcome;
    await primaryExecution.release();
    final admittedPrimaryLease = await queuedPrimaryLease.timeout(const Duration(seconds: 1));
    await admittedPrimaryLease!.release();

    final taskSession = await fixture.storage!.sessions.createSession();
    final taskLease = await executions.acquire(
      fixture.executionRequest(providerId: 'claude', sessionId: taskSession.id),
    );
    final taskExecution = taskLease!;
    final taskRunner = taskExecution.runner!;
    final taskTurnId = await taskRunner.reserveAdmittedTurn(taskSession.id);
    final taskOutcome = taskRunner.waitForOutcome(taskSession.id, taskTurnId);
    taskRunner.executeTurn(taskSession.id, taskTurnId, const [
      {'role': 'user', 'content': 'wait on worker'},
    ]);
    final taskHarness = taskRunner.harness as FakeAgentHarness;
    await taskHarness.turnInvoked;
    final queuedTaskLease = executions.acquire(
      fixture.executionRequest(providerId: 'claude', sessionId: taskSession.id),
    );
    addTearDown(() async {
      if (taskHarness.hasPendingTurn) taskHarness.completeSuccess();
      await taskOutcome;
      await taskExecution.release();
      await (await queuedTaskLease)?.release();
    });

    final taskStatus = await _pollFor(
      () => taskRunner.turnStatus(taskSession.id),
      (status) => status.state.name == 'stuck',
    );
    expect(taskStatus.state.name, 'stuck');
    expect(taskStatus.globalTimeoutAt, isNotNull);

    taskHarness.completeSuccess();
    await taskOutcome;
    await taskExecution.release();
    final admittedTaskLease = await queuedTaskLease.timeout(const Duration(seconds: 1));
    await admittedTaskLease!.release();
  });
}
