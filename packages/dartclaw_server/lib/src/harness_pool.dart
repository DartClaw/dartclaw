import 'package:logging/logging.dart';

import 'turn_runner.dart';

/// Pool of [TurnRunner] instances for concurrent task execution.
///
/// Runner at index 0 is the "primary" — used exclusively for main chat, cron,
/// and channel turns via [TurnManager]. Runners at indices 1..N-1 form the
/// "task pool" — acquired by [TaskExecutor] for background task execution.
///
/// Task runners can be added lazily via [addRunner] — the pool starts with
/// only the primary runner and grows on demand up to [maxConcurrentTasks].
///
/// When `maxConcurrentTasks == 0`, the pool has only the primary runner and
/// [tryAcquire] always returns null, preserving single-harness sequential
/// behavior.
class HarnessPool {
  static final _log = Logger('HarnessPool');

  final List<TurnRunner> _runners;
  final int _maxConcurrentTasks;
  final Set<TurnRunner> _available = {};
  final Set<TurnRunner> _busy = {};

  HarnessPool({required List<TurnRunner> runners, int? maxConcurrentTasks})
    : assert(runners.isNotEmpty, 'Pool must have at least one runner'),
      _maxConcurrentTasks = maxConcurrentTasks ?? (runners.length - 1),
      _runners = List<TurnRunner>.of(runners) {
    // Indices 1..N-1 start as available task runners.
    for (var i = 1; i < _runners.length; i++) {
      _available.add(_runners[i]);
    }
  }

  /// The primary runner (index 0), used for main chat, cron, and channel turns.
  /// Never acquired by task executor — always available for interactive use.
  TurnRunner get primary => _runners[0];

  /// All runners in the pool, including the primary runner.
  List<TurnRunner> get runners => _runners;

  /// Adds a lazily-spawned task runner to the pool.
  ///
  /// The runner is immediately available for acquisition. Throws if the pool
  /// has already reached [maxConcurrentTasks] task runners.
  void addRunner(TurnRunner runner) {
    final taskRunnerCount = _runners.length - 1;
    if (taskRunnerCount >= _maxConcurrentTasks) {
      throw StateError('Pool already at capacity ($taskRunnerCount/$_maxConcurrentTasks task runners)');
    }
    _runners.add(runner);
    _available.add(runner);
    _log.info('Added task runner (pool: ${_runners.length - 1}/$_maxConcurrentTasks task runners)');
  }

  /// Number of additional task runners that can still be spawned.
  int get spawnableCount => _maxConcurrentTasks - (_runners.length - 1);

  /// Acquires an idle task runner from the pool (indices 1..N-1).
  /// Returns null if all task runners are busy or no task runners exist.
  TurnRunner? tryAcquire() {
    if (_busy.length >= _maxConcurrentTasks) return null;
    if (_available.isEmpty) return null;
    final runner = _available.first;
    _available.remove(runner);
    _busy.add(runner);
    _log.fine('Acquired task runner (busy: ${_busy.length}/$maxConcurrentTasks)');
    return runner;
  }

  /// Acquires an idle task runner matching the given [profileId].
  /// Returns null if no matching runner is available.
  TurnRunner? tryAcquireForProfile(String profileId) {
    if (_busy.length >= _maxConcurrentTasks) return null;
    final runner = _takeMatchingRunner((runner) => runner.profileId == profileId);
    if (runner == null) return null;
    _log.fine('Acquired task runner for profile $profileId (busy: ${_busy.length}/$maxConcurrentTasks)');
    return runner;
  }

  /// Acquires an idle task runner matching the given [providerId].
  /// Returns null if no matching runner is available.
  TurnRunner? tryAcquireForProvider(String providerId) {
    if (_busy.length >= _maxConcurrentTasks) return null;
    final runner = _takeMatchingRunner((runner) => runner.providerId == providerId);
    if (runner == null) return null;
    _log.fine('Acquired task runner for provider $providerId (busy: ${_busy.length}/$maxConcurrentTasks)');
    return runner;
  }

  /// Acquires an idle task runner matching both [providerId] and [profileId].
  /// Returns null if no matching runner is available.
  TurnRunner? tryAcquireForProviderAndProfile(String providerId, String profileId) {
    if (_busy.length >= _maxConcurrentTasks) return null;
    final runner = _takeMatchingRunner((runner) => runner.providerId == providerId && runner.profileId == profileId);
    if (runner == null) return null;
    _log.fine(
      'Acquired task runner for provider $providerId in profile $profileId '
      '(busy: ${_busy.length}/$maxConcurrentTasks)',
    );
    return runner;
  }

  /// Releases a previously acquired runner back to the pool.
  void release(TurnRunner runner) {
    if (!_busy.remove(runner)) {
      _log.warning('Attempted to release a runner that was not busy');
      return;
    }
    _available.add(runner);
    _log.fine('Released task runner (busy: ${_busy.length}/$maxConcurrentTasks)');
  }

  /// Number of runners currently executing task turns.
  int get activeCount => _busy.length;

  /// Number of runners available for task acquisition.
  int get availableCount => _available.length;

  /// Total pool size (including primary).
  int get size => _runners.length;

  /// Maximum concurrent task executions allowed at once.
  int get maxConcurrentTasks => _maxConcurrentTasks;

  /// Returns the pool index of [runner], or -1 if not found.
  int indexOf(TurnRunner runner) => _runners.indexOf(runner);

  /// Returns true when the task pool contains at least one runner for [profileId].
  bool hasTaskRunnerForProfile(String profileId) {
    for (var i = 1; i < _runners.length; i++) {
      if (_runners[i].profileId == profileId) {
        return true;
      }
    }
    return false;
  }

  /// Returns true when the task pool contains at least one runner for [providerId].
  bool hasTaskRunnerForProvider(String providerId) {
    for (var i = 1; i < _runners.length; i++) {
      if (_runners[i].providerId == providerId) {
        return true;
      }
    }
    return false;
  }

  /// Distinct security profiles available among task runners.
  Set<String> get taskProfiles => _runners.skip(1).map((runner) => runner.profileId).toSet();

  /// Distinct provider IDs available among task runners.
  Set<String> get taskProviders => _runners.skip(1).map((runner) => runner.providerId).toSet();

  TurnRunner? _takeMatchingRunner(bool Function(TurnRunner runner) predicate) {
    for (final runner in _available) {
      if (!predicate(runner)) {
        continue;
      }
      _available.remove(runner);
      _busy.add(runner);
      return runner;
    }
    return null;
  }

  /// Graceful shutdown: stops and disposes all runners' harnesses.
  Future<void> dispose() async {
    for (final runner in _runners) {
      try {
        await runner.harness.stop();
      } catch (e) {
        _log.warning('Failed to stop harness during pool dispose', e);
      }
      try {
        await runner.harness.dispose();
      } catch (e) {
        _log.warning('Failed to dispose harness during pool dispose', e);
      }
    }
    _available.clear();
    _busy.clear();
  }
}
