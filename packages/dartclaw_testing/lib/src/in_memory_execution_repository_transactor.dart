import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart' show ExecutionRepositoryTransactor;

/// In-memory [ExecutionRepositoryTransactor] used by tests.
final class InMemoryExecutionRepositoryTransactor implements ExecutionRepositoryTransactor {
  const InMemoryExecutionRepositoryTransactor();

  @override
  Future<T> transaction<T>(FutureOr<T> Function() action) async => await action();
}
