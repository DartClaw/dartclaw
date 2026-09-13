import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart' show TaskEvent, TaskEventKind;
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show DatabaseBackend;
import 'package:logging/logging.dart';

/// SQLite-backed persistence for task timeline events.
///
/// Writes complete before the returned future completes.
class TaskEventService {
  static final _log = Logger('TaskEventService');

  final DatabaseBackend _backend;

  /// Creates the service against a prepared task [backend].
  new(this._backend);

  /// Inserts a single event before the returned future completes.
  Future<void> insert(TaskEvent event) async {
    final stmt = await _backend.prepare(
      'INSERT INTO task_events (id, task_id, timestamp, kind, details) VALUES (?, ?, ?, ?, ?)',
    );
    try {
      await stmt.execute([
        event.id,
        event.taskId,
        event.timestamp.toIso8601String(),
        event.kind.name,
        jsonEncode(event.details),
      ]);
    } finally {
      await stmt.close();
    }
  }

  /// Retrieves events for a task in chronological order (oldest first).
  ///
  /// Optionally filtered by [kind] and limited to [limit] results.
  Future<List<TaskEvent>> listForTask(String taskId, {TaskEventKind? kind, int? limit}) async {
    final filter = _taskFilter(taskId, kind);
    final limitClause = limit != null ? ' LIMIT $limit' : '';

    final stmt = await _backend.prepare(
      'SELECT id, task_id, timestamp, kind, details FROM task_events '
      'WHERE ${filter.whereClause} ORDER BY timestamp ASC$limitClause',
    );
    try {
      return (await stmt.query(filter.params)).map(_eventFromRow).toList();
    } finally {
      await stmt.close();
    }
  }

  /// Returns the count of events for a task, optionally filtered by kind.
  Future<int> countForTask(String taskId, {TaskEventKind? kind}) async {
    final filter = _taskFilter(taskId, kind);
    final stmt = await _backend.prepare('SELECT COUNT(*) as cnt FROM task_events WHERE ${filter.whereClause}');
    try {
      final rows = await stmt.query(filter.params);
      return (rows.firstOrNull?['cnt'] as num?)?.toInt() ?? 0;
    } finally {
      await stmt.close();
    }
  }

  ({String whereClause, List<Object?> params}) _taskFilter(String taskId, TaskEventKind? kind) {
    final where = ['task_id = ?'];
    final params = <Object?>[taskId];
    if (kind != null) {
      where.add('kind = ?');
      params.add(kind.name);
    }
    return (whereClause: where.join(' AND '), params: params);
  }

  TaskEvent _eventFromRow(Map<String, Object?> row) {
    Map<String, dynamic> details = const {};
    final detailsJson = row['details'] as String?;
    if (detailsJson != null && detailsJson.isNotEmpty) {
      try {
        details = jsonDecode(detailsJson) as Map<String, dynamic>;
      } catch (e) {
        _log.warning('Malformed details JSON for event ${row['id']}: $e');
      }
    }
    return TaskEvent(
      id: row['id'] as String,
      taskId: row['task_id'] as String,
      timestamp: DateTime.parse(row['timestamp'] as String),
      kind: TaskEventKind.fromName(row['kind'] as String),
      details: details,
    );
  }
}
