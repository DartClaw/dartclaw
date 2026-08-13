import 'package:dartclaw_core/dartclaw_core.dart' hide TurnRunner;
import 'package:dartclaw_server/src/behavior/behavior_file_service.dart';
import 'package:dartclaw_server/src/execution_coordinator.dart';
import 'package:dartclaw_server/src/turn_runner.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness;
import 'package:test/test.dart';

/// Allocation identity and container-authority release lifecycle.
///
/// Covers Acceptance Scenarios S03 (host and container workers are never
/// interchangeable) and S07 (container profiles stay distinct without
/// container-runner caching).
void main() {
  group('S03 worker identity spans both policy axes', () {
    test('a released host worker is never handed to a container request', () async {
      final fixture = _Fixture(capacities: const {'claude': 2});
      addTearDown(fixture.dispose);

      final host = await fixture.acquire('session-a', const ExecutionPolicy.host());
      final hostRunner = host.runner;
      await host.release();

      final container = await fixture.acquire('session-a', const ExecutionPolicy.container('workspace'));

      expect(container.runner, isNot(same(hostRunner)));
      expect(container.runner!.executionPolicy, const ExecutionPolicy.container('workspace'));
      await container.release();
    });

    test('a released container worker is never handed to a host request', () async {
      final fixture = _Fixture(capacities: const {'claude': 2});
      addTearDown(fixture.dispose);

      final container = await fixture.acquire('session-a', const ExecutionPolicy.container('workspace'));
      final containerRunner = container.runner;
      await container.release();

      final host = await fixture.acquire('session-a', const ExecutionPolicy.host());

      expect(host.runner, isNot(same(containerRunner)));
      expect(host.runner!.executionPolicy, const ExecutionPolicy.host());
      await host.release();
    });

    test('compatible host runners are still reused, preferring the same session', () async {
      final fixture = _Fixture(capacities: const {'claude': 1});
      addTearDown(fixture.dispose);

      final first = await fixture.acquire('session-a', const ExecutionPolicy.host());
      final firstRunner = first.runner;
      await first.release();

      final second = await fixture.acquire('session-a', const ExecutionPolicy.host());

      expect(second.runner, same(firstRunner), reason: 'host caching remains unchanged');
      expect(fixture.created, hasLength(1));
      await second.release();
    });

    test('each runner reports its real mode, with the host profile absent', () async {
      final fixture = _Fixture(capacities: const {'claude': 2});
      addTearDown(fixture.dispose);

      final host = await fixture.acquire('session-a', const ExecutionPolicy.host());
      final container = await fixture.acquire('session-b', const ExecutionPolicy.container('restricted'));

      expect(host.runner!.executionPolicy.mode, ExecutionMode.host);
      expect(host.runner!.executionPolicy.containerProfile, isNull);
      expect(container.runner!.executionPolicy.mode, ExecutionMode.container);
      expect(container.runner!.executionPolicy.containerProfile, 'restricted');
      await host.release();
      await container.release();
    });
  });

  group('S07 container authorities are dedicated and destroyed on release', () {
    test('a released container runner is destroyed rather than cached', () async {
      final fixture = _Fixture(capacities: const {'claude': 1});
      addTearDown(fixture.dispose);

      final lease = await fixture.acquire('session-a', const ExecutionPolicy.container('workspace'));
      final runner = lease.runner!;
      await lease.release();

      expect(fixture.coordinator.snapshot.cachedWorkers, 0);
      expect(fixture.coordinator.runners, isNot(contains(runner)));
      expect(fixture.destroyed, [runner]);
    });

    test('a second container request receives its own container, never the released one', () async {
      final fixture = _Fixture(capacities: const {'claude': 1});
      addTearDown(fixture.dispose);

      final first = await fixture.acquire('session-a', const ExecutionPolicy.container('workspace'));
      final firstRunner = first.runner;
      await first.release();

      final second = await fixture.acquire('session-a', const ExecutionPolicy.container('workspace'));

      expect(second.runner, isNot(same(firstRunner)));
      expect(fixture.created, hasLength(2), reason: 'each authority builds a fresh harness and container');
      await second.release();
    });

    test('a workspace request cannot reuse a restricted container', () async {
      final fixture = _Fixture(capacities: const {'claude': 2});
      addTearDown(fixture.dispose);

      final restricted = await fixture.acquire('shared', const ExecutionPolicy.container('restricted'));
      final restrictedRunner = restricted.runner;
      await restricted.release();

      final workspace = await fixture.acquire('shared', const ExecutionPolicy.container('workspace'));

      expect(workspace.runner, isNot(same(restrictedRunner)));
      expect(workspace.runner!.executionPolicy, const ExecutionPolicy.container('workspace'));
      await workspace.release();
    });

    test('release terminates, revokes, and destroys before returning capacity', () async {
      final fixture = _Fixture(capacities: const {'claude': 1});
      addTearDown(fixture.dispose);

      final lease = await fixture.acquire('session-a', const ExecutionPolicy.container('workspace'));
      await lease.release();

      expect(fixture.order, [
        'harness-stopped',
        'hook',
        'destroy',
      ], reason: 'authority-scoped resources are revoked while the container still exists');
      expect(
        fixture.activeWorkersDuringDestroy,
        1,
        reason: 'the capacity slot is still held while its container is being destroyed',
      );
      expect(fixture.coordinator.snapshot.activeWorkers, 0);
    });

    test('release hooks receive the released policy and run only for container authorities', () async {
      final fixture = _Fixture(capacities: const {'claude': 2});
      addTearDown(fixture.dispose);

      final host = await fixture.acquire('session-a', const ExecutionPolicy.host());
      await host.release();
      expect(fixture.hookPolicies, isEmpty, reason: 'host release has no container authority to revoke');

      final container = await fixture.acquire('session-b', const ExecutionPolicy.container('restricted'));
      await container.release();

      expect(fixture.hookPolicies, [const ExecutionPolicy.container('restricted')]);
    });

    test('a failed container destroy quarantines the slot rather than returning capacity', () async {
      final fixture = _Fixture(capacities: const {'claude': 2}, destroyThrows: true);
      addTearDown(fixture.dispose);

      final lease = await fixture.acquire('session-a', const ExecutionPolicy.container('workspace'));
      expect(fixture.coordinator.snapshot.availableWorkers, 1);
      await lease.release();

      // The harness confirmed its own termination, but `docker rm -f` threw, so
      // the container may still be alive: the slot must be quarantined, never
      // handed to a fresh authority over a live orphan.
      final snapshot = fixture.coordinator.snapshot;
      expect(snapshot.quarantinedWorkers, 1);
      expect(snapshot.availableWorkers, 1, reason: 'the possibly-orphaned slot is not returned to capacity');
    });

    test('provider capacity totals are unchanged by container teardown', () async {
      final fixture = _Fixture(capacities: const {'claude': 2});
      addTearDown(fixture.dispose);

      final lease = await fixture.acquire('session-a', const ExecutionPolicy.container('workspace'));
      expect(fixture.coordinator.snapshot.availableWorkers, 1);
      await lease.release();

      final snapshot = fixture.coordinator.snapshot;
      expect(snapshot.configuredWorkers, 2);
      expect(snapshot.effectiveWorkers, 2);
      expect(snapshot.activeWorkers, 0);
      expect(snapshot.availableWorkers, 2);
      expect(snapshot.quarantinedWorkers, 0);
    });
  });
}

/// Coordinator wired with recording release hooks and a recording container
/// destroyer, so teardown ordering is observable.
class _Fixture {
  _Fixture({required Map<String, int> capacities, bool destroyThrows = false}) {
    coordinator = ExecutionCoordinator(
      providerCapacities: capacities,
      admitExecution: (_) async {},
      releaseAdmission: (_) {},
      createWorker: (request) async {
        final runner = TurnRunner(
          harness: _RecordingHarness(order),
          messages: _NoOpMessages(),
          behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-container-authority-test'),
          providerId: request.providerId,
          executionPolicy: request.policy,
        );
        created.add(runner);
        return runner;
      },
      releaseHooks: [
        (context) async {
          order.add('hook');
          hookPolicies.add(context.policy);
        },
      ],
      destroyContainerAuthority: (context) async {
        order.add('destroy');
        destroyed.add(context.runner);
        activeWorkersDuringDestroy = coordinator.snapshot.activeWorkers;
        if (destroyThrows) throw StateError('docker rm -f failed');
      },
    );
  }

  late final ExecutionCoordinator coordinator;
  final List<TurnRunner> created = [];
  final List<TurnRunner> destroyed = [];
  final List<ExecutionPolicy> hookPolicies = [];
  final List<String> order = [];

  /// Leased slots still held at the moment the container is destroyed.
  int? activeWorkersDuringDestroy;
  var _disposed = false;

  Future<ExecutionLease> acquire(String sessionId, ExecutionPolicy policy) async {
    final lease = await coordinator.acquire(
      ExecutionRequest(surface: ExecutionSurface.task, providerId: 'claude', policy: policy, sessionId: sessionId),
    );
    return lease!;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await coordinator.dispose();
  }
}

class _RecordingHarness extends FakeAgentHarness {
  _RecordingHarness(this._order) : super(autoTransitionState: false);

  final List<String> _order;

  @override
  Future<void> stop() async {
    if (!_order.contains('harness-stopped')) _order.add('harness-stopped');
    await super.stop();
  }
}

class _NoOpMessages implements MessageService {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
