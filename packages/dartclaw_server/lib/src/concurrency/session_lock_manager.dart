import 'dart:async';

import '../turn_manager.dart';

/// Per-session Completer-based locks with a global concurrency cap.
///
/// Prevents concurrent turns on the same session and limits overall parallel
/// turn count across all sessions.
class SessionLockManager {
  final int maxParallel;
  final Map<String, Completer<void>> _locks = {};
  int _activeCount = 0;

  SessionLockManager({this.maxParallel = 3});

  /// Acquires a lock for [sessionId].
  ///
  /// Throws [BusyTurnException] if the session is already locked (same session)
  /// or global cap is reached (different session busy).
  void acquire(String sessionId) {
    if (_locks.containsKey(sessionId)) {
      throw BusyTurnException(
        'Session $sessionId already has an active turn',
        isSameSession: true,
      );
    }
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
