import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  late SlidingWindowRateLimiter limiter;
  final t0 = DateTime(2024, 1, 1, 12, 0, 0);

  setUp(() {
    limiter = SlidingWindowRateLimiter(
      limit: 3,
      window: const Duration(minutes: 1),
    );
  });

  group('SlidingWindowRateLimiter', () {
    test('allows up to limit events', () {
      expect(limiter.check('a', now: t0), isTrue);
      expect(limiter.check('a', now: t0.add(const Duration(seconds: 10))), isTrue);
      expect(limiter.check('a', now: t0.add(const Duration(seconds: 20))), isTrue);
    });

    test('rejects the N+1th event within window', () {
      limiter.check('a', now: t0);
      limiter.check('a', now: t0.add(const Duration(seconds: 10)));
      limiter.check('a', now: t0.add(const Duration(seconds: 20)));
      expect(limiter.check('a', now: t0.add(const Duration(seconds: 30))), isFalse);
    });

    test('allows event after window slides', () {
      limiter.check('a', now: t0);
      limiter.check('a', now: t0.add(const Duration(seconds: 10)));
      limiter.check('a', now: t0.add(const Duration(seconds: 20)));
      // 61 seconds later — first event has expired
      expect(limiter.check('a', now: t0.add(const Duration(seconds: 61))), isTrue);
    });

    test('zero limit — always allowed', () {
      final unlimitedLimiter = SlidingWindowRateLimiter(
        limit: 0,
        window: const Duration(minutes: 1),
      );
      for (var i = 0; i < 100; i++) {
        expect(unlimitedLimiter.check('a'), isTrue);
      }
    });

    test('negative limit — always allowed', () {
      final unlimitedLimiter = SlidingWindowRateLimiter(
        limit: -1,
        window: const Duration(minutes: 1),
      );
      expect(unlimitedLimiter.check('a'), isTrue);
    });

    test('multiple keys are independent', () {
      limiter.check('a', now: t0);
      limiter.check('a', now: t0);
      limiter.check('a', now: t0);
      // 'a' is at limit, 'b' is empty
      expect(limiter.check('a', now: t0), isFalse);
      expect(limiter.check('b', now: t0), isTrue);
    });

    test('currentCount reflects active events only', () {
      limiter.check('a', now: t0);
      limiter.check('a', now: t0.add(const Duration(seconds: 30)));
      expect(limiter.currentCount('a', now: t0.add(const Duration(seconds: 30))), 2);
      // After 61s, the first event has expired
      expect(limiter.currentCount('a', now: t0.add(const Duration(seconds: 61))), 1);
    });

    test('currentCount on unknown key returns 0', () {
      expect(limiter.currentCount('unknown'), 0);
    });

    test('usage returns correct fraction', () {
      limiter.check('a', now: t0);
      limiter.check('a', now: t0.add(const Duration(seconds: 10)));
      // 2 out of 3 = 0.667
      expect(limiter.usage('a', now: t0.add(const Duration(seconds: 10))), closeTo(2 / 3, 0.001));
    });

    test('usage returns 0.0 for zero limit', () {
      final unlimitedLimiter = SlidingWindowRateLimiter(
        limit: 0,
        window: const Duration(minutes: 1),
      );
      expect(unlimitedLimiter.usage('a'), 0.0);
    });

    test('totalCount sums across all keys', () {
      limiter.check('a', now: t0);
      limiter.check('a', now: t0);
      limiter.check('b', now: t0);
      expect(limiter.totalCount(now: t0), 3);
    });

    test('reset clears all state', () {
      limiter.check('a', now: t0);
      limiter.check('a', now: t0);
      limiter.check('a', now: t0);
      limiter.reset();
      expect(limiter.currentCount('a', now: t0), 0);
      expect(limiter.check('a', now: t0), isTrue);
    });

    test('failing check does not record event (safe for retry loop)', () {
      limiter.check('a', now: t0);
      limiter.check('a', now: t0);
      limiter.check('a', now: t0);
      // At limit — this should NOT record
      limiter.check('a', now: t0);
      // Count should still be 3, not 4
      expect(limiter.currentCount('a', now: t0), 3);
    });
  });
}
