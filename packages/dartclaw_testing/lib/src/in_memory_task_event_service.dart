import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';

/// In-memory task-event service for tests that do not exercise SQL.
final class InMemoryTaskEventService extends TaskEventService {
  new() : super(_UnusedDatabaseBackend());

  final List<TaskEvent> _events = [];
  var _closed = false;

  Future<void> close() async => _closed = true;

  @override
  Future<void> insert(TaskEvent event) async {
    _ensureOpen();
    _events.add(event);
  }

  @override
  Future<List<TaskEvent>> listForTask(String taskId, {TaskEventKind? kind, int? limit}) async {
    _ensureOpen();
    final matching = _events.where((event) => event.taskId == taskId && (kind == null || event.kind == kind)).toList()
      ..sort((left, right) => left.timestamp.compareTo(right.timestamp));
    return limit == null ? matching : matching.take(limit).toList();
  }

  @override
  Future<int> countForTask(String taskId, {TaskEventKind? kind}) async =>
      (await listForTask(taskId, kind: kind)).length;

  void _ensureOpen() {
    if (_closed) throw StateError('Task event service is closed');
  }
}

final class _UnusedDatabaseBackend implements DatabaseBackend {
  @override
  Future<void> close() async {}

  @override
  Future<int> execute(String sql, [List<Object?> parameters = const []]) =>
      throw UnsupportedError('The in-memory task event service does not use SQL');

  @override
  Future<DatabaseStatement> prepare(String sql) =>
      throw UnsupportedError('The in-memory task event service does not use SQL');

  @override
  Future<List<Map<String, Object?>>> query(String sql, [List<Object?> parameters = const []]) =>
      throw UnsupportedError('The in-memory task event service does not use SQL');

  @override
  Future<T> transaction<T>(Future<T> Function(DatabaseBackend tx) body) => body(this);
}
