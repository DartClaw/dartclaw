import '../turn/turn_runner.dart';

/// Pool of [TurnRunner] instances for concurrent host-dispatched execution.
///
/// Runner at index 0 is the "primary" — used exclusively for main chat, cron,
/// and channel turns. Runners at indices 1..N-1 are workers shared by
/// background tasks and logical-agent sessions.
abstract interface class HarnessPool {
  /// The primary runner (index 0), used for main chat, cron, and channel turns.
  TurnRunner get primary;

  /// All runners in the pool, including the primary runner.
  List<TurnRunner> get runners;

  /// Adds a lazily-spawned worker to the pool.
  void addRunner(TurnRunner runner);

  /// Number of additional workers that can still be spawned.
  int get spawnableCount;

  /// Acquires an idle worker from the pool (indices 1..N-1).
  /// Returns null if all workers are busy or no workers exist.
  TurnRunner? tryAcquire();

  /// Acquires an idle worker matching the given [profileId].
  TurnRunner? tryAcquireForProfile(String profileId);

  /// Acquires an idle worker matching the given [providerId].
  TurnRunner? tryAcquireForProvider(String providerId);

  /// Acquires an idle worker matching both [providerId] and [profileId].
  TurnRunner? tryAcquireForProviderAndProfile(String providerId, String profileId);

  /// Releases a previously acquired runner back to the pool.
  void release(TurnRunner runner);

  /// Number of workers currently executing turns.
  int get activeCount;

  /// Number of workers available for acquisition.
  int get availableCount;

  /// Total pool size (including primary).
  int get size;

  /// Maximum concurrent worker executions allowed at once.
  int get maxConcurrentWorkers;

  /// Returns the pool index of [runner], or -1 if not found.
  int indexOf(TurnRunner runner);

  /// Returns true when the worker pool contains at least one runner for [profileId].
  bool hasWorkerForProfile(String profileId);

  /// Returns true when the worker pool contains at least one runner for [providerId].
  bool hasWorkerForProvider(String providerId);

  /// Number of workers configured for [providerId].
  int workerCountForProvider(String providerId);

  /// Distinct security profiles available among workers.
  Set<String> get workerProfiles;

  /// Distinct provider IDs available among workers.
  Set<String> get workerProviders;

  /// Graceful shutdown: stops and disposes all runners' harnesses.
  Future<void> dispose();
}
