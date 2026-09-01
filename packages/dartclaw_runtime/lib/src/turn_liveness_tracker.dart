import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';

import 'concurrency/session_lock_manager.dart';

final class TurnLivenessTracker {
  static const _defaultWaiting = Duration(seconds: 30);
  static const _defaultStuck = Duration(seconds: 120);

  final Duration stallTimeout;
  final SessionLockTimerFactory timerFactory;
  final SessionLockNow now;
  final void Function() onWaiting;
  final void Function() onStuck;
  final void Function(Duration timeout) onStall;

  Timer? _waitingTimer;
  Timer? _stuckTimer;
  Timer? _stallTimer;
  TurnLivenessSnapshot _snapshot;

  new({
    required this.stallTimeout,
    required this.timerFactory,
    required this.now,
    required TurnWaitReason initialReason,
    required this.onWaiting,
    required this.onStuck,
    required this.onStall,
  }) : _snapshot = TurnLivenessSnapshot(waitingSince: now(), reason: initialReason) {
    _schedule();
  }

  TurnLivenessSnapshot get snapshot => _snapshot;

  void recordActivity(TurnWaitReason reason) {
    _cancelTimers();
    _snapshot = TurnLivenessSnapshot(waitingSince: now(), reason: reason);
    _schedule();
  }

  void dispose() => _cancelTimers();

  void _schedule() {
    final stuckCeiling = stallTimeout > Duration.zero ? stallTimeout - const Duration(microseconds: 1) : _defaultStuck;
    final stuckAfter = stuckCeiling.isNegative
        ? Duration.zero
        : stuckCeiling < _defaultStuck
        ? stuckCeiling
        : _defaultStuck;
    final waitingCeiling = stuckAfter - const Duration(microseconds: 1);
    final waitWarningAfter = waitingCeiling.isNegative
        ? Duration.zero
        : waitingCeiling < _defaultWaiting
        ? waitingCeiling
        : _defaultWaiting;

    _waitingTimer = timerFactory(waitWarningAfter, () {
      _snapshot = _snapshot.copyWith(warningVisibleAt: now());
      onWaiting();
    });
    _stuckTimer = timerFactory(stuckAfter, () {
      _snapshot = _snapshot.copyWith(stuckSince: now());
      onStuck();
    });
    if (stallTimeout > Duration.zero && _snapshot.reason != TurnWaitReason.toolApproval) {
      _stallTimer = timerFactory(stallTimeout, () => onStall(stallTimeout));
    }
  }

  void _cancelTimers() {
    _waitingTimer?.cancel();
    _stuckTimer?.cancel();
    _stallTimer?.cancel();
  }
}

final class TurnLivenessSnapshot {
  final DateTime waitingSince;
  final DateTime? warningVisibleAt;
  final DateTime? stuckSince;
  final TurnWaitReason reason;

  const new({required this.waitingSince, required this.reason, this.warningVisibleAt, this.stuckSince});

  TurnLivenessSnapshot copyWith({DateTime? warningVisibleAt, DateTime? stuckSince}) {
    return TurnLivenessSnapshot(
      waitingSince: waitingSince,
      reason: reason,
      warningVisibleAt: warningVisibleAt ?? this.warningVisibleAt,
      stuckSince: stuckSince ?? this.stuckSince,
    );
  }
}
