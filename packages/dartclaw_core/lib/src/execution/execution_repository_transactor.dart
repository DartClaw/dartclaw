import 'dart:async';

/// Runs a unit of repository work inside a shared transaction boundary.
abstract interface class ExecutionRepositoryTransactor {
  /// Executes [action] atomically.
  Future<T> transaction<T>(FutureOr<T> Function() action);
}
