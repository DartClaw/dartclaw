import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

void main() {
  group('HarnessPool', () {
    test('primary runner is always index 0', () {
      final runners = _createRunners(3);
      final pool = HarnessPool(runners: runners);

      expect(pool.primary, same(runners[0]));
      expect(pool.size, 3);
      expect(pool.maxConcurrentTasks, 2);
    });

    test('tryAcquire returns idle runner from task pool', () {
      final runners = _createRunners(3);
      final pool = HarnessPool(runners: runners);

      final acquired = pool.tryAcquire();
      expect(acquired, isNotNull);
      expect(acquired, isNot(same(runners[0]))); // never the primary
      expect(pool.activeCount, 1);
      expect(pool.availableCount, 1);
    });

    test('tryAcquire returns null when all task runners busy', () {
      final runners = _createRunners(3);
      final pool = HarnessPool(runners: runners);

      pool.tryAcquire(); // acquire runner 1
      pool.tryAcquire(); // acquire runner 2

      final third = pool.tryAcquire();
      expect(third, isNull);
      expect(pool.activeCount, 2);
      expect(pool.availableCount, 0);
    });

    test('release returns runner to available pool', () {
      final runners = _createRunners(3);
      final pool = HarnessPool(runners: runners);

      final acquired = pool.tryAcquire()!;
      expect(pool.activeCount, 1);

      pool.release(acquired);
      expect(pool.activeCount, 0);
      expect(pool.availableCount, 2);

      // Can acquire again after release.
      final reacquired = pool.tryAcquire();
      expect(reacquired, isNotNull);
    });

    test('activeCount and availableCount track correctly', () {
      final runners = _createRunners(4);
      final pool = HarnessPool(runners: runners);

      expect(pool.activeCount, 0);
      expect(pool.availableCount, 3);

      final r1 = pool.tryAcquire()!;
      expect(pool.activeCount, 1);
      expect(pool.availableCount, 2);

      final r2 = pool.tryAcquire()!;
      expect(pool.activeCount, 2);
      expect(pool.availableCount, 1);

      pool.release(r1);
      expect(pool.activeCount, 1);
      expect(pool.availableCount, 2);

      pool.release(r2);
      expect(pool.activeCount, 0);
      expect(pool.availableCount, 3);
    });

    test('single-harness pool (maxConcurrent: 1) — tryAcquire always returns null', () {
      final runners = _createRunners(1);
      final pool = HarnessPool(runners: runners);

      expect(pool.size, 1);
      expect(pool.maxConcurrentTasks, 0);
      expect(pool.tryAcquire(), isNull);
    });

    test('dispose stops all harnesses', () async {
      final workers = <_FakeWorker>[];
      final runners = <TurnRunner>[];
      for (var i = 0; i < 3; i++) {
        final worker = _FakeWorker();
        workers.add(worker);
        runners.add(
          TurnRunner(
            harness: worker,
            messages: _FakeMessageService(),
            behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-pool-test'),
          ),
        );
      }
      final pool = HarnessPool(runners: runners);

      await pool.dispose();

      for (final worker in workers) {
        expect(worker.stopped, isTrue);
        expect(worker.disposed, isTrue);
      }
      expect(pool.availableCount, 0);
    });

    test('concurrent acquisition — two tasks run in parallel', () {
      final runners = _createRunners(3);
      final pool = HarnessPool(runners: runners);

      final r1 = pool.tryAcquire();
      final r2 = pool.tryAcquire();

      expect(r1, isNotNull);
      expect(r2, isNotNull);
      expect(r1, isNot(same(r2)));
      expect(r1, isNot(same(pool.primary)));
      expect(r2, isNot(same(pool.primary)));
      expect(pool.activeCount, 2);
    });

    group('lazy spawning', () {
      test('spawnableCount reflects remaining capacity', () {
        final runners = _createRunners(1); // primary only
        final pool = HarnessPool(runners: runners, maxConcurrentTasks: 3);

        expect(pool.spawnableCount, 3);
        expect(pool.availableCount, 0);
      });

      test('addRunner makes runner immediately available', () {
        final runners = _createRunners(1);
        final pool = HarnessPool(runners: runners, maxConcurrentTasks: 2);

        expect(pool.tryAcquire(), isNull);

        final newRunner = _createRunners(1).first;
        pool.addRunner(newRunner);

        expect(pool.size, 2);
        expect(pool.spawnableCount, 1);
        expect(pool.availableCount, 1);

        final acquired = pool.tryAcquire();
        expect(acquired, same(newRunner));
      });

      test('addRunner throws when at capacity', () {
        final runners = _createRunners(1);
        final pool = HarnessPool(runners: runners, maxConcurrentTasks: 1);

        pool.addRunner(_createRunners(1).first);

        expect(() => pool.addRunner(_createRunners(1).first), throwsStateError);
      });

      test('spawnableCount decreases as runners are added', () {
        final runners = _createRunners(1);
        final pool = HarnessPool(runners: runners, maxConcurrentTasks: 3);

        expect(pool.spawnableCount, 3);

        pool.addRunner(_createRunners(1).first);
        expect(pool.spawnableCount, 2);

        pool.addRunner(_createRunners(1).first);
        expect(pool.spawnableCount, 1);

        pool.addRunner(_createRunners(1).first);
        expect(pool.spawnableCount, 0);
      });

      test('dispose includes lazily-added runners', () async {
        final workers = <_FakeWorker>[];
        TurnRunner makeRunner() {
          final worker = _FakeWorker();
          workers.add(worker);
          return TurnRunner(
            harness: worker,
            messages: _FakeMessageService(),
            behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-pool-test'),
          );
        }

        final pool = HarnessPool(runners: [makeRunner()], maxConcurrentTasks: 2);
        pool.addRunner(makeRunner());

        await pool.dispose();

        for (final worker in workers) {
          expect(worker.stopped, isTrue);
          expect(worker.disposed, isTrue);
        }
      });
    });
  });
}

List<TurnRunner> _createRunners(int count) {
  return List.generate(count, (_) {
    return TurnRunner(
      harness: _FakeWorker(),
      messages: _FakeMessageService(),
      behavior: BehaviorFileService(workspaceDir: '/tmp/nonexistent-pool-test'),
    );
  });
}

class _FakeWorker implements AgentHarness {
  @override
  String skillActivationLine(String skill) => "Use the '$skill' skill.";

  final _eventsCtrl = StreamController<BridgeEvent>.broadcast();
  bool stopped = false;
  bool disposed = false;

  @override
  bool get supportsCostReporting => true;

  @override
  bool get supportsToolApproval => true;

  @override
  bool get supportsStreaming => true;

  @override
  bool get supportsCachedTokens => false;

  @override
  bool get supportsSessionContinuity => false;

  @override
  bool get supportsPreCompactHook => false;

  @override
  PromptStrategy get promptStrategy => PromptStrategy.replace;

  @override
  WorkerState get state => WorkerState.idle;

  @override
  Stream<BridgeEvent> get events => _eventsCtrl.stream;

  @override
  Future<void> start() async {}

  @override
  Future<Map<String, dynamic>> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    Map<String, dynamic>? mcpServers,
    bool resume = false,
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
  }) async {
    return <String, dynamic>{'input_tokens': 0, 'output_tokens': 0};
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<void> stop() async {
    stopped = true;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    if (!_eventsCtrl.isClosed) await _eventsCtrl.close();
  }
}

/// Minimal fake message service for TurnRunner constructor.
class _FakeMessageService implements MessageService {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
