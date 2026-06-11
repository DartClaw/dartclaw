import '../turn/turn_runner.dart';

/// Pool of [TurnRunner] instances for concurrent task execution.
///
/// Runner at index 0 is the "primary" — used exclusively for main chat, cron,
/// and channel turns. Runners at indices 1..N-1 form the "task pool" —
/// acquired by the task executor for background task execution.
abstract interface class HarnessPool {
  /// The primary runner (index 0), used for main chat, cron, and channel turns.
  TurnRunner get primary;

  /// All runners in the pool, including the primary runner.
  List<TurnRunner> get runners;

  /// Adds a lazily-spawned task runner to the pool.
  void addRunner(TurnRunner runner);

  /// Number of additional task runners that can still be spawned.
  int get spawnableCount;

  /// Acquires an idle task runner from the pool (indices 1..N-1).
  /// Returns null if all task runners are busy or no task runners exist.
  TurnRunner? tryAcquire();

  /// Acquires an idle task runner matching the given [profileId].
  TurnRunner? tryAcquireForProfile(String profileId);

  /// Acquires an idle task runner matching the given [providerId].
  TurnRunner? tryAcquireForProvider(String providerId);

  /// Acquires an idle task runner matching both [providerId] and [profileId].
  TurnRunner? tryAcquireForProviderAndProfile(String providerId, String profileId);

  /// Releases a previously acquired runner back to the pool.
  void release(TurnRunner runner);

  /// Number of runners currently executing task turns.
  int get activeCount;

  /// Number of runners available for task acquisition.
  int get availableCount;

  /// Total pool size (including primary).
  int get size;

  /// Maximum concurrent task executions allowed at once.
  int get maxConcurrentTasks;

  /// Returns the pool index of [runner], or -1 if not found.
  int indexOf(TurnRunner runner);

  /// Returns true when the task pool contains at least one runner for [profileId].
  bool hasTaskRunnerForProfile(String profileId);

  /// Returns true when the task pool contains at least one runner for [providerId].
  bool hasTaskRunnerForProvider(String providerId);

  /// Number of task runners configured for [providerId].
  int taskRunnerCountForProvider(String providerId);

  /// Distinct security profiles available among task runners.
  Set<String> get taskProfiles;

  /// Distinct provider IDs available among task runners.
  Set<String> get taskProviders;

  /// Graceful shutdown: stops and disposes all runners' harnesses.
  Future<void> dispose();
}
