import 'package:dartclaw_kernel/dartclaw_kernel.dart' show ConfigDelta, DartclawConfig, ServerConfig;
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:test/test.dart';

void main() {
  group('SessionLockManager', () {
    test('single session acquire/release works', () async {
      final mgr = SessionLockManager();
      await mgr.acquire('s1');
      expect(mgr.isLocked('s1'), isTrue);
      expect(mgr.activeCount, 1);
      mgr.release('s1');
      expect(mgr.isLocked('s1'), isFalse);
      expect(mgr.activeCount, 0);
    });

    test('same session second acquire waits for release', () async {
      final mgr = SessionLockManager();
      await mgr.acquire('s1');

      var secondAcquired = false;
      final secondFuture = mgr.acquire('s1').then((_) {
        secondAcquired = true;
      });

      // Second acquire should be waiting
      await pumpEventQueue();
      expect(secondAcquired, isFalse);

      mgr.release('s1');
      await secondFuture;
      expect(secondAcquired, isTrue);
      expect(mgr.isLocked('s1'), isTrue);
      mgr.release('s1');
    });

    test('global cap exceeded throws BusyTurnException(isSameSession: false)', () async {
      final mgr = SessionLockManager(maxParallel: 2);
      await mgr.acquire('s1');
      await mgr.acquire('s2');
      expect(
        () => mgr.acquire('s3'),
        throwsA(isA<BusyTurnException>().having((e) => e.isSameSession, 'isSameSession', isFalse)),
      );
      mgr.release('s1');
      mgr.release('s2');
    });

    test('release decrements counter', () async {
      final mgr = SessionLockManager();
      await mgr.acquire('s1');
      await mgr.acquire('s2');
      expect(mgr.activeCount, 2);
      mgr.release('s1');
      expect(mgr.activeCount, 1);
      mgr.release('s2');
      expect(mgr.activeCount, 0);
    });

    test('multiple sessions up to cap succeed', () async {
      final mgr = SessionLockManager(maxParallel: 3);
      await mgr.acquire('s1');
      await mgr.acquire('s2');
      await mgr.acquire('s3');
      expect(mgr.activeCount, 3);
      mgr.release('s1');
      mgr.release('s2');
      mgr.release('s3');
    });

    test('release non-existent session is no-op', () {
      final mgr = SessionLockManager();
      mgr.release('nonexistent'); // should not throw
      expect(mgr.activeCount, 0);
    });

    test('queued same-session request respects global cap after wait', () async {
      final mgr = SessionLockManager(maxParallel: 1);
      await mgr.acquire('s1');

      // s1 second request queues behind first
      final second = mgr.acquire('s1');

      mgr.release('s1');
      await second;
      expect(mgr.activeCount, 1);
      mgr.release('s1');
    });

    test('multiple queued requests serialize correctly', () async {
      final mgr = SessionLockManager();
      await mgr.acquire('s1');

      final order = <int>[];
      final f2 = mgr.acquire('s1').then((_) => order.add(2));
      final f3 = mgr.acquire('s1').then((_) {
        order.add(3);
        mgr.release('s1');
      });

      await pumpEventQueue();
      expect(order, isEmpty);

      mgr.release('s1'); // unblocks f2
      await f2;
      expect(order, [2]);

      mgr.release('s1'); // unblocks f3
      await f3;
      expect(order, [2, 3]);
    });
  });

  group('SessionLockManager.whenCapacityAvailable', () {
    ConfigDelta capDelta(int maxParallelTurns) => ConfigDelta(
      previous: const DartclawConfig.defaults(),
      current: DartclawConfig(server: ServerConfig(maxParallelTurns: maxParallelTurns)),
      changedKeys: const {'server.*'},
    );

    test('completes immediately while the cap has room', () async {
      final mgr = SessionLockManager(maxParallel: 2);
      await mgr.acquire('s1');

      await mgr.whenCapacityAvailable().timeout(Duration.zero);
    });

    test('completes every pending waiter on the release that frees a slot, without reserving it', () async {
      final mgr = SessionLockManager(maxParallel: 1);
      await mgr.acquire('s1');
      var completed = 0;
      final waiters = [
        mgr.whenCapacityAvailable().then((_) => completed++),
        mgr.whenCapacityAvailable().then((_) => completed++),
      ];

      await pumpEventQueue();
      expect(completed, 0);

      mgr.release('s1');
      await Future.wait(waiters);

      expect(completed, 2);
      expect(mgr.activeCount, 0, reason: 'the signal reserves nothing; the caller re-attempts acquire');
    });

    test('completes when a reconfigure raises the cap above the active count', () async {
      final mgr = SessionLockManager(maxParallel: 1);
      await mgr.acquire('s1');
      var completed = false;
      final waiter = mgr.whenCapacityAvailable().then((_) => completed = true);

      mgr.reconfigure(capDelta(2));
      await waiter;

      expect(completed, isTrue);
    });

    test('stays pending on a release that still leaves the cap full', () async {
      final mgr = SessionLockManager(maxParallel: 3);
      await mgr.acquire('s1');
      await mgr.acquire('s2');
      await mgr.acquire('s3');
      mgr.reconfigure(capDelta(1));
      var completed = false;
      final waiter = mgr.whenCapacityAvailable().then((_) => completed = true);

      mgr.release('s1');
      await pumpEventQueue();
      expect(completed, isFalse, reason: '2 active against a cap of 1');

      mgr.release('s2');
      await pumpEventQueue();
      expect(completed, isFalse, reason: '1 active against a cap of 1');

      mgr.release('s3');
      await waiter;
      expect(completed, isTrue);
    });
  });
}
