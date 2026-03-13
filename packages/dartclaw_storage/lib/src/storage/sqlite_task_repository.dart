import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart'
    show ArtifactKind, Task, TaskArtifact, TaskRepository, TaskStatus, TaskType;
import 'package:sqlite3/sqlite3.dart';

/// SQLite-backed task persistence for [Task] and [TaskArtifact].
class SqliteTaskRepository implements TaskRepository {
  final Database _db;

  SqliteTaskRepository(this._db) {
    _initSchema();
  }

  void _initSchema() {
    _db.execute('PRAGMA journal_mode=WAL');
    _db.execute('PRAGMA foreign_keys=ON');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS tasks (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        description TEXT NOT NULL,
        type TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'draft',
        goal_id TEXT,
        session_id TEXT,
        acceptance_criteria TEXT,
        config_json TEXT NOT NULL DEFAULT '{}',
        worktree_json TEXT,
        created_at TEXT NOT NULL,
        started_at TEXT,
        completed_at TEXT
      )
    ''');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status)');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_tasks_type ON tasks(type)');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_tasks_status_type ON tasks(status, type)');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS task_artifacts (
        id TEXT PRIMARY KEY,
        task_id TEXT NOT NULL,
        name TEXT NOT NULL,
        kind TEXT NOT NULL,
        path TEXT NOT NULL,
        created_at TEXT NOT NULL,
        FOREIGN KEY (task_id) REFERENCES tasks(id) ON DELETE CASCADE
      )
    ''');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_task_artifacts_task_id ON task_artifacts(task_id)');
  }

  @override
  Future<void> insert(Task task) async {
    final stmt = _db.prepare('''
      INSERT INTO tasks (
        id, title, description, type, status, goal_id, session_id,
        acceptance_criteria, config_json, worktree_json,
        created_at, started_at, completed_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''');
    try {
      stmt.execute([
        task.id,
        task.title,
        task.description,
        task.type.name,
        task.status.name,
        task.goalId,
        task.sessionId,
        task.acceptanceCriteria,
        _encodeJson(task.configJson),
        _encodeJsonNullable(task.worktreeJson),
        task.createdAt.toIso8601String(),
        task.startedAt?.toIso8601String(),
        task.completedAt?.toIso8601String(),
      ]);
    } finally {
      stmt.close();
    }
  }

  @override
  Future<Task?> getById(String id) async {
    final stmt = _db.prepare('SELECT * FROM tasks WHERE id = ?');
    try {
      final rows = stmt.select([id]);
      return rows.isEmpty ? null : _taskFromRow(rows.first);
    } finally {
      stmt.close();
    }
  }

  @override
  Future<List<Task>> list({TaskStatus? status, TaskType? type}) async {
    final where = <String>[];
    final params = <Object?>[];
    if (status != null) {
      where.add('status = ?');
      params.add(status.name);
    }
    if (type != null) {
      where.add('type = ?');
      params.add(type.name);
    }
    final buffer = StringBuffer('SELECT * FROM tasks');
    if (where.isNotEmpty) {
      buffer.write(' WHERE ${where.join(' AND ')}');
    }
    buffer.write(' ORDER BY created_at DESC, id DESC');

    final stmt = _db.prepare(buffer.toString());
    try {
      return stmt.select(params).map(_taskFromRow).toList(growable: false);
    } finally {
      stmt.close();
    }
  }

  @override
  Future<void> update(Task task) async {
    final stmt = _db.prepare('''
      UPDATE tasks
      SET
        title = ?,
        description = ?,
        type = ?,
        status = ?,
        goal_id = ?,
        session_id = ?,
        acceptance_criteria = ?,
        config_json = ?,
        worktree_json = ?,
        started_at = ?,
        completed_at = ?
      WHERE id = ?
    ''');
    try {
      stmt.execute([
        task.title,
        task.description,
        task.type.name,
        task.status.name,
        task.goalId,
        task.sessionId,
        task.acceptanceCriteria,
        _encodeJson(task.configJson),
        _encodeJsonNullable(task.worktreeJson),
        task.startedAt?.toIso8601String(),
        task.completedAt?.toIso8601String(),
        task.id,
      ]);
      if (_db.updatedRows == 0) {
        throw ArgumentError('Task not found: ${task.id}');
      }
    } finally {
      stmt.close();
    }
  }

  @override
  Future<bool> updateIfStatus(Task task, {required TaskStatus expectedStatus}) async {
    final stmt = _db.prepare('''
      UPDATE tasks
      SET
        status = ?,
        started_at = ?,
        completed_at = ?
      WHERE id = ? AND status = ?
    ''');
    try {
      stmt.execute([
        task.status.name,
        task.startedAt?.toIso8601String(),
        task.completedAt?.toIso8601String(),
        task.id,
        expectedStatus.name,
      ]);
      return _db.updatedRows > 0;
    } finally {
      stmt.close();
    }
  }

  @override
  Future<bool> updateMutableFieldsIfStatus(Task task, {required TaskStatus expectedStatus}) async {
    final stmt = _db.prepare('''
      UPDATE tasks
      SET
        title = ?,
        description = ?,
        session_id = ?,
        acceptance_criteria = ?,
        config_json = ?,
        worktree_json = ?
      WHERE id = ? AND status = ?
    ''');
    try {
      stmt.execute([
        task.title,
        task.description,
        task.sessionId,
        task.acceptanceCriteria,
        _encodeJson(task.configJson),
        _encodeJsonNullable(task.worktreeJson),
        task.id,
        expectedStatus.name,
      ]);
      return _db.updatedRows > 0;
    } finally {
      stmt.close();
    }
  }

  @override
  Future<void> delete(String id) async {
    final stmt = _db.prepare('DELETE FROM tasks WHERE id = ?');
    try {
      stmt.execute([id]);
      if (_db.updatedRows == 0) {
        throw ArgumentError('Task not found: $id');
      }
    } finally {
      stmt.close();
    }
  }

  @override
  Future<void> insertArtifact(TaskArtifact artifact) async {
    final stmt = _db.prepare('''
      INSERT INTO task_artifacts (id, task_id, name, kind, path, created_at)
      VALUES (?, ?, ?, ?, ?, ?)
    ''');
    try {
      stmt.execute([
        artifact.id,
        artifact.taskId,
        artifact.name,
        artifact.kind.name,
        artifact.path,
        artifact.createdAt.toIso8601String(),
      ]);
    } finally {
      stmt.close();
    }
  }

  @override
  Future<TaskArtifact?> getArtifactById(String id) async {
    final stmt = _db.prepare('SELECT * FROM task_artifacts WHERE id = ?');
    try {
      final rows = stmt.select([id]);
      return rows.isEmpty ? null : _artifactFromRow(rows.first);
    } finally {
      stmt.close();
    }
  }

  @override
  Future<List<TaskArtifact>> listArtifactsByTask(String taskId) async {
    final stmt = _db.prepare('SELECT * FROM task_artifacts WHERE task_id = ? ORDER BY created_at ASC');
    try {
      return stmt.select([taskId]).map(_artifactFromRow).toList(growable: false);
    } finally {
      stmt.close();
    }
  }

  @override
  Future<void> deleteArtifact(String id) async {
    final stmt = _db.prepare('DELETE FROM task_artifacts WHERE id = ?');
    try {
      stmt.execute([id]);
    } finally {
      stmt.close();
    }
  }

  @override
  Future<void> dispose() async {
    _db.close();
  }

  Task _taskFromRow(Row row) {
    return Task(
      id: row['id'] as String,
      title: row['title'] as String,
      description: row['description'] as String,
      type: TaskType.values.byName(row['type'] as String),
      status: TaskStatus.values.byName(row['status'] as String),
      goalId: row['goal_id'] as String?,
      sessionId: row['session_id'] as String?,
      acceptanceCriteria: row['acceptance_criteria'] as String?,
      configJson: _decodeJson(row['config_json'] as String),
      worktreeJson: _decodeJsonNullable(row['worktree_json'] as String?),
      createdAt: DateTime.parse(row['created_at'] as String),
      startedAt: _decodeDateTime(row['started_at']),
      completedAt: _decodeDateTime(row['completed_at']),
    );
  }

  TaskArtifact _artifactFromRow(Row row) {
    return TaskArtifact(
      id: row['id'] as String,
      taskId: row['task_id'] as String,
      name: row['name'] as String,
      kind: ArtifactKind.values.byName(row['kind'] as String),
      path: row['path'] as String,
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }

  DateTime? _decodeDateTime(Object? value) => value == null ? null : DateTime.parse(value as String);

  String _encodeJson(Map<String, dynamic> value) => jsonEncode(value);

  String? _encodeJsonNullable(Map<String, dynamic>? value) => value == null ? null : jsonEncode(value);

  Map<String, dynamic> _decodeJson(String value) => Map<String, dynamic>.from(jsonDecode(value) as Map);

  Map<String, dynamic>? _decodeJsonNullable(String? value) =>
      value == null ? null : Map<String, dynamic>.from(jsonDecode(value) as Map);
}
