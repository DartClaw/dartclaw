import 'package:dartclaw_core/dartclaw_core.dart' show Goal, GoalRepository;
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show DatabaseBackend;

/// SQLite-backed goal persistence sharing the tasks database.
class SqliteGoalRepository implements GoalRepository {
  final DatabaseBackend _backend;

  new(this._backend);

  @override
  Future<void> insert(Goal goal) async {
    final stmt = await _backend.prepare('''
      INSERT INTO goals (id, title, parent_goal_id, mission, created_at, max_tokens)
      VALUES (?, ?, ?, ?, ?, ?)
    ''');
    try {
      await stmt.execute([
        goal.id,
        goal.title,
        goal.parentGoalId,
        goal.mission,
        goal.createdAt.toIso8601String(),
        goal.maxTokens,
      ]);
    } finally {
      await stmt.close();
    }
  }

  @override
  Future<Goal?> getById(String id) async {
    final stmt = await _backend.prepare('SELECT * FROM goals WHERE id = ?');
    try {
      final rows = await stmt.query([id]);
      return rows.isEmpty ? null : _goalFromRow(rows.first);
    } finally {
      await stmt.close();
    }
  }

  @override
  Future<List<Goal>> list() async {
    final stmt = await _backend.prepare('SELECT * FROM goals ORDER BY created_at DESC, id DESC');
    try {
      return (await stmt.query()).map(_goalFromRow).toList(growable: false);
    } finally {
      await stmt.close();
    }
  }

  @override
  Future<void> delete(String id) async {
    final stmt = await _backend.prepare('DELETE FROM goals WHERE id = ?');
    try {
      await stmt.execute([id]);
    } finally {
      await stmt.close();
    }
  }

  @override
  Future<void> dispose() async {}

  Goal _goalFromRow(Map<String, Object?> row) {
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
