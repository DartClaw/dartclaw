import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

void main() {
  group('ContextMonitor', () {
    test('shouldFlush is false with no data', () {
      final monitor = ContextMonitor();
      expect(monitor.shouldFlush, isFalse);
    });

    test('shouldFlush is false when under threshold', () {
      final monitor = ContextMonitor(reserveTokens: 20000);
      monitor.update(contextWindow: 200000, contextTokens: 100000);
      expect(monitor.shouldFlush, isFalse);
    });

    test('shouldFlush is true when over threshold', () {
      final monitor = ContextMonitor(reserveTokens: 20000);
      monitor.update(contextWindow: 200000, contextTokens: 185000);
      expect(monitor.shouldFlush, isTrue);
    });

    test('shouldFlush is true at exact threshold', () {
      final monitor = ContextMonitor(reserveTokens: 20000);
      monitor.update(contextWindow: 200000, contextTokens: 180001);
      expect(monitor.shouldFlush, isTrue);
    });

    test('shouldFlush does not re-trigger while flush is pending', () {
      final monitor = ContextMonitor(reserveTokens: 20000);
      monitor.update(contextWindow: 200000, contextTokens: 190000);
      expect(monitor.shouldFlush, isTrue);

      monitor.markFlushStarted();
      expect(monitor.shouldFlush, isFalse);
      expect(monitor.isFlushPending, isTrue);
    });

    test('markFlushCompleted resets pending flag', () {
      final monitor = ContextMonitor(reserveTokens: 20000);
      monitor.update(contextWindow: 200000, contextTokens: 190000);
      monitor.markFlushStarted();
      monitor.markFlushCompleted();

      expect(monitor.isFlushPending, isFalse);
      // Should be able to trigger again
      expect(monitor.shouldFlush, isTrue);
    });

    test('partial updates work (only contextTokens)', () {
      final monitor = ContextMonitor(reserveTokens: 20000);
      monitor.update(contextWindow: 200000);
      expect(monitor.shouldFlush, isFalse); // no token count yet

      monitor.update(contextTokens: 190000);
      expect(monitor.shouldFlush, isTrue);
    });

    test('shouldFlush is false with only contextTokens (no window)', () {
      final monitor = ContextMonitor(reserveTokens: 20000);
      monitor.update(contextTokens: 190000);
      expect(monitor.shouldFlush, isFalse); // no window set
    });

    group('checkThreshold', () {
      test('returns false with no data', () {
        final monitor = ContextMonitor(warningThreshold: 80);
        expect(monitor.checkThreshold(), isFalse);
      });

      test('returns false when below threshold', () {
        final monitor = ContextMonitor(warningThreshold: 80);
        monitor.update(contextWindow: 100000, contextTokens: 79000);
        expect(monitor.checkThreshold(sessionId: 's1'), isFalse);
        expect(monitor.warningEmitted(sessionId: 's1'), isFalse);
      });

      test('returns true when at threshold', () {
        final monitor = ContextMonitor(warningThreshold: 80);
        monitor.update(contextWindow: 100000, contextTokens: 80000);
        expect(monitor.checkThreshold(sessionId: 's1'), isTrue);
        expect(monitor.warningEmitted(sessionId: 's1'), isTrue);
      });

      test('returns true when above threshold', () {
        final monitor = ContextMonitor(warningThreshold: 80);
        monitor.update(contextWindow: 100000, contextTokens: 95000);
        expect(monitor.checkThreshold(sessionId: 's1'), isTrue);
      });

      test('returns false on subsequent calls after first trigger (one-shot per session)', () {
        final monitor = ContextMonitor(warningThreshold: 80);
        monitor.update(contextWindow: 100000, contextTokens: 85000);
        expect(monitor.checkThreshold(sessionId: 's1'), isTrue);
        expect(monitor.checkThreshold(sessionId: 's1'), isFalse);
        expect(monitor.checkThreshold(sessionId: 's1'), isFalse);
      });

      test('warningEmitted starts false', () {
        final monitor = ContextMonitor(warningThreshold: 80);
        expect(monitor.warningEmitted(sessionId: 's1'), isFalse);
      });

      test('uses integer division for percentage calculation', () {
        // 79999 / 100000 = 79.999% → integer 79 — below 80% threshold
        final monitor = ContextMonitor(warningThreshold: 80);
        monitor.update(contextWindow: 100000, contextTokens: 79999);
        expect(monitor.checkThreshold(sessionId: 's1'), isFalse);
      });

      test('respects custom warningThreshold', () {
        final monitor = ContextMonitor(warningThreshold: 90);
        monitor.update(contextWindow: 100000, contextTokens: 89000);
        expect(monitor.checkThreshold(sessionId: 's1'), isFalse);

        monitor.update(contextTokens: 90000);
        expect(monitor.checkThreshold(sessionId: 's1'), isTrue);
      });

      test('warningThreshold can be updated live', () {
        final monitor = ContextMonitor(warningThreshold: 90);
        monitor.update(contextWindow: 100000, contextTokens: 80000);
        expect(monitor.checkThreshold(sessionId: 's1'), isFalse); // 80% < 90%

        monitor.warningThreshold = 75;
        expect(monitor.checkThreshold(sessionId: 's1'), isTrue); // 80% >= 75%
      });

      test('per-session isolation — different sessions fire independently', () {
        final monitor = ContextMonitor(warningThreshold: 80);
        monitor.update(contextWindow: 100000, contextTokens: 85000);

        expect(monitor.checkThreshold(sessionId: 'session-A'), isTrue);
        expect(monitor.checkThreshold(sessionId: 'session-A'), isFalse); // one-shot
        expect(monitor.checkThreshold(sessionId: 'session-B'), isTrue); // independent
        expect(monitor.checkThreshold(sessionId: 'session-B'), isFalse); // one-shot
      });

      test('null sessionId uses default key', () {
        final monitor = ContextMonitor(warningThreshold: 80);
        monitor.update(contextWindow: 100000, contextTokens: 85000);
        expect(monitor.checkThreshold(), isTrue);
        expect(monitor.checkThreshold(), isFalse);
        // Different session is still independent
        expect(monitor.checkThreshold(sessionId: 's1'), isTrue);
      });
    });

    group('compactionSignalAvailable', () {
      test('suppresses shouldFlush when true', () {
        final monitor = ContextMonitor(reserveTokens: 20000);
        monitor.update(contextWindow: 200000, contextTokens: 190000);
        expect(monitor.shouldFlush, isTrue); // would flush without the flag

        monitor.compactionSignalAvailable = true;
        expect(monitor.shouldFlush, isFalse);
      });

      test('false by default — shouldFlush works normally', () {
        final monitor = ContextMonitor(reserveTokens: 20000);
        expect(monitor.compactionSignalAvailable, isFalse);
        monitor.update(contextWindow: 200000, contextTokens: 190000);
        expect(monitor.shouldFlush, isTrue);
      });

      test('can be toggled back to false to re-enable heuristic', () {
        final monitor = ContextMonitor(reserveTokens: 20000);
        monitor.update(contextWindow: 200000, contextTokens: 190000);
        monitor.compactionSignalAvailable = true;
        expect(monitor.shouldFlush, isFalse);

        monitor.compactionSignalAvailable = false;
        expect(monitor.shouldFlush, isTrue);
      });
    });

    group('shouldSkipFlush / markFlushed / onCompactionCompleted', () {
      test('shouldSkipFlush returns false initially (cycle -1 != cycle 0)', () {
        final monitor = ContextMonitor();
        expect(monitor.shouldSkipFlush('hash-abc'), isFalse);
      });

      test('shouldSkipFlush returns true when same cycle already flushed', () {
        final monitor = ContextMonitor();
        monitor.markFlushed('hash-abc');
        // _lastFlushCycleId (0) == _compactionCycleId (0) → skip
        expect(monitor.shouldSkipFlush('hash-abc'), isTrue);
        expect(monitor.shouldSkipFlush('hash-other'), isTrue); // cycle check fires first
      });

      test('shouldSkipFlush returns true for same hash in new cycle (hash dedup)', () {
        final monitor = ContextMonitor();
        monitor.markFlushed('hash-abc');

        monitor.onCompactionCompleted(); // cycle → 1, _lastFlushCycleId = 0
        // Cycle check: 0 != 1, falls through to hash check
        expect(monitor.shouldSkipFlush('hash-abc'), isTrue); // hash dedup
      });

      test('shouldSkipFlush returns false for new hash in new cycle', () {
        final monitor = ContextMonitor();
        monitor.markFlushed('hash-abc');

        monitor.onCompactionCompleted();
        expect(monitor.shouldSkipFlush('hash-new'), isFalse);
      });

      test('onCompactionCompleted starts at 0 and increments', () {
        final monitor = ContextMonitor();
        expect(monitor.compactionCycleId, 0);
        monitor.onCompactionCompleted();
        expect(monitor.compactionCycleId, 1);
        monitor.onCompactionCompleted();
        monitor.onCompactionCompleted();
        expect(monitor.compactionCycleId, 3);
      });

      test('full flush lifecycle: flush → compaction → new flush allowed', () {
        final monitor = ContextMonitor();

        // First flush in cycle 0
        expect(monitor.shouldSkipFlush('hash-1'), isFalse);
        monitor.markFlushed('hash-1');
        expect(monitor.shouldSkipFlush('hash-1'), isTrue); // same cycle

        // Compaction completes → cycle 1
        monitor.onCompactionCompleted();
        expect(monitor.shouldSkipFlush('hash-1'), isTrue); // hash dedup
        expect(monitor.shouldSkipFlush('hash-2'), isFalse); // new hash, new cycle → allow

        // Second flush in cycle 1
        monitor.markFlushed('hash-2');
        expect(monitor.shouldSkipFlush('hash-2'), isTrue); // same cycle

        // Compaction completes → cycle 2
        monitor.onCompactionCompleted();
        expect(monitor.shouldSkipFlush('hash-3'), isFalse); // new hash, new cycle → allow
      });

      test('markFlushed with empty string (fail-open) blocks same cycle', () {
        final monitor = ContextMonitor();
        monitor.markFlushed(''); // fail-open: empty hash recorded
        // cycle dedup: _lastFlushCycleId (0) == _compactionCycleId (0) → skip
        expect(monitor.shouldSkipFlush(''), isTrue);
        expect(monitor.shouldSkipFlush('real-hash'), isTrue); // cycle check fires first

        monitor.onCompactionCompleted();
        // New cycle — only hash dedup applies: '' vs 'real-hash' → allow
        expect(monitor.shouldSkipFlush('real-hash'), isFalse);
      });
    });

    group('usagePercent', () {
      test('returns null with no data', () {
        final monitor = ContextMonitor();
        expect(monitor.usagePercent, isNull);
      });

      test('returns null with only contextWindow', () {
        final monitor = ContextMonitor();
        monitor.update(contextWindow: 100000);
        expect(monitor.usagePercent, isNull);
      });

      test('returns correct percentage', () {
        final monitor = ContextMonitor();
        monitor.update(contextWindow: 100000, contextTokens: 85000);
        expect(monitor.usagePercent, equals(85));
      });

      test('uses integer division', () {
        final monitor = ContextMonitor();
        monitor.update(contextWindow: 100000, contextTokens: 85999);
        expect(monitor.usagePercent, equals(85));
      });
    });
  });
}
