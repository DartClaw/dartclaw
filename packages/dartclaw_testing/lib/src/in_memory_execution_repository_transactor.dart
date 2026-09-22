import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:async';

/// In-memory [ExecutionRepositoryTransactor] used by tests.
final class InMemoryExecutionRepositoryTransactor implements ExecutionRepositoryTransactor {
  const new();

  @override
  Future<T> transaction<T>(FutureOr<T> Function() action) async => await action();
}
