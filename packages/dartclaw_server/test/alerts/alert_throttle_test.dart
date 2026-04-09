import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/alerts/alert_throttle.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

const _target0 = AlertTarget(channel: 'whatsapp', recipient: '+1000');
const _target1 = AlertTarget(channel: 'signal', recipient: '+2000');

void main() {
  group('AlertThrottle — basic cooldown', () {
    test('first call to shouldDeliver returns true', () {
      final throttle = AlertThrottle(cooldown: const Duration(minutes: 5), burstThreshold: 5, onSummary: (_, _, _) {});
      expect(throttle.shouldDeliver('guard_block', _target0), isTrue);
      throttle.dispose();
    });

    test('second call within cooldown returns false', () {
      fakeAsync((async) {
        final throttle = AlertThrottle(
          cooldown: const Duration(minutes: 5),
          burstThreshold: 5,
          onSummary: (_, _, _) {},
        );
        expect(throttle.shouldDeliver('guard_block', _target0), isTrue);
        async.elapse(const Duration(seconds: 30));
        expect(throttle.shouldDeliver('guard_block', _target0), isFalse);
        throttle.dispose();
      });
    });

    test('call after cooldown expiry starts a new cycle', () {
      fakeAsync((async) {
        final throttle = AlertThrottle(
          cooldown: const Duration(minutes: 5),
          burstThreshold: 5,
          onSummary: (_, _, _) {},
        );
        expect(throttle.shouldDeliver('guard_block', _target0), isTrue);
        // Suppress one event to create a timer entry
        throttle.shouldDeliver('guard_block', _target0);
        // Advance past cooldown — timer fires, entry removed
        async.elapse(const Duration(minutes: 5, seconds: 1));
        // New cycle: should deliver again
        expect(throttle.shouldDeliver('guard_block', _target0), isTrue);
        throttle.dispose();
      });
    });

    test('delivered-only entry expires before the next isolated alert', () {
      fakeAsync((async) {
        final throttle = AlertThrottle(
          cooldown: const Duration(minutes: 5),
          burstThreshold: 5,
          onSummary: (_, _, _) {},
        );
        final start = DateTime(2026, 4, 9, 12, 0);

        expect(throttle.shouldDeliver('guard_block', _target0, now: start), isTrue);

        async.elapse(const Duration(minutes: 6));

        expect(throttle.shouldDeliver('guard_block', _target0, now: start.add(const Duration(minutes: 6))), isTrue);
        throttle.dispose();
      });
    });
  });

  group('AlertThrottle — burst summary', () {
    test('6 events with burstThreshold=5 triggers summary with count=5', () {
      fakeAsync((async) {
        final summaries = <(String, AlertTarget, int)>[];
        final throttle = AlertThrottle(
          cooldown: const Duration(minutes: 5),
          burstThreshold: 5,
          onSummary: (type, target, count) => summaries.add((type, target, count)),
        );

        // First event delivered immediately
        expect(throttle.shouldDeliver('guard_block', _target0), isTrue);
        // 5 suppressed events
        for (var i = 0; i < 5; i++) {
          throttle.shouldDeliver('guard_block', _target0);
        }

        expect(summaries, isEmpty); // not yet

        async.elapse(const Duration(minutes: 5, seconds: 1));

        expect(summaries, hasLength(1));
        expect(summaries.first.$1, 'guard_block');
        expect(summaries.first.$2, _target0);
        expect(summaries.first.$3, 5);
        throttle.dispose();
      });
    });

    test('below burst threshold — no summary delivered', () {
      fakeAsync((async) {
        final summaries = <(String, AlertTarget, int)>[];
        final throttle = AlertThrottle(
          cooldown: const Duration(minutes: 5),
          burstThreshold: 5,
          onSummary: (type, target, count) => summaries.add((type, target, count)),
        );

        // First delivered, then 3 suppressed (below threshold of 5)
        throttle.shouldDeliver('guard_block', _target0);
        throttle.shouldDeliver('guard_block', _target0);
        throttle.shouldDeliver('guard_block', _target0);
        throttle.shouldDeliver('guard_block', _target0);

        async.elapse(const Duration(minutes: 5, seconds: 1));

        expect(summaries, isEmpty);
        throttle.dispose();
      });
    });

    test('exactly burstThreshold suppressed events triggers summary', () {
      fakeAsync((async) {
        final summaries = <(String, AlertTarget, int)>[];
        final throttle = AlertThrottle(
          cooldown: const Duration(minutes: 5),
          burstThreshold: 3,
          onSummary: (type, target, count) => summaries.add((type, target, count)),
        );

        throttle.shouldDeliver('guard_block', _target0); // delivered
        throttle.shouldDeliver('guard_block', _target0); // suppressed #1
        throttle.shouldDeliver('guard_block', _target0); // suppressed #2
        throttle.shouldDeliver('guard_block', _target0); // suppressed #3 (= threshold)

        async.elapse(const Duration(minutes: 5, seconds: 1));

        expect(summaries, hasLength(1));
        expect(summaries.first.$3, 3);
        throttle.dispose();
      });
    });

    test('single event with no follow-ups does not trigger summary', () {
      fakeAsync((async) {
        final summaries = <(String, AlertTarget, int)>[];
        final throttle = AlertThrottle(
          cooldown: const Duration(minutes: 5),
          burstThreshold: 5,
          onSummary: (type, target, count) => summaries.add((type, target, count)),
        );

        throttle.shouldDeliver('guard_block', _target0);
        // No timer started — no cooldown expiry to advance

        async.elapse(const Duration(minutes: 10));
        expect(summaries, isEmpty);
        throttle.dispose();
      });
    });
  });

  group('AlertThrottle — per-key independence', () {
    test('different event types to same target throttled independently', () {
      fakeAsync((async) {
        final summaries = <(String, AlertTarget, int)>[];
        final throttle = AlertThrottle(
          cooldown: const Duration(minutes: 5),
          burstThreshold: 5,
          onSummary: (type, target, count) => summaries.add((type, target, count)),
        );

        // guard_block to _target0: deliver first
        expect(throttle.shouldDeliver('guard_block', _target0), isTrue);
        // container_crash to _target0: still a new key — deliver first
        expect(throttle.shouldDeliver('container_crash', _target0), isTrue);
        // guard_block to _target0 again: suppressed
        expect(throttle.shouldDeliver('guard_block', _target0), isFalse);
        // container_crash to _target0 again: suppressed
        expect(throttle.shouldDeliver('container_crash', _target0), isFalse);

        throttle.dispose();
      });
    });

    test('same event type to different targets throttled independently', () {
      fakeAsync((async) {
        final summaries = <(String, AlertTarget, int)>[];
        final throttle = AlertThrottle(
          cooldown: const Duration(minutes: 5),
          burstThreshold: 5,
          onSummary: (type, target, count) => summaries.add((type, target, count)),
        );

        // Both targets get first delivery
        expect(throttle.shouldDeliver('guard_block', _target0), isTrue);
        expect(throttle.shouldDeliver('guard_block', _target1), isTrue);
        // Both suppressed on second
        expect(throttle.shouldDeliver('guard_block', _target0), isFalse);
        expect(throttle.shouldDeliver('guard_block', _target1), isFalse);

        throttle.dispose();
      });
    });

    test('throttle state of one key does not affect another key summary', () {
      fakeAsync((async) {
        final summaries = <(String, AlertTarget, int)>[];
        final throttle = AlertThrottle(
          cooldown: const Duration(minutes: 5),
          burstThreshold: 2,
          onSummary: (type, target, count) => summaries.add((type, target, count)),
        );

        // _target0: 1 delivered + 2 suppressed (≥ threshold → summary expected)
        throttle.shouldDeliver('guard_block', _target0);
        throttle.shouldDeliver('guard_block', _target0);
        throttle.shouldDeliver('guard_block', _target0);

        // _target1: only 1 event (no suppression → no summary)
        throttle.shouldDeliver('guard_block', _target1);

        async.elapse(const Duration(minutes: 5, seconds: 1));

        expect(summaries, hasLength(1));
        expect(summaries.first.$2, _target0);
        throttle.dispose();
      });
    });
  });

  group('AlertThrottle — timer lifecycle', () {
    test('timer not started on first event (no suppression)', () {
      fakeAsync((async) {
        var summaryCalled = false;
        final throttle = AlertThrottle(
          cooldown: const Duration(minutes: 5),
          burstThreshold: 5,
          onSummary: (_, _, _) => summaryCalled = true,
        );
        throttle.shouldDeliver('guard_block', _target0);
        // No second event — no timer should exist
        async.elapse(const Duration(minutes: 10));
        expect(summaryCalled, isFalse);
        expect(async.pendingTimers, isEmpty);
        throttle.dispose();
      });
    });

    test('entry cleaned up after timer fires', () {
      fakeAsync((async) {
        final throttle = AlertThrottle(
          cooldown: const Duration(minutes: 5),
          burstThreshold: 5,
          onSummary: (_, _, _) {},
        );
        throttle.shouldDeliver('guard_block', _target0);
        throttle.shouldDeliver('guard_block', _target0); // starts timer

        async.elapse(const Duration(minutes: 5, seconds: 1));
        // Entry gone — next call starts a new cycle
        expect(throttle.shouldDeliver('guard_block', _target0), isTrue);
        throttle.dispose();
      });
    });

    test('dispose cancels pending timers — no summary delivered', () {
      fakeAsync((async) {
        final summaries = <int>[];
        final throttle = AlertThrottle(
          cooldown: const Duration(minutes: 5),
          burstThreshold: 2,
          onSummary: (_, _, count) => summaries.add(count),
        );

        throttle.shouldDeliver('guard_block', _target0);
        throttle.shouldDeliver('guard_block', _target0);
        throttle.shouldDeliver('guard_block', _target0); // suppressedCount=2

        throttle.dispose(); // cancels timer

        async.elapse(const Duration(minutes: 5, seconds: 1));
        expect(summaries, isEmpty);
      });
    });
  });

  group('AlertThrottle — reconfigure', () {
    test('reconfigure applies new cooldown to subsequent cycles', () {
      fakeAsync((async) {
        final summaries = <int>[];
        final throttle = AlertThrottle(
          cooldown: const Duration(minutes: 10),
          burstThreshold: 5,
          onSummary: (_, _, count) => summaries.add(count),
        );

        // First cycle with original cooldown
        throttle.shouldDeliver('guard_block', _target0);
        throttle.shouldDeliver('guard_block', _target0); // starts timer (10 min)

        async.elapse(const Duration(minutes: 10, seconds: 1)); // original timer fires
        // Entry removed — reconfigure for new cycle
        throttle.reconfigure(const Duration(minutes: 2), 5);

        // New cycle with shorter cooldown
        throttle.shouldDeliver('guard_block', _target0);
        throttle.shouldDeliver('guard_block', _target0);
        throttle.shouldDeliver('guard_block', _target0);
        throttle.shouldDeliver('guard_block', _target0);
        throttle.shouldDeliver('guard_block', _target0);
        throttle.shouldDeliver('guard_block', _target0); // 5 suppressed ≥ threshold

        async.elapse(const Duration(minutes: 2, seconds: 1)); // new cooldown
        expect(summaries, hasLength(1)); // from the second cycle (5 suppressed)
        throttle.dispose();
      });
    });

    test('active entry timers not interrupted by reconfigure', () {
      fakeAsync((async) {
        final summaries = <int>[];
        final throttle = AlertThrottle(
          cooldown: const Duration(minutes: 5),
          burstThreshold: 5,
          onSummary: (_, _, count) => summaries.add(count),
        );

        throttle.shouldDeliver('guard_block', _target0);
        throttle.shouldDeliver('guard_block', _target0);
        throttle.shouldDeliver('guard_block', _target0);
        throttle.shouldDeliver('guard_block', _target0);
        throttle.shouldDeliver('guard_block', _target0);
        throttle.shouldDeliver('guard_block', _target0); // 5 suppressed, timer running

        // Reconfigure after timer is already running
        throttle.reconfigure(const Duration(minutes: 1), 5);

        // Original timer still fires at 5 min (not 1 min)
        async.elapse(const Duration(minutes: 1, seconds: 1));
        expect(summaries, isEmpty); // timer not yet fired with original schedule

        async.elapse(const Duration(minutes: 4)); // total ~5:01
        expect(summaries, hasLength(1));
        throttle.dispose();
      });
    });
  });
}
