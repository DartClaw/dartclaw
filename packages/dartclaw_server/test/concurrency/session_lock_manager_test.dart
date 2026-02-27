import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

void main() {
  group('SessionLockManager', () {
    test('single session acquire/release works', () {
      final mgr = SessionLockManager();
      mgr.acquire('s1');
      expect(mgr.isLocked('s1'), isTrue);
      expect(mgr.activeCount, 1);
      mgr.release('s1');
      expect(mgr.isLocked('s1'), isFalse);
      expect(mgr.activeCount, 0);
    });

    test('same session double-acquire throws BusyTurnException(isSameSession: true)', () {
      final mgr = SessionLockManager();
      mgr.acquire('s1');
      expect(
        () => mgr.acquire('s1'),
        throwsA(isA<BusyTurnException>().having((e) => e.isSameSession, 'isSameSession', isTrue)),
      );
      mgr.release('s1');
    });

    test('global cap exceeded throws BusyTurnException(isSameSession: false)', () {
      final mgr = SessionLockManager(maxParallel: 2);
      mgr.acquire('s1');
      mgr.acquire('s2');
      expect(
        () => mgr.acquire('s3'),
        throwsA(isA<BusyTurnException>().having((e) => e.isSameSession, 'isSameSession', isFalse)),
      );
      mgr.release('s1');
      mgr.release('s2');
    });

    test('release decrements counter', () {
      final mgr = SessionLockManager();
      mgr.acquire('s1');
      mgr.acquire('s2');
      expect(mgr.activeCount, 2);
      mgr.release('s1');
      expect(mgr.activeCount, 1);
      mgr.release('s2');
      expect(mgr.activeCount, 0);
    });

    test('multiple sessions up to cap succeed', () {
      final mgr = SessionLockManager(maxParallel: 3);
      mgr.acquire('s1');
      mgr.acquire('s2');
      mgr.acquire('s3');
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
  });
}
