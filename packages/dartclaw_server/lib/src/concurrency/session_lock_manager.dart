import 'dart:async';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show BusyTurnException;
import 'package:logging/logging.dart';

/// Per-session Completer-based locks with a global concurrency cap.
///
/// Prevents concurrent turns on the same session and limits overall parallel
/// turn count across all sessions. Same-session requests queue behind the
/// active turn instead of failing.
class SessionLockManager implements Reconfigurable {
  static final _log = Logger('SessionLockManager');

  int _maxParallel;
  final Map<String, Completer<void>> _locks = {};
  final Map<String, _WaitEntry> _waits = {};
  int _activeCount = 0;

  SessionLockManager({int maxParallel = 3}) : _maxParallel = maxParallel;

  int get maxParallel => _maxParallel;

  @override
  Set<String> get watchKeys => const {'server.*'};

  @override
  void reconfigure(ConfigDelta delta) {
    final newMax = delta.current.server.maxParallelTurns;
    if (newMax == _maxParallel) return;
    _maxParallel = newMax;
    _log.info('SessionLockManager maxParallel updated to $_maxParallel');
  }

  /// Acquires a lock for [sessionId].
  ///
  /// If the session is already locked, waits for the existing lock to release,
  /// then acquires. Throws [BusyTurnException] if global cap is reached.
  Future<void> acquire(
    String sessionId, {
    Duration? waitWarningAfter,
    Duration? stuckAfter,
    void Function()? onWaiting,
    void Function()? onStuck,
  }) async {
    // Wait for existing same-session lock to release
    while (_locks.containsKey(sessionId)) {
      final waitEntry = _waits.putIfAbsent(sessionId, () {
        _log.info('Session $sessionId is waiting on an active turn lock');
        final entry = _WaitEntry(waitingSince: DateTime.now());
        final warningAfter = waitWarningAfter;
        if (warningAfter != null && warningAfter > Duration.zero) {
          entry.waitingTimer = Timer(warningAfter, () {
            entry.warningVisibleAt = DateTime.now();
            onWaiting?.call();
          });
        }
        final stuckDelay = stuckAfter;
        if (stuckDelay != null && stuckDelay > Duration.zero) {
          entry.stuckTimer = Timer(stuckDelay, () {
            entry.stuckSince = DateTime.now();
            onStuck?.call();
          });
        }
        return entry;
      });
      if (waitWarningAfter == null || waitWarningAfter <= Duration.zero) {
        waitEntry.warningVisibleAt ??= waitEntry.waitingSince;
      }
      await _locks[sessionId]!.future;
    }
    _clearWait(sessionId);
    // Check global cap after waiting
    if (_activeCount >= _maxParallel) {
      throw BusyTurnException('Global concurrency limit reached ($_maxParallel)', isSameSession: false);
    }
    _locks[sessionId] = Completer<void>();
    _activeCount++;
  }

  /// Releases the lock for [sessionId].
  void release(String sessionId) {
    final completer = _locks.remove(sessionId);
    if (completer != null) {
      _activeCount--;
      if (!completer.isCompleted) completer.complete();
    }
    _clearWait(sessionId);
  }

  /// Whether [sessionId] currently has an active lock.
  bool isLocked(String sessionId) => _locks.containsKey(sessionId);

  /// Number of currently active locks.
  int get activeCount => _activeCount;

  SessionLockWaitSnapshot? waitSnapshot(String sessionId) {
    final entry = _waits[sessionId];
    if (entry == null) return null;
    return SessionLockWaitSnapshot(
      waitingSince: entry.waitingSince,
      warningVisibleAt: entry.warningVisibleAt,
      stuckSince: entry.stuckSince,
    );
  }

  void _clearWait(String sessionId) {
    final entry = _waits.remove(sessionId);
    entry?.waitingTimer?.cancel();
    entry?.stuckTimer?.cancel();
  }
}

class SessionLockWaitSnapshot {
  final DateTime waitingSince;
  final DateTime? warningVisibleAt;
  final DateTime? stuckSince;

  const SessionLockWaitSnapshot({required this.waitingSince, this.warningVisibleAt, this.stuckSince});
}

class _WaitEntry {
  final DateTime waitingSince;
  DateTime? warningVisibleAt;
  DateTime? stuckSince;
  Timer? waitingTimer;
  Timer? stuckTimer;

  _WaitEntry({required this.waitingSince});
}
