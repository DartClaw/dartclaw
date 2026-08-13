import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart'
    show CanonicalMemoryCorpus, CanonicalMemoryEntry, CanonicalMemoryLearning, MemoryFileService, MemorySearchResult;
import 'package:sqlite3/sqlite3.dart';

/// One canonical row in the derived memory search index.
final class MemoryIndexRow {
  /// Normalized chunk text used by FTS5 and exact-identity operations.
  final String text;

  /// Stable source locator. Canonical rows use their entry ID.
  final String source;

  /// Memory category retained from the source entry.
  final String? category;

  /// Source entry time; undated entries use a deterministic oldest sentinel.
  final DateTime createdAt;

  /// Canonical or native memory role.
  final String role;

  /// Host-labelled source provenance.
  final String provenance;

  /// Stable source-of-record locator.
  final String locator;

  /// Canonical entry identity when applicable.
  final String? entryId;

  /// Canonical entry revision when applicable.
  final int? entryRevision;

  /// Creates one derived index row.
  const new({
    required this.text,
    required this.source,
    required this.category,
    required this.createdAt,
    this.role = 'memory',
    this.provenance = 'unknown',
    String? locator,
    this.entryId,
    this.entryRevision,
  }) : locator = locator ?? source;
}

/// Manages the FTS5 memory search index backed by SQLite.
class MemoryService {
  static final _undatedCreatedAt = DateTime.utc(1);
  final Database _db;

  /// Creates a [MemoryService] backed by [_db] and initializes the FTS5 schema.
  new(this._db) {
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
        user_id TEXT NOT NULL DEFAULT 'owner',
        role TEXT NOT NULL DEFAULT 'memory',
        provenance TEXT NOT NULL DEFAULT 'unknown',
        locator TEXT,
        entry_id TEXT,
        entry_revision INTEGER
      )
    ''');

    _migrateResultColumns();

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

  void _migrateResultColumns() {
    final cols = _db.select('PRAGMA table_info(memory_chunks)');
    final names = cols.map((row) => row['name'] as String).toSet();
    for (final (name, definition) in const [
      ('user_id', "TEXT NOT NULL DEFAULT 'owner'"),
      ('role', "TEXT NOT NULL DEFAULT 'memory'"),
      ('provenance', "TEXT NOT NULL DEFAULT 'unknown'"),
      ('locator', 'TEXT'),
      ('entry_id', 'TEXT'),
      ('entry_revision', 'INTEGER'),
    ]) {
      if (!names.contains(name)) _db.execute('ALTER TABLE memory_chunks ADD COLUMN $name $definition');
    }
  }

  /// Searches memory chunks using FTS5 BM25 ranking.
  ///
  /// The [query] is passed directly to the FTS5 MATCH operator. Results are
  /// ordered by relevance (best match first). The `rank` value from FTS5 is
  /// negative — lower is better.
  List<MemorySearchResult> search(String query, {int limit = 20, String userId = 'owner'}) {
    final stmt = _db.prepare('''
      SELECT mc.text, mc.source, mc.category, mc.role, mc.provenance,
             COALESCE(mc.locator, mc.source) AS locator, mc.entry_id, mc.entry_revision, rank
      FROM memory_chunks mc
      JOIN memory_chunks_fts ON mc.id = memory_chunks_fts.rowid
      WHERE memory_chunks_fts MATCH ? AND mc.user_id = ?
      ORDER BY rank
      LIMIT ?
    ''');
    try {
      final rows = stmt.select([query, userId, limit]);
      return rows.map((row) => _searchResult(row, score: (row['rank'] as num).toDouble())).toList();
    } finally {
      stmt.close();
    }
  }

  /// Encodes natural language into a safe FTS5 MATCH expression.
  static String? encodeNaturalLanguageQuery(String query) {
    var cleaned = query.replaceAll('"', ' ');
    cleaned = cleaned.replaceAll(RegExp(r'\b(AND|OR|NOT|NEAR)\b', caseSensitive: false), ' ');
    cleaned = cleaned.replaceAll(RegExp(r'[*^:+\-()]'), ' ');
    final words = cleaned.split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList(growable: false);
    if (words.isEmpty) return null;
    return words.map((word) => '"$word"').join(' ');
  }

  /// Lists recent memory chunks without mutating the search index.
  List<MemorySearchResult> listRecent({int limit = 20, String userId = 'owner'}) {
    final stmt = _db.prepare('''
      SELECT text, source, category, role, provenance,
             COALESCE(locator, source) AS locator, entry_id, entry_revision
      FROM memory_chunks
      WHERE user_id = ?
      ORDER BY created_at DESC, id DESC
      LIMIT ?
    ''');
    try {
      final rows = stmt.select([userId, limit]);
      return rows.map((row) => _searchResult(row, score: 0)).toList();
    } finally {
      stmt.close();
    }
  }

  static MemorySearchResult _searchResult(Row row, {required double score}) {
    final role = row['role'] as String;
    final entryId = row['entry_id'] as String?;
    final revision = row['entry_revision'] as int?;
    final locator = row['locator'] as String;
    if (const {'topic', 'archive', 'observation', 'learning'}.contains(role)) {
      if (entryId == null || revision == null) {
        throw StateError('canonical search row is missing entry identity');
      }
      return MemorySearchResult.canonical(
        text: row['text'] as String,
        source: row['source'] as String,
        category: row['category'] as String?,
        score: score,
        role: role,
        provenance: row['provenance'] as String,
        locator: locator,
        entryId: entryId,
        entryRevision: revision,
      );
    }
    return MemorySearchResult(
      text: row['text'] as String,
      source: row['source'] as String,
      category: row['category'] as String?,
      score: score,
      role: role,
      provenance: row['provenance'] as String,
      locator: locator,
      entryId: entryId,
      entryRevision: revision,
    );
  }

  /// Normalizes one canonical file entry into its stable search-index rows.
  static List<MemoryIndexRow> indexRows({
    required String text,
    required String source,
    required String? category,
    required DateTime? createdAt,
    String role = 'memory',
    String provenance = 'unknown',
    String? locator,
    String? entryId,
    int? entryRevision,
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
            role: role,
            provenance: provenance,
            locator: locator ?? source,
            entryId: entryId,
            entryRevision: entryRevision,
          ),
        )
        .toList(growable: false);
  }

  /// Normalizes every searchable canonical record into rebuildable index rows.
  static List<MemoryIndexRow> canonicalIndexRows(CanonicalMemoryCorpus corpus) {
    final rows = <MemoryIndexRow>[];
    void add({
      required String text,
      required String role,
      required String locator,
      required String provenance,
      required String? category,
      required DateTime createdAt,
      required int revision,
    }) {
      rows.addAll(
        indexRows(
          text: text,
          source: locator,
          category: category,
          createdAt: createdAt,
          role: role,
          provenance: provenance,
          locator: locator,
          entryId: locator,
          entryRevision: revision,
        ),
      );
    }

    for (final topic in corpus.topics) {
      for (final entry in topic.entries) {
        add(
          text: entry.content,
          role: 'topic',
          locator: entry.locator,
          provenance: entry.provenance.sourceLocator,
          category: entry.topic,
          createdAt: entry.created,
          revision: entry.revision,
        );
      }
    }
    for (final entry in corpus.archive?.entries ?? const <CanonicalMemoryEntry>[]) {
      add(
        text: entry.content,
        role: 'archive',
        locator: entry.locator,
        provenance: entry.provenance.sourceLocator,
        category: entry.topic,
        createdAt: entry.created,
        revision: entry.revision,
      );
    }
    for (final document in corpus.observations) {
      for (final entry in document.observations) {
        add(
          text: entry.content,
          role: 'observation',
          locator: entry.id,
          provenance: entry.provenance.sourceLocator,
          category: null,
          createdAt: entry.recorded,
          revision: 1,
        );
      }
    }
    for (final entry in corpus.learnings?.entries ?? const <CanonicalMemoryLearning>[]) {
      add(
        text: entry.content,
        role: 'learning',
        locator: entry.locator,
        provenance: entry.provenance.sourceLocator,
        category: null,
        createdAt: entry.created,
        revision: entry.revision,
      );
    }
    return rows;
  }

  /// Replaces all chunks for [userId] with [chunks].
  void rebuildIndex(Iterable<MemoryIndexRow> chunks, {String userId = 'owner'}) => _replaceRows(
    chunks,
    deleteSql: 'DELETE FROM memory_chunks WHERE user_id = ?',
    deleteArgs: [userId],
    userId: userId,
  );

  /// Atomically replaces memory-corpus rows while preserving independent sources.
  void replaceMemoryRows(Iterable<MemoryIndexRow> rows, {String userId = 'owner'}) {
    final replacements = rows.toList(growable: false);
    const canonicalRoles = {'topic', 'archive', 'observation', 'learning'};
    const legacySources = {'memory_save', 'archive', 'legacy-memory', 'legacy-archive', 'legacy-learning'};
    if (replacements.any((row) => !canonicalRoles.contains(row.role) && !legacySources.contains(row.source))) {
      throw ArgumentError.value(rows, 'rows', 'must belong to the memory corpus');
    }
    _replaceRows(
      replacements,
      deleteSql:
          'DELETE FROM memory_chunks WHERE user_id = ? '
          'AND (role IN (?, ?, ?, ?) OR source IN (?, ?, ?, ?, ?))',
      deleteArgs: [userId, ...canonicalRoles, ...legacySources],
      userId: userId,
    );
  }

  /// Atomically replaces the canonical records identified by [priorRecordIds].
  void replaceMemoryRecords(Iterable<MemoryIndexRow> rows, Iterable<String> priorRecordIds, {String userId = 'owner'}) {
    final replacements = rows.toList(growable: false);
    final ids = priorRecordIds.toSet().toList(growable: false);
    if (ids.isEmpty && replacements.isEmpty) return;
    _db.execute('BEGIN IMMEDIATE');
    try {
      if (ids.isNotEmpty) {
        _db.execute(
          'DELETE FROM memory_chunks WHERE user_id = ? AND entry_id IN (${List.filled(ids.length, '?').join(',')})',
          [userId, ...ids],
        );
      }
      _insertRows(replacements, userId);
      _db.execute('COMMIT');
    } catch (_) {
      if (!_db.autocommit) _db.execute('ROLLBACK');
      rethrow;
    }
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
      _insertRows(rows, userId);
      _db.execute('COMMIT');
    } catch (_) {
      if (!_db.autocommit) _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void _insertRows(Iterable<MemoryIndexRow> rows, String userId) {
    final stmt = _db.prepare('''
        INSERT INTO memory_chunks
          (text, source, category, created_at, user_id, role, provenance, locator, entry_id, entry_revision)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''');
    try {
      for (final chunk in rows) {
        stmt.execute([
          chunk.text,
          chunk.source,
          chunk.category,
          chunk.createdAt.toIso8601String(),
          userId,
          chunk.role,
          chunk.provenance,
          chunk.locator,
          chunk.entryId,
          chunk.entryRevision,
        ]);
      }
    } finally {
      stmt.close();
    }
  }

  /// Validates SQLite/FTS integrity and the complete expected row multiset.
  void validateIndexRows(Iterable<MemoryIndexRow> rows, {String userId = 'owner'}) {
    final expected = rows.toList(growable: false);
    validateIntegrity();
    final actual = _db.select(
      '''
      SELECT text, source, category, created_at, user_id, role, provenance,
             COALESCE(locator, source) AS locator, entry_id, entry_revision
      FROM memory_chunks WHERE user_id = ?
        AND (role IN ('topic', 'archive', 'observation', 'learning')
             OR source IN ('memory_save', 'archive', 'legacy-memory', 'legacy-archive', 'legacy-learning'))
      ''',
      [userId],
    );
    _validateRowParity(expected, actual, userId);
  }

  /// Validates SQLite/FTS integrity and exact parity for one replaced record set.
  void validateMemoryRecords(Iterable<MemoryIndexRow> rows, Iterable<String> recordIds, {String userId = 'owner'}) {
    final expected = rows.toList(growable: false);
    final ids = {...recordIds, ...expected.map((row) => row.entryId).whereType<String>()}.toList(growable: false);
    validateIntegrity();
    final actual = ids.isEmpty
        ? const <Row>[]
        : _db.select(
            '''
            SELECT text, source, category, created_at, user_id, role, provenance,
                   COALESCE(locator, source) AS locator, entry_id, entry_revision
            FROM memory_chunks WHERE user_id = ?
              AND entry_id IN (${List.filled(ids.length, '?').join(',')})
            ''',
            [userId, ...ids],
          );
    _validateRowParity(expected, actual, userId);
  }

  void _validateRowParity(List<MemoryIndexRow> expected, Iterable<Row> actual, String userId) {
    final expectedKeys = expected.map((row) => _indexRowKey(row, userId)).toList()..sort();
    final actualKeys = actual.map(_storedRowKey).toList()..sort();
    if (expectedKeys.length != actualKeys.length) {
      throw StateError('Index row count mismatch: expected ${expectedKeys.length}, found ${actualKeys.length}');
    }
    for (var index = 0; index < expectedKeys.length; index++) {
      if (expectedKeys[index] != actualKeys[index]) throw StateError('Index row identity mismatch');
    }
  }

  /// Validates database/FTS integrity without materializing canonical rows.
  void validateIntegrity() {
    final integrity = _db.select('PRAGMA integrity_check').single.values.first;
    if (integrity != 'ok') throw StateError('SQLite integrity check failed: $integrity');
    _db.execute("INSERT INTO memory_chunks_fts(memory_chunks_fts) VALUES('integrity-check')");
  }

  /// Counts canonical derived rows for [userId].
  int memoryRowCount({String userId = 'owner'}) =>
      _db.select(
            "SELECT COUNT(*) AS count FROM memory_chunks WHERE user_id = ? AND role IN ('topic','archive','observation','learning')",
            [userId],
          ).single['count']
          as int;

  static String _indexRowKey(MemoryIndexRow row, String userId) => jsonEncode([
    row.text,
    row.source,
    row.category,
    row.createdAt.toIso8601String(),
    userId,
    row.role,
    row.provenance,
    row.locator,
    row.entryId,
    row.entryRevision,
  ]);

  static String _storedRowKey(Row row) => jsonEncode([
    row['text'],
    row['source'],
    row['category'],
    row['created_at'],
    row['user_id'],
    row['role'],
    row['provenance'],
    row['locator'],
    row['entry_id'],
    row['entry_revision'],
  ]);
}
