import 'package:dartclaw_core/dartclaw_core.dart' show MemoryFileService, MemorySearchResult;
import 'package:sqlite3/sqlite3.dart';

/// One canonical row in the derived memory search index.
final class MemoryIndexRow {
  /// Normalized chunk text used by FTS5 and exact-identity operations.
  final String text;

  /// Canonical source label such as `memory_save` or `archive`.
  final String source;

  /// Memory category retained from the source entry.
  final String? category;

  /// Source entry time; undated entries use a deterministic oldest sentinel.
  final DateTime createdAt;

  /// Creates one derived index row.
  const MemoryIndexRow({required this.text, required this.source, required this.category, required this.createdAt});
}

/// Manages the FTS5 memory search index backed by SQLite.
class MemoryService {
  static final _undatedCreatedAt = DateTime.utc(1);
  final Database _db;

  /// Creates a [MemoryService] backed by [_db] and initializes the FTS5 schema.
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

  /// Inserts a new memory chunk and returns its row id.
  int insertChunk({
    required String text,
    required String source,
    String? category,
    DateTime? createdAt,
    String userId = 'owner',
  }) {
    if (text.trim().isEmpty) {
      throw ArgumentError('text must not be empty or blank');
    }
    if (source.trim().isEmpty) {
      throw ArgumentError('source must not be empty or blank');
    }
    if (createdAt == null) {
      _db.execute('INSERT INTO memory_chunks (text, source, category, user_id) VALUES (?, ?, ?, ?)', [
        text,
        source,
        category,
        userId,
      ]);
    } else {
      _db.execute('INSERT INTO memory_chunks (text, source, category, created_at, user_id) VALUES (?, ?, ?, ?, ?)', [
        text,
        source,
        category,
        createdAt.toIso8601String(),
        userId,
      ]);
    }
    return _db.lastInsertRowId;
  }

  /// Inserts a chunk only when the same indexed identity is absent.
  bool insertChunkIfAbsent({
    required String text,
    required String source,
    String? category,
    DateTime? createdAt,
    String userId = 'owner',
  }) {
    if (text.trim().isEmpty) throw ArgumentError('text must not be empty or blank');
    if (source.trim().isEmpty) throw ArgumentError('source must not be empty or blank');
    _db.execute(
      '''
      INSERT INTO memory_chunks (text, source, category, created_at, user_id)
      SELECT ?, ?, ?, COALESCE(?, datetime('now')), ?
      WHERE NOT EXISTS (
        SELECT 1 FROM memory_chunks WHERE text = ? AND source = ? AND category IS ? AND user_id = ?
      )
    ''',
      [text, source, category, createdAt?.toIso8601String(), userId, text, source, category, userId],
    );
    return _db.updatedRows > 0;
  }

  /// Deletes the exact indexed identity used by [insertChunkIfAbsent].
  bool deleteChunkIdentity({required String text, required String source, String? category, String userId = 'owner'}) {
    _db.execute('DELETE FROM memory_chunks WHERE text = ? AND source = ? AND category IS ? AND user_id = ?', [
      text,
      source,
      category,
      userId,
    ]);
    return _db.updatedRows > 0;
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

  /// Lists recent memory chunks without mutating the search index.
  List<MemorySearchResult> listRecent({int limit = 20, String userId = 'owner'}) {
    final stmt = _db.prepare('''
      SELECT text, source, category
      FROM memory_chunks
      WHERE user_id = ?
      ORDER BY created_at DESC, id DESC
      LIMIT ?
    ''');
    try {
      final rows = stmt.select([userId, limit]);
      return rows
          .map(
            (row) => MemorySearchResult(
              text: row['text'] as String,
              source: row['source'] as String,
              category: row['category'] as String?,
              score: 0,
            ),
          )
          .toList();
    } finally {
      stmt.close();
    }
  }

  /// Stub for future vector search. Returns empty list.
  List<MemorySearchResult> searchVector(List<double> embedding, {int limit = 20}) => const [];

  /// Deletes all chunks with [source] for [userId] and returns the row count.
  int deleteBySource(String source, {String userId = 'owner'}) {
    _db.execute('DELETE FROM memory_chunks WHERE source = ? AND user_id = ?', [source, userId]);
    return _db.updatedRows;
  }

  /// Normalizes one canonical file entry into its stable search-index rows.
  static List<MemoryIndexRow> indexRows({
    required String text,
    required String source,
    required String? category,
    required DateTime? createdAt,
  }) {
    final normalized = MemoryFileService.stripMarkdown(text.replaceAll('\r\n', '\n').replaceAll('\r', '\n'));
    return MemoryFileService.splitParagraphs(normalized)
        .where((chunk) => chunk.trim().isNotEmpty)
        .map(
          (chunk) => MemoryIndexRow(
            text: chunk,
            source: source,
            category: category,
            createdAt: createdAt ?? _undatedCreatedAt,
          ),
        )
        .toList(growable: false);
  }

  /// Replaces all chunks for [userId] with [chunks].
  void rebuildIndex(Iterable<MemoryIndexRow> chunks, {String userId = 'owner'}) => _replaceRows(
    chunks,
    deleteSql: 'DELETE FROM memory_chunks WHERE user_id = ?',
    deleteArgs: [userId],
    userId: userId,
  );

  /// Atomically replaces rows from [sources] while preserving other sources.
  void replaceSourceRows(Iterable<MemoryIndexRow> rows, {required Set<String> sources, String userId = 'owner'}) {
    if (sources.isEmpty) throw ArgumentError.value(sources, 'sources', 'must not be empty');
    final replacements = rows.toList(growable: false);
    if (replacements.any((row) => !sources.contains(row.source))) {
      throw ArgumentError.value(rows, 'rows', 'must belong to the replaced sources');
    }
    final placeholders = List.filled(sources.length, '?').join(', ');
    _replaceRows(
      replacements,
      deleteSql: 'DELETE FROM memory_chunks WHERE user_id = ? AND source IN ($placeholders)',
      deleteArgs: [userId, ...sources],
      userId: userId,
    );
  }

  /// Atomically replaces one source/category slice while preserving other rows.
  void replaceCategoryRows(
    Iterable<MemoryIndexRow> rows, {
    required String source,
    required String? category,
    String userId = 'owner',
  }) {
    final replacements = rows.toList(growable: false);
    if (replacements.any((row) => row.source != source || row.category != category)) {
      throw ArgumentError.value(rows, 'rows', 'must belong to the replaced source and category');
    }
    _replaceRows(
      replacements,
      deleteSql: 'DELETE FROM memory_chunks WHERE user_id = ? AND source = ? AND category IS ?',
      deleteArgs: [userId, source, category],
      userId: userId,
    );
  }

  void _replaceRows(
    Iterable<MemoryIndexRow> rows, {
    required String deleteSql,
    required List<Object?> deleteArgs,
    required String userId,
  }) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      _db.execute(deleteSql, deleteArgs);
      final stmt = _db.prepare(
        'INSERT INTO memory_chunks (text, source, category, created_at, user_id) VALUES (?, ?, ?, ?, ?)',
      );
      try {
        for (final chunk in rows) {
          stmt.execute([chunk.text, chunk.source, chunk.category, chunk.createdAt.toIso8601String(), userId]);
        }
      } finally {
        stmt.close();
      }
      _db.execute('COMMIT');
    } catch (_) {
      if (!_db.autocommit) _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Closes the underlying database connection.
  void close() => _db.close();
}
