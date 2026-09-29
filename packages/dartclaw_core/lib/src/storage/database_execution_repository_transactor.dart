import 'dart:async';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';

/// Database-backed [ExecutionRepositoryTransactor].
final class DatabaseExecutionRepositoryTransactor implements ExecutionRepositoryTransactor {
  final DatabaseBackend _backend;

  /// Creates the transactor bound to [backend].
  new(this._backend);

  @override
  Future<T> transaction<T>(FutureOr<T> Function() action) => _backend.transaction((_) async => action());
}
