import 'dart:async';

import 'package:dartclaw_runtime/src/turn_liveness_tracker.dart';
import 'package:dartclaw_runtime/src/turn_wait_status.dart';
import 'package:test/test.dart';

class _ManualTimer implements Timer {
  new(this.duration, this._callback);

  final Duration duration;
  final void Function() _callback;
  bool _active = true;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;

  @override
  void cancel() => _active = false;

  void fire() {
    if (!_active) return;
    _active = false;
    _callback();
  }
}

void main() {
  test('approval wait suspends stall clock', () {
    final timers = <_ManualTimer>[];
    var stalls = 0;
    final tracker = TurnLivenessTracker(
      stallTimeout: const Duration(seconds: 2),
      timerFactory: (duration, callback) {
        final timer = _ManualTimer(duration, callback);
        timers.add(timer);
        return timer;
      },
      now: DateTime.now,
      initialReason: TurnWaitReason.unknown,
      onWaiting: () {},
      onStuck: () {},
      onStall: (_) => stalls++,
    );

    tracker.recordActivity(TurnWaitReason.toolApproval);
    for (final timer in timers.where((timer) => timer.duration == const Duration(seconds: 2))) {
      timer.fire();
    }
    expect(stalls, 0);

    tracker.recordActivity(TurnWaitReason.unknown);
    timers.lastWhere((timer) => timer.duration == const Duration(seconds: 2) && timer.isActive).fire();
    expect(stalls, 1);
    tracker.dispose();
  });
}
