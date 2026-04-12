import 'package:dartclaw_core/dartclaw_core.dart' show MemorySearchResult;
import 'package:sqlite3/sqlite3.dart';

/// Manages the FTS5 memory search index backed by SQLite.
class MemoryService {
  final Database _db;

  MemoryService(this._db) {
    _initSchema();
  }

  void _initSchema() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS memory_chunks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        text TEXT NOT NULL,
        source TEXT NOT NULL,
        category TEXT,
        created_at TEXT NOT NULL DEFAULT (datetime('now')),
        user_id TEXT NOT NULL DEFAULT 'owner'
      )
    ''');

    // Migration: add user_id column if missing (existing DBs created before S19)
    _migrateUserIdColumn();

    _db.execute('''
      CREATE VIRTUAL TABLE IF NOT EXISTS memory_chunks_fts USING fts5(
        body,
        content='memory_chunks',
        content_rowid='id'
      )
    ''');

    _db.execute('''
      CREATE TRIGGER IF NOT EXISTS memory_chunks_ai AFTER INSERT ON memory_chunks BEGIN
        INSERT INTO memory_chunks_fts(rowid, body) VALUES (new.id, new.text);
      END
    ''');

    _db.execute('''
      CREATE TRIGGER IF NOT EXISTS memory_chunks_ad AFTER DELETE ON memory_chunks BEGIN
        INSERT INTO memory_chunks_fts(memory_chunks_fts, rowid, body) VALUES('delete', old.id, old.text);
      END
    ''');

    _db.execute('''
      CREATE TRIGGER IF NOT EXISTS memory_chunks_au AFTER UPDATE ON memory_chunks BEGIN
        INSERT INTO memory_chunks_fts(memory_chunks_fts, rowid, body) VALUES('delete', old.id, old.text);
        INSERT INTO memory_chunks_fts(rowid, body) VALUES (new.id, new.text);
      END
    ''');
  }

  void _migrateUserIdColumn() {
    final cols = _db.select('PRAGMA table_info(memory_chunks)');
    final hasUserId = cols.any((row) => row['name'] == 'user_id');
    if (!hasUserId) {
      _db.execute("ALTER TABLE memory_chunks ADD COLUMN user_id TEXT NOT NULL DEFAULT 'owner'");
    }
  }

  int insertChunk({required String text, required String source, String? category, String userId = 'owner'}) {
    if (text.trim().isEmpty) {
      throw ArgumentError('text must not be empty or blank');
    }
    if (source.trim().isEmpty) {
      throw ArgumentError('source must not be empty or blank');
    }
    _db.execute('INSERT INTO memory_chunks (text, source, category, user_id) VALUES (?, ?, ?, ?)', [
      text,
      source,
      category,
      userId,
    ]);
    return _db.lastInsertRowId;
  }

  /// Searches memory chunks using FTS5 BM25 ranking.
  ///
  /// The [query] is passed directly to the FTS5 MATCH operator. Results are
  /// ordered by relevance (best match first). The `rank` value from FTS5 is
  /// negative — lower is better.
  List<MemorySearchResult> search(String query, {int limit = 20, String userId = 'owner'}) {
    final stmt = _db.prepare('''
      SELECT mc.text, mc.source, mc.category, rank
      FROM memory_chunks mc
      JOIN memory_chunks_fts ON mc.id = memory_chunks_fts.rowid
      WHERE memory_chunks_fts MATCH ? AND mc.user_id = ?
      ORDER BY rank
      LIMIT ?
    ''');
    try {
      final rows = stmt.select([query, userId, limit]);
      return rows
          .map(
            (row) => MemorySearchResult(
              text: row['text'] as String,
              source: row['source'] as String,
              category: row['category'] as String?,
              score: (row['rank'] as num).toDouble(),
            ),
          )
          .toList();
    } finally {
      stmt.close();
    }
  }

  /// Stub for future vector search. Returns empty list.
  List<MemorySearchResult> searchVector(List<double> embedding, {int limit = 20}) => const [];

  int deleteBySource(String source, {String userId = 'owner'}) {
    _db.execute('DELETE FROM memory_chunks WHERE source = ? AND user_id = ?', [source, userId]);
    return _db.updatedRows;
  }

  void rebuildIndex(List<({String text, String source, String? category})> chunks, {String userId = 'owner'}) {
    _db.execute('DELETE FROM memory_chunks WHERE user_id = ?', [userId]);
    final stmt = _db.prepare('INSERT INTO memory_chunks (text, source, category, user_id) VALUES (?, ?, ?, ?)');
    try {
      for (final chunk in chunks) {
        stmt.execute([chunk.text, chunk.source, chunk.category, userId]);
      }
    } finally {
      stmt.close();
    }
  }

  void close() => _db.close();
}
