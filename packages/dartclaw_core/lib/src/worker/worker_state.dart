/// Lifecycle state of a worker (agent subprocess).
enum WorkerState {
  /// Worker is available to accept a new turn.
  idle,

  /// Worker is currently executing a turn.
  busy,

  /// Worker exited unexpectedly and requires recovery.
  crashed,

  /// Worker has been intentionally stopped.
  stopped,
}
