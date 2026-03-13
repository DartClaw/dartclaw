import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

void main() {
  group('AuthRateLimiter', () {
    test('does not limit under the threshold', () {
      final limiter = AuthRateLimiter(maxAttempts: 5, windowDuration: const Duration(minutes: 1));

      for (var i = 0; i < 4; i++) {
        limiter.recordFailure('client');
      }

      expect(limiter.shouldLimit('client'), isFalse);
    });

    test('limits at the threshold', () {
      final limiter = AuthRateLimiter(maxAttempts: 5, windowDuration: const Duration(minutes: 1));

      for (var i = 0; i < 5; i++) {
        limiter.recordFailure('client');
      }

      expect(limiter.shouldLimit('client'), isTrue);
    });

    test('stays limited over the threshold', () {
      final limiter = AuthRateLimiter(maxAttempts: 5, windowDuration: const Duration(minutes: 1));

      for (var i = 0; i < 6; i++) {
        limiter.recordFailure('client');
      }

      expect(limiter.shouldLimit('client'), isTrue);
    });

    test('reset clears recorded failures', () {
      final limiter = AuthRateLimiter(maxAttempts: 5, windowDuration: const Duration(minutes: 1));

      for (var i = 0; i < 5; i++) {
        limiter.recordFailure('client');
      }
      limiter.reset('client');

      expect(limiter.shouldLimit('client'), isFalse);
    });

    test('window expiry removes old failures', () async {
      final limiter = AuthRateLimiter(maxAttempts: 2, windowDuration: const Duration(milliseconds: 20));

      limiter.recordFailure('client');
      limiter.recordFailure('client');
      expect(limiter.shouldLimit('client'), isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 25));

      expect(limiter.shouldLimit('client'), isFalse);
    });
  });
}
