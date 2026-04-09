import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

import '../turn_manager.dart';

/// Per-session Completer-based locks with a global concurrency cap.
///
/// Prevents concurrent turns on the same session and limits overall parallel
/// turn count across all sessions. Same-session requests queue behind the
/// active turn instead of failing.
class SessionLockManager implements Reconfigurable {
  static final _log = Logger('SessionLockManager');

  int _maxParallel;
  final Map<String, Completer<void>> _locks = {};
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
  Future<void> acquire(String sessionId) async {
    // Wait for existing same-session lock to release
    while (_locks.containsKey(sessionId)) {
      await _locks[sessionId]!.future;
    }
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
  }

  /// Whether [sessionId] currently has an active lock.
  bool isLocked(String sessionId) => _locks.containsKey(sessionId);

  /// Number of currently active locks.
  int get activeCount => _activeCount;
}
