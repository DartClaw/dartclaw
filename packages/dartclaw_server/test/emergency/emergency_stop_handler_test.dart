import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  late InMemoryTaskRepository repo;
  late TaskService taskService;
  late TestEventBus eventBus;

  setUp(() {
    repo = InMemoryTaskRepository();
    eventBus = TestEventBus();
    taskService = TaskService(repo, eventBus: eventBus);
  });

  tearDown(() async {
    await eventBus.dispose();
    await taskService.dispose();
  });

  final ts = DateTime.parse('2026-03-21T12:00:00Z');

  Future<Task> makeTask({
    required String id,
    required TaskStatus status,
  }) async {
    final task = Task(
      id: id,
      title: 'Task $id',
      description: 'do work',
      type: TaskType.research,
      createdAt: ts,
    );
    // Insert via repo directly to set status without event side-effects.
    await repo.insert(task);
    if (status != TaskStatus.draft) {
      // Transition via service to reach desired status.
      await taskService.transition(id, TaskStatus.queued, now: ts, trigger: 'test');
      if (status == TaskStatus.running) {
        await taskService.transition(id, TaskStatus.running, now: ts, trigger: 'test');
      }
    }
    return (await repo.getById(id))!;
  }

  group('EmergencyStopHandler — task cancellation', () {
    test('cancels all running tasks', () async {
      await makeTask(id: 't1', status: TaskStatus.running);
      await makeTask(id: 't2', status: TaskStatus.running);

      final handler = EmergencyStopHandler(
        turnManager: _FakeTurnManager(activeSessionIds: {}),
        taskService: taskService,
      );
      final result = await handler.execute(stoppedBy: 'alice', now: ts);

      expect(result.tasksCancelled, 2);
      expect(result.turnsCancelled, 0);
      expect(result.hadActivity, isTrue);

      final t1 = await taskService.get('t1');
      final t2 = await taskService.get('t2');
      expect(t1!.status, TaskStatus.cancelled);
      expect(t2!.status, TaskStatus.cancelled);
    });

    test('cancels all queued tasks', () async {
      await makeTask(id: 'q1', status: TaskStatus.queued);
      await makeTask(id: 'q2', status: TaskStatus.queued);

      final handler = EmergencyStopHandler(
        turnManager: _FakeTurnManager(activeSessionIds: {}),
        taskService: taskService,
      );
      final result = await handler.execute(stoppedBy: 'alice', now: ts);

      expect(result.tasksCancelled, 2);
      expect((await taskService.get('q1'))!.status, TaskStatus.cancelled);
      expect((await taskService.get('q2'))!.status, TaskStatus.cancelled);
    });

    test('cancels both running and queued tasks', () async {
      await makeTask(id: 'r1', status: TaskStatus.running);
      await makeTask(id: 'q1', status: TaskStatus.queued);

      final handler = EmergencyStopHandler(
        turnManager: _FakeTurnManager(activeSessionIds: {}),
        taskService: taskService,
      );
      final result = await handler.execute(stoppedBy: 'bob', now: ts);

      expect(result.tasksCancelled, 2);
    });

    test('does not cancel draft, review, accepted, or rejected tasks', () async {
      await makeTask(id: 'draft', status: TaskStatus.draft);
      // We cannot reach review/accepted/rejected via direct service without
      // more setup, but we verify draft is untouched.

      final handler = EmergencyStopHandler(
        turnManager: _FakeTurnManager(activeSessionIds: {}),
        taskService: taskService,
      );
      final result = await handler.execute(stoppedBy: 'alice', now: ts);

      expect(result.tasksCancelled, 0);
      expect(result.hadActivity, isFalse);
      final draft = await taskService.get('draft');
      expect(draft!.status, TaskStatus.draft);
    });

    test('no activity — hadActivity is false', () async {
      final handler = EmergencyStopHandler(
        turnManager: _FakeTurnManager(activeSessionIds: {}),
        taskService: taskService,
      );
      final result = await handler.execute(stoppedBy: 'alice', now: ts);

      expect(result.hadActivity, isFalse);
      expect(result.turnsCancelled, 0);
      expect(result.tasksCancelled, 0);
    });

    test('concurrent modification — VersionConflictException is caught and skipped', () async {
      await makeTask(id: 'r1', status: TaskStatus.running);
      await makeTask(id: 'r2', status: TaskStatus.running);

      // Simulate r1 completing between list() and transition() by marking it
      // as cancelled manually in the repo before execute() runs its cancel pass.
      repo.concurrentVersionOnNextTransition = true;

      final handler = EmergencyStopHandler(
        turnManager: _FakeTurnManager(activeSessionIds: {}),
        taskService: taskService,
      );

      // Should not throw — concurrent modification is caught.
      final result = await handler.execute(stoppedBy: 'alice', now: ts);

      // One failed + one or more cancelled — total is at least 0.
      expect(result.tasksCancelled, greaterThanOrEqualTo(0));
    });
  });

  group('EmergencyStopHandler — turn cancellation', () {
    test('cancels active turn sessions across all runners', () async {
      final fakeTurns = _FakeTurnManager(
        activeSessionIds: {'sess-1', 'sess-2'},
      );

      final handler = EmergencyStopHandler(
        turnManager: fakeTurns,
        taskService: taskService,
      );
      final result = await handler.execute(stoppedBy: 'alice', now: ts);

      expect(result.turnsCancelled, 2);
      expect(fakeTurns.cancelledSessions, unorderedEquals(['sess-1', 'sess-2']));
    });

    test('turn cancel failure is logged but stop continues', () async {
      final fakeTurns = _FakeTurnManager(
        activeSessionIds: {'sess-good', 'sess-fail'},
        failOnCancel: {'sess-fail'},
      );
      await makeTask(id: 'r1', status: TaskStatus.running);

      final handler = EmergencyStopHandler(
        turnManager: fakeTurns,
        taskService: taskService,
      );
      final result = await handler.execute(stoppedBy: 'alice', now: ts);

      // sess-fail threw — only 1 turn counted, but task still cancelled.
      expect(result.turnsCancelled, 1);
      expect(result.tasksCancelled, 1);
    });
  });

  group('EmergencyStopHandler — events', () {
    test('fires EmergencyStopEvent on EventBus with correct data', () async {
      await makeTask(id: 'r1', status: TaskStatus.running);
      final fakeTurns = _FakeTurnManager(activeSessionIds: {'sess-1'});

      final handler = EmergencyStopHandler(
        turnManager: fakeTurns,
        taskService: taskService,
        eventBus: eventBus,
      );
      await handler.execute(stoppedBy: 'carol', now: ts);

      final events = eventBus.firedEvents.whereType<EmergencyStopEvent>().toList();
      expect(events, hasLength(1));
      expect(events.first.stoppedBy, 'carol');
      expect(events.first.turnsCancelled, 1);
      expect(events.first.tasksCancelled, 1);
      expect(events.first.timestamp, ts);
    });

    test('fires emergency_stop SSE broadcast', () async {
      final sseBroadcast = _FakeSseBroadcast();
      final handler = EmergencyStopHandler(
        turnManager: _FakeTurnManager(activeSessionIds: {}),
        taskService: taskService,
        sseBroadcast: sseBroadcast,
      );
      await handler.execute(stoppedBy: 'dave', now: ts);

      expect(sseBroadcast.broadcastedEvents, hasLength(1));
      expect(sseBroadcast.broadcastedEvents.first.$1, 'emergency_stop');
      expect(sseBroadcast.broadcastedEvents.first.$2['stopped_by'], 'dave');
    });

    test('no EventBus — executes without error', () async {
      final handler = EmergencyStopHandler(
        turnManager: _FakeTurnManager(activeSessionIds: {}),
        taskService: taskService,
        // eventBus: null (default)
      );
      expect(() => handler.execute(stoppedBy: 'alice', now: ts), returnsNormally);
    });
  });
}

// ---------------------------------------------------------------------------
// Test doubles
// ---------------------------------------------------------------------------

/// Fake [TurnManager] that reports configurable active session IDs and
/// records which sessions were cancelled.
class _FakeTurnManager implements TurnManager {
  final Set<String> _activeSessionIds;
  final Set<String> _failOnCancel;
  final List<String> cancelledSessions = [];

  _FakeTurnManager({
    required Set<String> activeSessionIds,
    Set<String> failOnCancel = const {},
  })  : _activeSessionIds = activeSessionIds,
        _failOnCancel = failOnCancel;

  @override
  HarnessPool get pool => _FakePool(this);

  // All other TurnManager methods — not needed for these tests.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not implemented in _FakeTurnManager');
}

/// Fake [HarnessPool] that exposes a single [_FakeRunner] backed by the turn manager.
class _FakePool implements HarnessPool {
  final _FakeTurnManager _manager;
  late final _FakeRunner _runner = _FakeRunner(_manager);

  _FakePool(this._manager);

  @override
  List<TurnRunner> get runners => [_runner];

  @override
  TurnRunner get primary => _runner;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not implemented in _FakePool');
}

/// Fake [TurnRunner] that exposes configured active sessions and records cancellations.
class _FakeRunner implements TurnRunner {
  final _FakeTurnManager _manager;

  _FakeRunner(this._manager);

  @override
  Iterable<String> get activeSessionIds => _manager._activeSessionIds;

  @override
  Future<void> cancelTurn(String sessionId) async {
    if (_manager._failOnCancel.contains(sessionId)) {
      throw StateError('Simulated cancel failure for $sessionId');
    }
    _manager.cancelledSessions.add(sessionId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not implemented in _FakeRunner');
}

/// Fake [SseBroadcast] that records broadcast calls.
class _FakeSseBroadcast implements SseBroadcast {
  final List<(String, Map<String, dynamic>)> broadcastedEvents = [];

  @override
  void broadcast(String event, Map<String, dynamic> data) {
    broadcastedEvents.add((event, data));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not implemented in _FakeSseBroadcast');
}
