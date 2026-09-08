import 'dart:async';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';

/// SQLite-backed [ExecutionRepositoryTransactor].
final class SqliteExecutionRepositoryTransactor implements ExecutionRepositoryTransactor {
  final DatabaseBackend _backend;

  /// Creates the transactor bound to [backend].
  new(this._backend);

  @override
  Future<T> transaction<T>(FutureOr<T> Function() action) => _backend.transaction((_) async => action());
}
