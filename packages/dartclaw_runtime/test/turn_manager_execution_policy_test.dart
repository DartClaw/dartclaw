import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show MessageService;
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'execution_coordinator_test_support.dart';
import 'turn_manager_test_support.dart';
import 'turn_runner_test_support.dart';

/// Session routing across reconstruction.
///
/// Covers Acceptance Scenario S03 (mixed same-provider boundaries) and the
/// pre-upgrade backfill rule: a session pinned before execution mode existed
/// derives its mode once and persists it forward, and a container-only pinned
/// profile this deployment cannot run fails closed at resume.
void main() {
  late InMemorySessionService sessions;

  setUp(() => sessions = InMemorySessionService());

  ExecutionPolicyResolver resolverFor({required bool containersEnabled}) => ExecutionPolicyResolver(
    config: DartclawConfig.defaults().copyWith(container: ContainerConfig(enabled: containersEnabled)),
    availableContainerProfiles: containersEnabled ? const {'workspace', 'restricted'} : const {},
  );

  /// Reserves a turn to exercise policy resolution, then rolls the reservation
  /// back. The reservation's outcome future must be consumed: rollback
  /// completes it with an error by design.
  Future<void> reserveAndRollBack(TurnManager turns, String sessionId) async {
    final turnId = await turns.reserveTurn(sessionId);
    final outcome = turns.waitForOutcome(sessionId, turnId);
    turns.releaseTurn(sessionId, turnId);
    await expectLater(outcome, throwsStateError);
  }

  TurnManager turnsFor({
    required List<TurnRunner> runners,
    required bool containersEnabled,
    Map<String, int>? providerCapacities,
  }) => TurnManager.fromCoordinator(
    turnLimits: const TurnLimitsConfig.defaults(),
    coordinator: coordinatorForRunners(runners, providerCapacities: providerCapacities),
    sessions: sessions,
    policyResolver: resolverFor(containersEnabled: containersEnabled),
  );

  group('the single-harness composition reports where its harness runs', () {
    late Directory tempDir;

    setUp(() => tempDir = Directory.systemTemp.createTempSync('dartclaw_single_harness_policy_test_'));
    tearDown(() => tempDir.deleteSync(recursive: true));

    TurnManager singleHarnessTurns({ExecutionPolicy? executionPolicy}) => TurnManager(
      turnLimits: const TurnLimitsConfig.defaults(),
      messages: MessageService(baseDir: tempDir.path),
      worker: FakeWorkerService(),
      behavior: BehaviorFileService(workspaceDir: p.join(tempDir.path, 'workspace')),
      executionPolicy: executionPolicy ?? const ExecutionPolicy.host(),
    );

    test('a container-backed harness is not reported as running on the host', () {
      // The policy is the runner's reported placement, its reuse identity, and
      // the never-cache-container predicate — omitting it mislabels all three.
      final turns = singleHarnessTurns(executionPolicy: const ExecutionPolicy.container('restricted'));
      addTearDown(turns.executions.dispose);

      expect(turns.executions.primary!.executionPolicy, const ExecutionPolicy.container('restricted'));
    });

    test('an undeclared policy stays host, the placement an SDK host composes by default', () {
      final turns = singleHarnessTurns();
      addTearDown(turns.executions.dispose);

      expect(turns.executions.primary!.executionPolicy, const ExecutionPolicy.host());
    });
  });

  test('a session pinned without an execution mode derives container mode and persists it forward', () async {
    final session = await sessions.createSession(type: SessionType.logicalAgent, securityProfile: 'restricted');
    final turns = turnsFor(
      runners: [
        FakeTurnRunner(),
        FakeTurnRunner(executionPolicy: const ExecutionPolicy.container('restricted')),
      ],
      containersEnabled: true,
    );
    addTearDown(turns.executions.dispose);

    await reserveAndRollBack(turns, session.id);

    expect((await sessions.getSession(session.id))!.executionMode, ExecutionMode.container);
  });

  test('a pre-upgrade workspace pin without containers derives host — its real prior behavior', () async {
    final session = await sessions.createSession(type: SessionType.logicalAgent, securityProfile: 'workspace');
    final turns = turnsFor(runners: [FakeTurnRunner(), FakeTurnRunner()], containersEnabled: false);
    addTearDown(turns.executions.dispose);

    await reserveAndRollBack(turns, session.id);

    expect((await sessions.getSession(session.id))!.executionMode, ExecutionMode.host);
  });

  test('a pre-upgrade restricted pin without containers fails closed at resume', () async {
    final session = await sessions.createSession(type: SessionType.logicalAgent, securityProfile: 'restricted');
    final turns = turnsFor(runners: [FakeTurnRunner(), FakeTurnRunner()], containersEnabled: false);
    addTearDown(turns.executions.dispose);

    await expectLater(
      turns.reserveTurn(session.id),
      throwsA(
        isA<ExecutionPolicyException>().having(
          (error) => error.message,
          'message',
          allOf(contains(session.id), contains('restricted')),
        ),
      ),
    );
    expect(
      (await sessions.getSession(session.id))!.executionMode,
      isNull,
      reason: 'a rejected resume must not persist a weakened mode',
    );
  });

  test('a persisted mode is replayed verbatim rather than re-derived', () async {
    final session = await sessions.createSession(
      type: SessionType.logicalAgent,
      securityProfile: 'restricted',
      executionMode: ExecutionMode.container,
    );
    final containerRunner = FakeTurnRunner(executionPolicy: const ExecutionPolicy.container('restricted'));
    final turns = turnsFor(runners: [FakeTurnRunner(), containerRunner], containersEnabled: true);
    addTearDown(turns.executions.dispose);

    await reserveAndRollBack(turns, session.id);

    expect((await sessions.getSession(session.id))!.executionMode, ExecutionMode.container);
    expect(containerRunner.executionPolicy, const ExecutionPolicy.container('restricted'));
  });

  test('S03 two sessions on one provider keep separate boundaries', () async {
    final hostSession = await sessions.createSession(type: SessionType.logicalAgent, executionMode: ExecutionMode.host);
    final containerSession = await sessions.createSession(
      type: SessionType.logicalAgent,
      securityProfile: 'restricted',
      executionMode: ExecutionMode.container,
    );
    final hostRunner = FakeTurnRunner();
    final containerRunner = FakeTurnRunner(executionPolicy: const ExecutionPolicy.container('restricted'));
    final turns = turnsFor(
      runners: [FakeTurnRunner(), hostRunner, containerRunner],
      containersEnabled: true,
      providerCapacities: const {'claude': 2},
    );
    addTearDown(turns.executions.dispose);

    final hostTurn = await turns.reserveTurn(hostSession.id);
    final containerTurn = await turns.reserveTurn(containerSession.id);
    final hostOutcome = turns.waitForOutcome(hostSession.id, hostTurn);
    final containerOutcome = turns.waitForOutcome(containerSession.id, containerTurn);

    expect(turns.executions.runners, containsAll([hostRunner, containerRunner]));
    expect(hostRunner.executionPolicy, const ExecutionPolicy.host());
    expect(containerRunner.executionPolicy, const ExecutionPolicy.container('restricted'));

    turns.releaseTurn(hostSession.id, hostTurn);
    turns.releaseTurn(containerSession.id, containerTurn);
    await expectLater(hostOutcome, throwsStateError);
    await expectLater(containerOutcome, throwsStateError);
  });
}
