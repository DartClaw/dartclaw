import 'package:sqlite3/sqlite3.dart';

/// SQLite-backed storage for active turn state keyed by session ID.
class TurnStateStore {
  final Database _db;

  /// Creates a store backed by [db] and initializes the required schema.
  TurnStateStore(this._db) {
    _initSchema();
  }

  void _initSchema() {
    _db.execute('PRAGMA journal_mode=WAL');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS turn_state (
        session_id TEXT PRIMARY KEY,
        turn_id TEXT NOT NULL,
        started_at TEXT NOT NULL
      )
    ''');
  }

  /// Stores or updates the active turn state for [sessionId].
  Future<void> set(String sessionId, String turnId, DateTime startedAt) async {
    final stmt = _db.prepare('''
      INSERT INTO turn_state (session_id, turn_id, started_at)
      VALUES (?, ?, ?)
      ON CONFLICT(session_id) DO UPDATE SET
        turn_id = excluded.turn_id,
        started_at = excluded.started_at
    ''');
    try {
      stmt.execute([sessionId, turnId, startedAt.toIso8601String()]);
    } finally {
      stmt.close();
    }
  }

  /// Deletes the active turn state for [sessionId] if it exists.
  Future<void> delete(String sessionId) async {
    final stmt = _db.prepare('DELETE FROM turn_state WHERE session_id = ?');
    try {
      stmt.execute([sessionId]);
    } finally {
      stmt.close();
    }
  }

  /// Returns all active turn states keyed by session ID.
  Future<Map<String, ({String turnId, DateTime startedAt})>> getAll() async {
    final stmt = _db.prepare('SELECT session_id, turn_id, started_at FROM turn_state ORDER BY session_id ASC');
    try {
      final states = <String, ({String turnId, DateTime startedAt})>{};
      for (final row in stmt.select()) {
        states[row['session_id'] as String] = (
          turnId: row['turn_id'] as String,
          startedAt: DateTime.parse(row['started_at'] as String),
        );
      }
      return states;
    } finally {
      stmt.close();
    }
  }

  /// Closes the underlying sqlite database owned by this store.
  Future<void> dispose() async {
    _db.close();
  }
}
