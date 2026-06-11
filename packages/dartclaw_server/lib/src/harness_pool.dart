import 'package:dartclaw_core/dartclaw_core.dart' as core show HarnessPool, TurnRunner;
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
class HarnessPool implements core.HarnessPool {
  static final _log = Logger('HarnessPool');

  final List<TurnRunner> _runners;
  int _maxConcurrentTasks;
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
  @override
  TurnRunner get primary => _runners[0];

  /// All runners in the pool, including the primary runner.
  @override
  List<TurnRunner> get runners => _runners;

  /// Adds a lazily-spawned task runner to the pool.
  ///
  /// The runner is immediately available for acquisition. Throws if the pool
  /// has already reached [maxConcurrentTasks] task runners.
  @override
  void addRunner(core.TurnRunner runner) {
    final taskRunnerCount = _runners.length - 1;
    if (taskRunnerCount >= _maxConcurrentTasks) {
      throw StateError('Pool already at capacity ($taskRunnerCount/$_maxConcurrentTasks task runners)');
    }
    final concrete = runner as TurnRunner;
    _runners.add(concrete);
    _available.add(concrete);
    _log.info('Added task runner (pool: ${_runners.length - 1}/$_maxConcurrentTasks task runners)');
  }

  /// Current number of task runners (excludes the primary runner).
  int get taskRunnerCount => _runners.length - 1;

  /// Raises the task-runner capacity ceiling to at least [minCapacity];
  /// never lowers it.
  ///
  /// The initial capacity is sized from config, but standalone workflow
  /// execution may need to provision runners for a provider a workflow step
  /// requests beyond that sizing (e.g. a `provider: claude` step under a
  /// codex-default config). Growing the ceiling lets those runners be added.
  void ensureCapacity(int minCapacity) {
    if (minCapacity > _maxConcurrentTasks) {
      _maxConcurrentTasks = minCapacity;
    }
  }

  /// Number of additional task runners that can still be spawned.
  @override
  int get spawnableCount => _maxConcurrentTasks - (_runners.length - 1);

  /// Acquires an idle task runner from the pool (indices 1..N-1).
  /// Returns null if all task runners are busy or no task runners exist.
  @override
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
  @override
  TurnRunner? tryAcquireForProfile(String profileId) {
    if (_busy.length >= _maxConcurrentTasks) return null;
    final runner = _takeMatchingRunner((runner) => runner.profileId == profileId);
    if (runner == null) return null;
    _log.fine('Acquired task runner for profile $profileId (busy: ${_busy.length}/$maxConcurrentTasks)');
    return runner;
  }

  /// Acquires an idle task runner matching the given [providerId].
  /// Returns null if no matching runner is available.
  @override
  TurnRunner? tryAcquireForProvider(String providerId) {
    final runner = _takeMatchingRunner((runner) => runner.providerId == providerId);
    if (runner == null) return null;
    _log.fine(
      'Acquired task runner for provider $providerId '
      '(provider busy: ${_busyForProvider(providerId)}/${_taskRunnerCountForProvider(providerId)}, '
      'total busy: ${_busy.length}/$maxConcurrentTasks)',
    );
    return runner;
  }

  /// Acquires an idle task runner matching both [providerId] and [profileId].
  /// Returns null if no matching runner is available.
  @override
  TurnRunner? tryAcquireForProviderAndProfile(String providerId, String profileId) {
    final runner = _takeMatchingRunner((runner) => runner.providerId == providerId && runner.profileId == profileId);
    if (runner == null) return null;
    _log.fine(
      'Acquired task runner for provider $providerId in profile $profileId '
      '(provider busy: ${_busyForProvider(providerId)}/${_taskRunnerCountForProvider(providerId)}, '
      'total busy: ${_busy.length}/$maxConcurrentTasks)',
    );
    return runner;
  }

  /// Releases a previously acquired runner back to the pool.
  @override
  void release(core.TurnRunner runner) {
    final concrete = runner as TurnRunner;
    if (!_busy.remove(concrete)) {
      _log.warning('Attempted to release a runner that was not busy');
      return;
    }
    _available.add(concrete);
    _log.fine('Released task runner (busy: ${_busy.length}/$maxConcurrentTasks)');
  }

  /// Number of runners currently executing task turns.
  @override
  int get activeCount => _busy.length;

  /// Number of runners available for task acquisition.
  @override
  int get availableCount => _available.length;

  /// Total pool size (including primary).
  @override
  int get size => _runners.length;

  /// Maximum concurrent task executions allowed at once.
  @override
  int get maxConcurrentTasks => _maxConcurrentTasks;

  /// Returns the pool index of [runner], or -1 if not found.
  @override
  int indexOf(core.TurnRunner runner) => _runners.indexOf(runner as TurnRunner);

  /// Returns true when the task pool contains at least one runner for [profileId].
  @override
  bool hasTaskRunnerForProfile(String profileId) {
    for (var i = 1; i < _runners.length; i++) {
      if (_runners[i].profileId == profileId) {
        return true;
      }
    }
    return false;
  }

  /// Returns true when the task pool contains at least one runner for [providerId].
  @override
  bool hasTaskRunnerForProvider(String providerId) {
    return taskRunnerCountForProvider(providerId) > 0;
  }

  @override
  int taskRunnerCountForProvider(String providerId) => _taskRunnerCountForProvider(providerId);

  /// Distinct security profiles available among task runners.
  @override
  Set<String> get taskProfiles => _runners.skip(1).map((runner) => runner.profileId).toSet();

  /// Distinct provider IDs available among task runners.
  @override
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

  int _busyForProvider(String providerId) => _busy.where((runner) => runner.providerId == providerId).length;

  int _taskRunnerCountForProvider(String providerId) =>
      _runners.skip(1).where((runner) => runner.providerId == providerId).length;

  /// Graceful shutdown: stops and disposes all runners' harnesses.
  @override
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
