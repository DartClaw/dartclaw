import 'package:dartclaw_core/dartclaw_core.dart' show Goal, GoalRepository;
import 'package:sqlite3/sqlite3.dart';

/// SQLite-backed goal persistence sharing the tasks database.
class SqliteGoalRepository implements GoalRepository {
  final Database _db;

  SqliteGoalRepository(this._db) {
    _initSchema();
  }

  void _initSchema() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS goals (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        parent_goal_id TEXT,
        mission TEXT NOT NULL,
        created_at TEXT NOT NULL
      )
    ''');
    _db.execute('CREATE INDEX IF NOT EXISTS idx_goals_parent ON goals(parent_goal_id)');
    // Migrations: add columns to existing databases that don't have them.
    final columns = _db.select('PRAGMA table_info(goals)').map((row) => row['name'] as String).toSet();
    if (!columns.contains('max_tokens')) {
      _db.execute('ALTER TABLE goals ADD COLUMN max_tokens INTEGER');
    }
  }

  @override
  Future<void> insert(Goal goal) async {
    final stmt = _db.prepare('''
      INSERT INTO goals (id, title, parent_goal_id, mission, created_at, max_tokens)
      VALUES (?, ?, ?, ?, ?, ?)
    ''');
    try {
      stmt.execute([
        goal.id,
        goal.title,
        goal.parentGoalId,
        goal.mission,
        goal.createdAt.toIso8601String(),
        goal.maxTokens,
      ]);
    } finally {
      stmt.close();
    }
  }

  @override
  Future<Goal?> getById(String id) async {
    final stmt = _db.prepare('SELECT * FROM goals WHERE id = ?');
    try {
      final rows = stmt.select([id]);
      return rows.isEmpty ? null : _goalFromRow(rows.first);
    } finally {
      stmt.close();
    }
  }

  @override
  Future<List<Goal>> list() async {
    final stmt = _db.prepare('SELECT * FROM goals ORDER BY created_at DESC, id DESC');
    try {
      return stmt.select().map(_goalFromRow).toList(growable: false);
    } finally {
      stmt.close();
    }
  }

  @override
  Future<void> delete(String id) async {
    final stmt = _db.prepare('DELETE FROM goals WHERE id = ?');
    try {
      stmt.execute([id]);
    } finally {
      stmt.close();
    }
  }

  @override
  Future<void> dispose() async {}

  Goal _goalFromRow(Row row) {
    return Goal(
      id: row['id'] as String,
      title: row['title'] as String,
      parentGoalId: row['parent_goal_id'] as String?,
      mission: row['mission'] as String,
      createdAt: DateTime.parse(row['created_at'] as String),
      maxTokens: row['max_tokens'] as int?,
    );
  }
}
