import 'dart:async';
import 'dart:collection';

/// Bounds concurrent executions independently from reusable worker state.
final class WorkerCapacityGate {
  WorkerCapacityGate(this.configuredCapacity) {
    if (configuredCapacity < 1) {
      throw ArgumentError.value(configuredCapacity, 'configuredCapacity', 'must be positive');
    }
  }

  final int configuredCapacity;
  final Queue<Completer<WorkerCapacityPermit>> _waiters = Queue<Completer<WorkerCapacityPermit>>();
  var _activeCount = 0;
  var _quarantinedCount = 0;
  var _closed = false;

  int get activeCount => _activeCount;
  int get queuedCount => _waiters.length;
  int get quarantinedCount => _quarantinedCount;
  int get effectiveCapacity => configuredCapacity - _quarantinedCount;
  int get availableCount => effectiveCapacity - _activeCount;

  WorkerCapacityPermit? tryAcquire() {
    if (_closed || _waiters.isNotEmpty || availableCount <= 0) {
      return null;
    }
    _activeCount++;
    return WorkerCapacityPermit._(this);
  }

  Future<WorkerCapacityPermit> acquire() {
    if (_closed) {
      return Future<WorkerCapacityPermit>.error(StateError('Worker capacity gate is closed'));
    }
    if (effectiveCapacity == 0) {
      return Future<WorkerCapacityPermit>.error(
        StateError('Worker capacity is unavailable because all slots are quarantined'),
      );
    }
    if (_waiters.isEmpty && availableCount > 0) {
      _activeCount++;
      return Future<WorkerCapacityPermit>.value(WorkerCapacityPermit._(this));
    }
    final waiter = Completer<WorkerCapacityPermit>();
    _waiters.add(waiter);
    return waiter.future;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    while (_waiters.isNotEmpty) {
      _waiters.removeFirst().completeError(StateError('Worker capacity gate is closed'));
    }
  }

  void _release({required bool quarantine}) {
    if (_activeCount <= 0) {
      throw StateError('Worker capacity permit released without an active execution');
    }
    _activeCount--;
    if (quarantine) {
      _quarantinedCount++;
    }
    if (effectiveCapacity == 0) {
      while (_waiters.isNotEmpty) {
        _waiters.removeFirst().completeError(
          StateError('Worker capacity is unavailable because all slots are quarantined'),
        );
      }
      return;
    }
    _drainWaiters();
  }

  void _drainWaiters() {
    if (_closed) return;
    while (_waiters.isNotEmpty && availableCount > 0) {
      _activeCount++;
      _waiters.removeFirst().complete(WorkerCapacityPermit._(this));
    }
  }
}

/// Idempotent ownership token returned by [WorkerCapacityGate].
final class WorkerCapacityPermit {
  WorkerCapacityPermit._(this._gate);

  final WorkerCapacityGate _gate;
  var _released = false;

  void release() => _finish(quarantine: false);

  void quarantine() => _finish(quarantine: true);

  void _finish({required bool quarantine}) {
    if (_released) return;
    _released = true;
    _gate._release(quarantine: quarantine);
  }
}
