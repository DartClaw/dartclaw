import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

LoopDetectionConfig _config({
  bool enabled = true,
  int maxConsecutiveTurns = 3,
  int maxTokensPerMinute = 1000,
  int velocityWindowMinutes = 2,
  int maxConsecutiveIdenticalToolCalls = 3,
  LoopAction action = LoopAction.abort,
}) => LoopDetectionConfig(
  enabled: enabled,
  maxConsecutiveTurns: maxConsecutiveTurns,
  maxTokensPerMinute: maxTokensPerMinute,
  velocityWindowMinutes: velocityWindowMinutes,
  maxConsecutiveIdenticalToolCalls: maxConsecutiveIdenticalToolCalls,
  action: action,
);

void main() {
  // ── Turn chain depth ──────────────────────────────────────────────────────

  group('LoopDetector — turn chain depth', () {
    test('below threshold → no detection', () {
      final d = LoopDetector(config: _config(maxConsecutiveTurns: 3));
      expect(d.recordTurnStart('s1'), isNull);
      expect(d.recordTurnStart('s1'), isNull);
      expect(d.recordTurnStart('s1'), isNull); // exactly at threshold
    });

    test('exceeds threshold → detection fires', () {
      final d = LoopDetector(config: _config(maxConsecutiveTurns: 3));
      d.recordTurnStart('s1');
      d.recordTurnStart('s1');
      d.recordTurnStart('s1');
      final detection = d.recordTurnStart('s1'); // depth 4 > threshold 3
      expect(detection, isNotNull);
      expect(detection!.mechanism, LoopMechanism.turnChainDepth);
      expect(detection.sessionId, 's1');
      expect(detection.detail['depth'], 4);
      expect(detection.detail['threshold'], 3);
    });

    test('reset on human input → counter resets', () {
      final d = LoopDetector(config: _config(maxConsecutiveTurns: 2));
      d.recordTurnStart('s1');
      d.recordTurnStart('s1');
      // Reset — simulates human input
      d.resetTurnChain('s1');
      // New chain starts from 0
      expect(d.recordTurnStart('s1'), isNull); // depth 1 — no detection
      expect(d.recordTurnStart('s1'), isNull); // depth 2 — at threshold
      final detection = d.recordTurnStart('s1'); // depth 3 > 2
      expect(detection, isNotNull);
    });

    test('threshold 0 → mechanism disabled', () {
      final d = LoopDetector(config: _config(maxConsecutiveTurns: 0));
      for (var i = 0; i < 10; i++) {
        expect(d.recordTurnStart('s1'), isNull);
      }
    });

    test('multiple sessions → independent counters', () {
      final d = LoopDetector(config: _config(maxConsecutiveTurns: 2));
      d.recordTurnStart('s1');
      d.recordTurnStart('s1');
      // s2 chain is independent
      expect(d.recordTurnStart('s2'), isNull);
      // s1 now exceeds
      final detection = d.recordTurnStart('s1');
      expect(detection, isNotNull);
      expect(detection!.sessionId, 's1');
    });

    test('disabled config → all methods return null', () {
      final d = LoopDetector(config: _config(enabled: false));
      for (var i = 0; i < 20; i++) {
        expect(d.recordTurnStart('s1'), isNull);
      }
    });
  });

  // ── Token velocity ────────────────────────────────────────────────────────

  group('LoopDetector — token velocity', () {
    test('within threshold → no detection', () {
      final d = LoopDetector(config: _config(maxTokensPerMinute: 1000, velocityWindowMinutes: 2));
      // Max tokens in window = 1000 * 2 = 2000
      final t = DateTime(2026, 3, 15, 12, 0);
      d.recordTokens('s1', 1000, now: t);
      d.recordTokens('s1', 999, now: t.add(const Duration(seconds: 30)));
      final result = d.checkTokenVelocity('s1', now: t.add(const Duration(seconds: 60)));
      expect(result, isNull); // 1999 ≤ 2000
    });

    test('exceeds threshold → detection fires', () {
      final d = LoopDetector(config: _config(maxTokensPerMinute: 1000, velocityWindowMinutes: 2));
      // Max = 2000 tokens in 2 min window
      final t = DateTime(2026, 3, 15, 12, 0);
      d.recordTokens('s1', 1500, now: t);
      d.recordTokens('s1', 600, now: t.add(const Duration(seconds: 30)));
      final result = d.checkTokenVelocity('s1', now: t.add(const Duration(seconds: 60)));
      expect(result, isNotNull);
      expect(result!.mechanism, LoopMechanism.tokenVelocity);
      expect(result.detail['tokensInWindow'], 2100);
    });

    test('old entries evicted beyond window → not counted', () {
      final d = LoopDetector(config: _config(maxTokensPerMinute: 1000, velocityWindowMinutes: 2));
      // Max = 2000 in 2-min window
      final t0 = DateTime(2026, 3, 15, 12, 0);
      d.recordTokens('s1', 1800, now: t0); // added at t0 — will be outside window by t2
      final t2 = t0.add(const Duration(minutes: 3)); // 3 min later
      d.recordTokens('s1', 100, now: t2); // 100 within window
      // Check at t2: t0 entry is 3 min old, outside the 2-min window
      final result = d.checkTokenVelocity('s1', now: t2);
      expect(result, isNull); // only 100 in window
    });

    test('threshold 0 → mechanism disabled', () {
      final d = LoopDetector(config: _config(maxTokensPerMinute: 0));
      final t = DateTime(2026, 3, 15, 12, 0);
      d.recordTokens('s1', 99999, now: t);
      expect(d.checkTokenVelocity('s1', now: t), isNull);
    });

    test('empty window → no detection', () {
      final d = LoopDetector(config: _config(maxTokensPerMinute: 1000, velocityWindowMinutes: 2));
      expect(d.checkTokenVelocity('s1'), isNull);
    });

    test('injectable now → deterministic time control', () {
      final d = LoopDetector(config: _config(maxTokensPerMinute: 100, velocityWindowMinutes: 1));
      final t = DateTime(2026, 1, 1, 0, 0);
      d.recordTokens('s1', 200, now: t); // 200 > 100*1 = 100 threshold
      final result = d.checkTokenVelocity('s1', now: t.add(const Duration(seconds: 30)));
      expect(result, isNotNull);
    });
  });

  // ── Tool fingerprinting ───────────────────────────────────────────────────

  group('LoopDetector — tool fingerprinting', () {
    test('different tool calls → no detection', () {
      final d = LoopDetector(config: _config(maxConsecutiveIdenticalToolCalls: 3));
      d.recordToolCall('t1', 's1', 'read', {'file': 'a.txt'});
      d.recordToolCall('t1', 's1', 'write', {'file': 'b.txt'});
      final result = d.recordToolCall('t1', 's1', 'bash', {'command': 'ls'});
      expect(result, isNull);
    });

    test('same tool, different args → no detection', () {
      final d = LoopDetector(config: _config(maxConsecutiveIdenticalToolCalls: 3));
      d.recordToolCall('t1', 's1', 'read', {'file': 'a.txt'});
      d.recordToolCall('t1', 's1', 'read', {'file': 'b.txt'});
      final result = d.recordToolCall('t1', 's1', 'read', {'file': 'c.txt'});
      expect(result, isNull);
    });

    test('same tool, same args below threshold → no detection', () {
      final d = LoopDetector(config: _config(maxConsecutiveIdenticalToolCalls: 3));
      d.recordToolCall('t1', 's1', 'bash', {'command': 'ls'});
      d.recordToolCall('t1', 's1', 'bash', {'command': 'ls'}); // count=2
      final result = d.recordToolCall('t1', 's1', 'bash', {'command': 'ls'}); // count=3 ≥ threshold → fires
      expect(result, isNotNull);
      expect(result!.mechanism, LoopMechanism.toolFingerprint);
      expect(result.detail['toolName'], 'bash');
      expect(result.detail['consecutiveCount'], 3);
    });

    test('same tool, same args at threshold → detection fires', () {
      final d = LoopDetector(config: _config(maxConsecutiveIdenticalToolCalls: 2));
      d.recordToolCall('t1', 's1', 'read', {'file': 'a.txt'});
      final result = d.recordToolCall('t1', 's1', 'read', {'file': 'a.txt'}); // count=2 ≥ 2
      expect(result, isNotNull);
    });

    test('args map key ordering does not affect fingerprint', () {
      final d = LoopDetector(config: _config(maxConsecutiveIdenticalToolCalls: 2));
      // Same args, different key insertion order
      d.recordToolCall('t1', 's1', 'bash', {'z': '1', 'a': '2'});
      final result = d.recordToolCall('t1', 's1', 'bash', {'a': '2', 'z': '1'});
      expect(result, isNotNull); // same canonical fingerprint → consecutive = 2 ≥ 2
    });

    test('threshold 0 → mechanism disabled', () {
      final d = LoopDetector(config: _config(maxConsecutiveIdenticalToolCalls: 0));
      for (var i = 0; i < 10; i++) {
        expect(d.recordToolCall('t1', 's1', 'bash', {'cmd': 'ls'}), isNull);
      }
    });

    test('cleanup removes turn state', () {
      final d = LoopDetector(config: _config(maxConsecutiveIdenticalToolCalls: 3));
      d.recordToolCall('t1', 's1', 'bash', {'cmd': 'ls'});
      d.recordToolCall('t1', 's1', 'bash', {'cmd': 'ls'});
      d.cleanupTurn('t1');
      // After cleanup, count resets — same call is count=1
      final result = d.recordToolCall('t1', 's1', 'bash', {'cmd': 'ls'});
      expect(result, isNull); // count=1, not yet at threshold
    });

    test('nested args maps produce stable fingerprints', () {
      final d = LoopDetector(config: _config(maxConsecutiveIdenticalToolCalls: 2));
      final nested = {'outer': {'inner': 'value', 'num': 42}};
      d.recordToolCall('t1', 's1', 'complex', nested);
      final result = d.recordToolCall('t1', 's1', 'complex', {'outer': {'num': 42, 'inner': 'value'}});
      expect(result, isNotNull); // nested keys also sorted → same fingerprint
    });
  });

  // ── Integration ───────────────────────────────────────────────────────────

  group('LoopDetector — integration', () {
    test('all three mechanisms can fire independently', () {
      final d = LoopDetector(config: _config(
        maxConsecutiveTurns: 1,
        maxTokensPerMinute: 10,
        velocityWindowMinutes: 1,
        maxConsecutiveIdenticalToolCalls: 1,
      ));
      final t = DateTime(2026, 3, 15, 12, 0);

      // Mechanism 1: turn chain
      d.recordTurnStart('s1');
      final chainDetection = d.recordTurnStart('s1'); // depth 2 > 1
      expect(chainDetection, isNotNull);

      // Mechanism 2: velocity
      d.recordTokens('s1', 500, now: t);
      final velDetection = d.checkTokenVelocity('s1', now: t); // 500 > 10*1=10
      expect(velDetection, isNotNull);

      // Mechanism 3: fingerprint
      d.recordToolCall('t1', 's1', 'read', {});
      final fpDetection = d.recordToolCall('t1', 's1', 'read', {}); // count=2 ≥ 1+1
      expect(fpDetection, isNotNull);
    });

    test('disabled mechanisms do not interfere with enabled ones', () {
      final d = LoopDetector(config: _config(
        maxConsecutiveTurns: 2,
        maxTokensPerMinute: 0, // velocity disabled
        maxConsecutiveIdenticalToolCalls: 0, // fingerprint disabled
      ));
      // Only turn chain is active
      d.recordTurnStart('s1');
      d.recordTurnStart('s1');
      expect(d.recordTurnStart('s1'), isNotNull); // chain fires
      expect(d.checkTokenVelocity('s1'), isNull); // velocity disabled
      expect(d.recordToolCall('t1', 's1', 'bash', {}), isNull); // fp disabled
    });

    test('reset() clears all state', () {
      final d = LoopDetector(config: _config());
      d.recordTurnStart('s1');
      d.recordTurnStart('s1');
      d.recordTokens('s1', 5000);
      d.recordToolCall('t1', 's1', 'bash', {});

      d.reset();

      // After reset, all counters are zero — mechanisms don't fire
      expect(d.recordTurnStart('s1'), isNull); // depth 1
      expect(d.checkTokenVelocity('s1'), isNull); // window empty
      expect(d.recordToolCall('t1', 's1', 'bash', {}), isNull); // count 1
    });

    test('cleanupSession removes session-specific state', () {
      final d = LoopDetector(config: _config(maxConsecutiveTurns: 2));
      d.recordTurnStart('s1');
      d.recordTurnStart('s1');
      d.cleanupSession('s1');
      // After cleanup, chain is gone — no detection on next recordTurnStart
      expect(d.recordTurnStart('s1'), isNull); // depth 1
    });
  });
}
