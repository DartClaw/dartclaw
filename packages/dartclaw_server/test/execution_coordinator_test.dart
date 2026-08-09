import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnRunner;
import 'package:dartclaw_server/src/behavior/behavior_file_service.dart';
import 'package:dartclaw_server/src/execution_coordinator.dart';
import 'package:dartclaw_server/src/turn_runner.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness;
import 'package:test/test.dart';

void main() {
  group('ExecutionCoordinator', () {
    test('rejects admission callbacks unless both ownership operations are configured', () {
      TurnRunner createRunner(ExecutionRequest request) =>
          _runner(_TestHarness(), providerId: request.providerId, profileId: request.profileId);

      expect(
        () => ExecutionCoordinator(
          providerCapacities: const {'claude': 1},
          createWorker: (request) async => createRunner(request),
          admitExecution: (_) async {},
        ),
        throwsArgumentError,
      );
      expect(
        () => ExecutionCoordinator(
          providerCapacities: const {'claude': 1},
          createWorker: (request) async => createRunner(request),
          releaseAdmission: (_) {},
        ),
        throwsArgumentError,
      );
    });

    test('reuses exact-session worker before a fingerprint-only match', () async {
      final fixture = _CoordinatorFixture(capacities: const {'claude': 2});
      addTearDown(fixture.dispose);

      final first = await fixture.acquire(sessionId: 'session-a');
      final second = await fixture.acquire(sessionId: 'session-b');
      final firstRunner = first.runner;
      final secondRunner = second.runner;
      await first.release();
      await second.release();

      final reacquired = await fixture.acquire(sessionId: 'session-b');

      expect(reacquired.runner, same(secondRunner));
      expect(reacquired.runner, isNot(same(firstRunner)));
      expect(fixture.created, hasLength(2));
      await reacquired.release();
    });

    test('never reuses across provider, profile, or configuration fingerprints', () async {
      final fixture = _CoordinatorFixture(
        capacities: const {'claude': 2, 'codex': 1},
        resolveFingerprint: (providerId, profileId) => ExecutionFingerprint(
          providerId: providerId,
          profileId: profileId,
          configurationId: '$providerId-$profileId-config',
        ),
      );
      addTearDown(fixture.dispose);

      final workspace = await fixture.acquire(sessionId: 'shared', providerId: 'claude', profileId: 'workspace');
      final workspaceRunner = workspace.runner;
      await workspace.release();

      final restricted = await fixture.acquire(sessionId: 'shared', providerId: 'claude', profileId: 'restricted');
      final codex = await fixture.acquire(sessionId: 'shared', providerId: 'codex', profileId: 'workspace');

      expect(restricted.runner, isNot(same(workspaceRunner)));
      expect(codex.runner, isNot(same(workspaceRunner)));
      expect(restricted.runner!.profileId, 'restricted');
      expect(codex.runner!.providerId, 'codex');
      await restricted.release();
      await codex.release();
    });

    test('capacity-only lease admits work without creating a worker', () async {
      final fixture = _CoordinatorFixture(capacities: const {'claude': 1});
      addTearDown(fixture.dispose);

      final lease = await fixture.acquire(sessionId: 'job', surface: ExecutionSurface.workflow);

      expect(lease.runner, isNull);
      expect(lease.runnerId, isNull);
      expect(fixture.created, isEmpty);
      expect(fixture.coordinator.snapshot.providers['claude']!.active, 1);
      await lease.release();
      expect(fixture.coordinator.snapshot.providers['claude']!.active, 0);
    });

    test('fail-fast admission reports exhaustion without queueing', () async {
      final fixture = _CoordinatorFixture(capacities: const {'claude': 1});
      addTearDown(fixture.dispose);
      final active = await fixture.acquire(sessionId: 'active');

      final denied = await fixture.coordinator.acquire(
        fixture.request(sessionId: 'denied', admission: ExecutionAdmission.failFast),
      );

      expect(denied, isNull);
      expect(fixture.coordinator.snapshot.providers['claude']!.queued, 0);
      await active.release();
    });

    test('runs admission before capacity and releases it when fail-fast capacity is denied', () async {
      final calls = <String>[];
      late final ExecutionCoordinator coordinator;
      coordinator = ExecutionCoordinator(
        providerCapacities: const {'claude': 1},
        admitExecution: (request) async => calls.add('admit:${request.sessionId}'),
        releaseAdmission: (sessionId) => calls.add('release:$sessionId'),
        createWorker: (request) async {
          calls.add('create:${request.sessionId}');
          return _runner(_TestHarness(), providerId: request.providerId, profileId: request.profileId);
        },
      );
      addTearDown(coordinator.dispose);
      ExecutionRequest request(String sessionId, {ExecutionAdmission admission = ExecutionAdmission.wait}) =>
          ExecutionRequest(
            surface: ExecutionSurface.task,
            providerId: 'claude',
            sessionId: sessionId,
            fingerprint: coordinator.fingerprintFor('claude', 'workspace'),
            admission: admission,
          );

      final active = await coordinator.acquire(request('active'));
      final denied = await coordinator.acquire(request('denied', admission: ExecutionAdmission.failFast));

      expect(active!.admissionOwned, isTrue);
      expect(denied, isNull);
      expect(calls, ['admit:active', 'create:active', 'admit:denied', 'release:denied']);
      await active.release();
      expect(calls.last, 'release:active');
    });

    test('releases admission when worker creation fails', () async {
      final calls = <String>[];
      final coordinator = ExecutionCoordinator(
        providerCapacities: const {'claude': 1},
        admitExecution: (request) async => calls.add('admit:${request.sessionId}'),
        releaseAdmission: (sessionId) => calls.add('release:$sessionId'),
        createWorker: (_) async => throw const WorkerCreationException('failed'),
      );
      addTearDown(coordinator.dispose);

      await expectLater(
        coordinator.acquire(
          ExecutionRequest(
            surface: ExecutionSurface.task,
            providerId: 'claude',
            sessionId: 'failed',
            fingerprint: coordinator.fingerprintFor('claude', 'workspace'),
          ),
        ),
        throwsA(isA<WorkerCreationException>()),
      );

      expect(calls, ['admit:failed', 'release:failed']);
      expect(coordinator.snapshot.activeWorkers, 0);
    });

    test('capacity-only lease owns and releases admission', () async {
      final calls = <String>[];
      final coordinator = ExecutionCoordinator(
        providerCapacities: const {'claude': 1},
        admitExecution: (request) async => calls.add('admit:${request.sessionId}'),
        releaseAdmission: (sessionId) => calls.add('release:$sessionId'),
        createWorker: (_) async => throw StateError('must not create'),
      );
      addTearDown(coordinator.dispose);

      final lease = await coordinator.acquire(
        ExecutionRequest(
          surface: ExecutionSurface.workflow,
          providerId: 'claude',
          sessionId: 'workflow',
          fingerprint: coordinator.fingerprintFor('claude', 'workspace'),
        ),
      );
      expect(lease!.admissionOwned, isTrue);
      expect(calls, ['admit:workflow']);

      await lease.release();
      expect(calls, ['admit:workflow', 'release:workflow']);
    });

    test('capacity-only quarantine is idempotent and permanently removes the slot', () async {
      final fixture = _CoordinatorFixture(capacities: const {'claude': 1});
      addTearDown(fixture.dispose);
      final lease = await fixture.acquire(sessionId: 'workflow', surface: ExecutionSurface.workflow);

      final first = lease.quarantine();
      final second = lease.quarantine();
      expect(second, same(first));
      await Future.wait([first, second]);
      await lease.release();

      final capacity = fixture.coordinator.snapshot.providers['claude']!;
      expect(capacity.active, 0);
      expect(capacity.effective, 0);
      expect(capacity.quarantined, 1);
    });

    test('selects the execution lane from the surface centrally', () async {
      final primaryHarness = _TestHarness();
      final fixture = _CoordinatorFixture(capacities: const {'claude': 1}, primaryHarness: primaryHarness);
      addTearDown(fixture.dispose);

      for (final surface in [ExecutionSurface.interactive, ExecutionSurface.channel]) {
        final lease = await fixture.acquire(sessionId: surface.name, profileId: 'primary', surface: surface);
        expect(lease.lane, ExecutionLane.primary);
        await lease.release();
      }
      for (final surface in [
        ExecutionSurface.task,
        ExecutionSurface.scheduler,
        ExecutionSurface.advisor,
        ExecutionSurface.system,
        ExecutionSurface.logicalAgent,
      ]) {
        final lease = await fixture.acquire(sessionId: surface.name, surface: surface);
        expect(lease.lane, ExecutionLane.worker);
        await lease.release();
      }
      final workflow = await fixture.acquire(sessionId: 'workflow', surface: ExecutionSurface.workflow);
      expect(workflow.lane, ExecutionLane.capacityOnly);
      await workflow.release();
    });

    test('SDK background fallback is explicit and excludes advisor, workflow, and logical-agent surfaces', () async {
      final primaryHarness = _TestHarness();
      final primary = _runner(primaryHarness, providerId: 'claude', profileId: 'workspace');
      final coordinator = ExecutionCoordinator(
        providerCapacities: const {},
        primary: primary,
        allowPrimaryBackgroundFallback: true,
        createWorker: (_) => throw StateError('must not create'),
      );
      addTearDown(coordinator.dispose);

      for (final surface in [ExecutionSurface.task, ExecutionSurface.scheduler, ExecutionSurface.system]) {
        final lease = await coordinator.acquire(
          ExecutionRequest(
            surface: surface,
            providerId: 'claude',
            sessionId: surface.name,
            fingerprint: coordinator.fingerprintFor('claude', 'workspace'),
          ),
        );
        await lease!.release();
      }
      for (final surface in [ExecutionSurface.advisor, ExecutionSurface.workflow, ExecutionSurface.logicalAgent]) {
        await expectLater(
          coordinator.acquire(
            ExecutionRequest(
              surface: surface,
              providerId: 'claude',
              sessionId: surface.name,
              fingerprint: coordinator.fingerprintFor('claude', 'workspace'),
            ),
          ),
          throwsStateError,
        );
      }
    });

    test('disposes an unhealthy worker and creates its replacement', () async {
      final fixture = _CoordinatorFixture(capacities: const {'claude': 1});
      addTearDown(fixture.dispose);
      final first = await fixture.acquire(sessionId: 'first');
      final firstHarness = first.runner!.harness as _TestHarness;
      firstHarness.setState(WorkerState.crashed);

      await first.release();
      final replacement = await fixture.acquire(sessionId: 'second');

      expect(firstHarness.stopCalled, isTrue);
      expect(firstHarness.disposeCalled, isTrue);
      expect(replacement.runner, isNot(same(first.runner)));
      expect(fixture.created, hasLength(2));
      await replacement.release();
    });

    test('rejects and disposes a non-idle worker returned by the factory', () async {
      final harness = _TestHarness()..setState(WorkerState.stopped);
      late final ExecutionCoordinator coordinator;
      coordinator = ExecutionCoordinator(
        providerCapacities: const {'claude': 1},
        createWorker: (request) async => _runner(harness, providerId: request.providerId, profileId: request.profileId),
      );
      addTearDown(coordinator.dispose);

      await expectLater(
        coordinator.acquire(
          ExecutionRequest(
            surface: ExecutionSurface.task,
            providerId: 'claude',
            sessionId: 'invalid-factory-worker',
            fingerprint: coordinator.fingerprintFor('claude', 'workspace'),
          ),
        ),
        throwsA(isA<StateError>().having((error) => error.message, 'message', contains('non-idle'))),
      );

      expect(harness.stopCalled, isTrue);
      expect(harness.disposeCalled, isTrue);
      expect(coordinator.snapshot.activeWorkers, 0);
      expect(coordinator.snapshot.effectiveWorkers, 1);
    });

    test('quarantines a non-idle factory result when teardown is unconfirmed', () async {
      final harness = _TestHarness(terminationConfirmed: false)..setState(WorkerState.crashed);
      late final ExecutionCoordinator coordinator;
      coordinator = ExecutionCoordinator(
        providerCapacities: const {'claude': 1},
        createWorker: (request) async => _runner(harness, providerId: request.providerId, profileId: request.profileId),
      );
      addTearDown(coordinator.dispose);

      await expectLater(
        coordinator.acquire(
          ExecutionRequest(
            surface: ExecutionSurface.task,
            providerId: 'claude',
            sessionId: 'unsafe-factory-worker',
            fingerprint: coordinator.fingerprintFor('claude', 'workspace'),
          ),
        ),
        throwsStateError,
      );

      final capacity = coordinator.snapshot.providers['claude']!;
      expect(capacity.active, 0);
      expect(capacity.effective, 0);
      expect(capacity.quarantined, 1);
    });

    test('quarantines a slot when unhealthy worker teardown is unconfirmed', () async {
      final fixture = _CoordinatorFixture(capacities: const {'claude': 1}, terminationConfirmed: false);
      addTearDown(fixture.dispose);
      final lease = await fixture.acquire(sessionId: 'unsafe');
      (lease.runner!.harness as _TestHarness).setState(WorkerState.crashed);

      await lease.release();

      final capacity = fixture.coordinator.snapshot.providers['claude']!;
      expect(capacity.quarantined, 1);
      expect(capacity.effective, 0);
      expect(capacity.active, 0);
      expect(
        await fixture.coordinator.acquire(
          fixture.request(sessionId: 'replacement', admission: ExecutionAdmission.failFast),
        ),
        isNull,
      );
    });

    test('dispose reaps cached workers and the primary harness', () async {
      final primaryHarness = _TestHarness();
      final fixture = _CoordinatorFixture(capacities: const {'claude': 1}, primaryHarness: primaryHarness);
      final lease = await fixture.acquire(sessionId: 'cached');
      final workerHarness = lease.runner!.harness as _TestHarness;
      await lease.release();

      await fixture.dispose();

      expect(workerHarness.stopCalled, isTrue);
      expect(workerHarness.disposeCalled, isTrue);
      expect(primaryHarness.stopCalled, isTrue);
      expect(primaryHarness.disposeCalled, isTrue);
    });

    test('concurrent dispose calls await the same complete shutdown', () async {
      final primaryHarness = _DelayedDisposeHarness();
      final coordinator = ExecutionCoordinator(
        providerCapacities: const {},
        primary: _runner(primaryHarness, providerId: 'claude', profileId: 'workspace'),
        createWorker: (_) => throw StateError('must not create'),
      );

      final first = coordinator.dispose();
      await primaryHarness.disposeStarted.future;
      final second = coordinator.dispose();
      var secondCompleted = false;
      unawaited(second.then((_) => secondCompleted = true));
      await pumpEventQueue();

      expect(second, same(first));
      expect(secondCompleted, isFalse);

      primaryHarness.allowDispose.complete();
      await Future.wait([first, second]);
      expect(secondCompleted, isTrue);
    });

    test('dispose drains an in-flight factory and rejects its late worker', () async {
      final createStarted = Completer<void>();
      final allowCreate = Completer<void>();
      final harness = _TestHarness();
      final coordinator = ExecutionCoordinator(
        providerCapacities: const {'claude': 1},
        createWorker: (request) async {
          createStarted.complete();
          await allowCreate.future;
          return _runner(harness, providerId: request.providerId, profileId: request.profileId);
        },
      );
      final acquisition = coordinator.acquire(
        ExecutionRequest(
          surface: ExecutionSurface.task,
          providerId: 'claude',
          sessionId: 'pending',
          fingerprint: coordinator.fingerprintFor('claude', 'workspace'),
        ),
      );
      await createStarted.future;

      final disposal = coordinator.dispose();
      var disposed = false;
      unawaited(disposal.then((_) => disposed = true));
      await pumpEventQueue();
      expect(disposed, isFalse);

      allowCreate.complete();
      await expectLater(acquisition, throwsStateError);
      await disposal;

      expect(harness.disposeCalled, isTrue);
      expect(coordinator.snapshot.activeWorkers, 0);
    });

    test('continuity reset fails closed while worker creation is pending', () async {
      final createStarted = Completer<void>();
      final allowCreate = Completer<void>();
      final coordinator = ExecutionCoordinator(
        providerCapacities: const {'claude': 1},
        createWorker: (request) async {
          createStarted.complete();
          await allowCreate.future;
          return _runner(_TestHarness(), providerId: request.providerId, profileId: request.profileId);
        },
      );
      addTearDown(coordinator.dispose);
      final acquisition = coordinator.acquire(
        ExecutionRequest(
          surface: ExecutionSurface.task,
          providerId: 'claude',
          sessionId: 'pending',
          fingerprint: coordinator.fingerprintFor('claude', 'workspace'),
        ),
      );
      await createStarted.future;

      await expectLater(
        coordinator.resetSessionContinuity('pending'),
        throwsA(isA<BusyTurnException>().having((error) => error.isSameSession, 'isSameSession', isTrue)),
      );

      allowCreate.complete();
      final lease = await acquisition;
      await lease!.release();
    });

    test('snapshot and lifecycle events report real allocation state', () async {
      final fixture = _CoordinatorFixture(capacities: const {'claude': 1});
      addTearDown(fixture.dispose);
      final events = <ExecutionEvent>[];
      final subscription = fixture.coordinator.events.listen(events.add);
      addTearDown(subscription.cancel);

      final active = await fixture.acquire(sessionId: 'active', taskId: 'task-1');
      final queuedFuture = fixture.coordinator.acquire(fixture.request(sessionId: 'queued'));
      await _flushEvents();

      var snapshot = fixture.coordinator.snapshot;
      expect(snapshot.configuredWorkers, 1);
      expect(snapshot.activeWorkers, 1);
      expect(snapshot.queuedWorkers, 1);
      expect(snapshot.cachedWorkers, 0);
      expect(snapshot.availableWorkers, 0);

      await active.release();
      final queued = (await queuedFuture)!;
      await _flushEvents();
      snapshot = fixture.coordinator.snapshot;
      expect(snapshot.activeWorkers, 1);
      expect(snapshot.queuedWorkers, 0);
      expect(snapshot.cachedWorkers, 0);

      await queued.release();
      await _flushEvents();
      snapshot = fixture.coordinator.snapshot;
      expect(snapshot.activeWorkers, 0);
      expect(snapshot.cachedWorkers, 1);
      expect(snapshot.availableWorkers, 1);
      expect(
        events.map((event) => event.kind),
        containsAllInOrder([
          ExecutionEventKind.runnerCreated,
          ExecutionEventKind.acquired,
          ExecutionEventKind.cached,
          ExecutionEventKind.released,
          ExecutionEventKind.acquired,
          ExecutionEventKind.cached,
          ExecutionEventKind.released,
        ]),
      );
      expect(events.where((event) => event.kind == ExecutionEventKind.acquired).first.request.taskId, 'task-1');
    });
  });
}

Future<void> _flushEvents() => Future<void>.delayed(Duration.zero);

final class _CoordinatorFixture {
  _CoordinatorFixture({
    required Map<String, int> capacities,
    ResolveExecutionFingerprint? resolveFingerprint,
    bool terminationConfirmed = true,
    _TestHarness? primaryHarness,
  }) : _terminationConfirmed = terminationConfirmed {
    coordinator = ExecutionCoordinator(
      providerCapacities: capacities,
      resolveFingerprint: resolveFingerprint,
      primary: primaryHarness == null ? null : _runner(primaryHarness, providerId: 'claude', profileId: 'primary'),
      createWorker: (request) async {
        final harness = _TestHarness(terminationConfirmed: _terminationConfirmed);
        final runner = _runner(harness, providerId: request.providerId, profileId: request.profileId);
        created.add(runner);
        return runner;
      },
    );
  }

  final bool _terminationConfirmed;
  final List<TurnRunner> created = [];
  late ExecutionCoordinator coordinator;
  var _disposed = false;

  ExecutionRequest request({
    required String sessionId,
    String providerId = 'claude',
    String profileId = 'workspace',
    ExecutionSurface surface = ExecutionSurface.task,
    ExecutionAdmission admission = ExecutionAdmission.wait,
    String? taskId,
  }) => ExecutionRequest(
    surface: surface,
    providerId: providerId,
    sessionId: sessionId,
    fingerprint: coordinator.fingerprintFor(providerId, profileId),
    admission: admission,
    taskId: taskId,
  );

  Future<ExecutionLease> acquire({
    required String sessionId,
    String providerId = 'claude',
    String profileId = 'workspace',
    ExecutionSurface surface = ExecutionSurface.task,
    String? taskId,
  }) async => (await coordinator.acquire(
    request(sessionId: sessionId, providerId: providerId, profileId: profileId, surface: surface, taskId: taskId),
  ))!;

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await coordinator.dispose();
  }
}

TurnRunner _runner(_TestHarness harness, {required String providerId, required String profileId}) => TurnRunner(
  harness: harness,
  messages: _FakeMessageService(),
  behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-execution-coordinator-test'),
  providerId: providerId,
  profileId: profileId,
);

class _TestHarness extends FakeAgentHarness {
  _TestHarness({this.terminationConfirmed = true}) : super(autoTransitionState: false);

  final bool terminationConfirmed;

  @override
  bool get isRootProcessTerminationConfirmed => terminationConfirmed;
}

final class _DelayedDisposeHarness extends _TestHarness {
  final disposeStarted = Completer<void>();
  final allowDispose = Completer<void>();

  @override
  Future<void> dispose() async {
    if (!disposeStarted.isCompleted) disposeStarted.complete();
    await allowDispose.future;
    await super.dispose();
  }
}

final class _FakeMessageService implements MessageService {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
