import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart' show TaskEvent, TaskEventKind;
import 'package:logging/logging.dart';
import 'package:sqlite3/sqlite3.dart';

/// SQLite-backed persistence for task timeline events.
///
/// Shares the same [Database] instance as [SqliteTaskRepository] and
/// [TurnTraceService] (co-located in tasks.db).
///
/// Writes are synchronous — no event loss on crash (NF04).
class TaskEventService {
  static final _log = Logger('TaskEventService');

  final Database _db;

  TaskEventService(this._db) {
    _initSchema();
  }

  void _initSchema() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS task_events (
        id TEXT PRIMARY KEY,
        task_id TEXT NOT NULL,
        timestamp TEXT NOT NULL,
        kind TEXT NOT NULL,
        details TEXT NOT NULL DEFAULT '{}'
      )
    ''');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_task_events_task ON task_events(task_id)');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_task_events_task_kind ON task_events(task_id, kind)');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_task_events_timestamp ON task_events(timestamp)');
  }

  /// Inserts a single event. Synchronous write for durability (NF04).
  void insert(TaskEvent event) {
    final stmt = _db.prepare('INSERT INTO task_events (id, task_id, timestamp, kind, details) VALUES (?, ?, ?, ?, ?)');
    try {
      stmt.execute([
        event.id,
        event.taskId,
        event.timestamp.toIso8601String(),
        event.kind.name,
        jsonEncode(event.details),
      ]);
    } finally {
      stmt.close();
    }
  }

  /// Retrieves events for a task in chronological order (oldest first).
  ///
  /// Optionally filtered by [kind] and limited to [limit] results.
  List<TaskEvent> listForTask(String taskId, {TaskEventKind? kind, int? limit}) {
    final where = ['task_id = ?'];
    final params = <Object?>[taskId];

    if (kind != null) {
      where.add('kind = ?');
      params.add(kind.name);
    }

    final whereClause = where.join(' AND ');
    final limitClause = limit != null ? ' LIMIT $limit' : '';

    final stmt = _db.prepare(
      'SELECT id, task_id, timestamp, kind, details FROM task_events '
      'WHERE $whereClause ORDER BY timestamp ASC$limitClause',
    );
    try {
      final rows = stmt.select(params);
      return rows.map(_eventFromRow).toList();
    } finally {
      stmt.close();
    }
  }

  /// Returns the count of events for a task, optionally filtered by kind.
  int countForTask(String taskId, {TaskEventKind? kind}) {
    final where = ['task_id = ?'];
    final params = <Object?>[taskId];

    if (kind != null) {
      where.add('kind = ?');
      params.add(kind.name);
    }

    final whereClause = where.join(' AND ');
    final stmt = _db.prepare('SELECT COUNT(*) as cnt FROM task_events WHERE $whereClause');
    try {
      final rows = stmt.select(params);
      return (rows.firstOrNull?['cnt'] as num?)?.toInt() ?? 0;
    } finally {
      stmt.close();
    }
  }

  TaskEvent _eventFromRow(Row row) {
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
