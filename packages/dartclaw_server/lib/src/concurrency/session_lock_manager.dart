import 'dart:async';

import '../turn_manager.dart';

/// Per-session Completer-based locks with a global concurrency cap.
///
/// Prevents concurrent turns on the same session and limits overall parallel
/// turn count across all sessions. Same-session requests queue behind the
/// active turn instead of failing.
class SessionLockManager {
  final int maxParallel;
  final Map<String, Completer<void>> _locks = {};
  int _activeCount = 0;

  SessionLockManager({this.maxParallel = 3});

  /// Acquires a lock for [sessionId].
  ///
  /// If the session is already locked, waits for the existing lock to release,
  /// then acquires. Throws [BusyTurnException] if global cap is reached.
  Future<void> acquire(String sessionId) async {
    // Wait for existing same-session lock to release
    while (_locks.containsKey(sessionId)) {
      await _locks[sessionId]!.future;
    }
    // Check global cap after waiting
    if (_activeCount >= maxParallel) {
      throw BusyTurnException(
        'Global concurrency limit reached ($maxParallel)',
        isSameSession: false,
      );
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
  }

  /// Whether [sessionId] currently has an active lock.
  bool isLocked(String sessionId) => _locks.containsKey(sessionId);

  /// Number of currently active locks.
  int get activeCount => _activeCount;
}
