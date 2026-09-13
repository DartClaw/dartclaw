import 'package:dartclaw_kernel/dartclaw_kernel.dart';

/// Describes one SQLite content table and its external-content FTS5 table.
final class SqliteFtsTable {
  /// The canonical memory-chunk schema prepared by [SqliteSchemaGate].
  static final memoryChunks = SqliteFtsTable(
    baseTable: 'memory_chunks',
    ftsTable: 'memory_chunks_fts',
    idColumn: 'locator',
    legacyIdFallbackColumn: 'source',
    textColumn: 'text',
    chunkIndexColumn: 'chunk_index',
    timestampColumn: 'created_at',
    userColumn: 'user_id',
    metadataColumns: const {
      'source': 'source',
      'category': 'category',
      'role': 'role',
      'provenance': 'provenance',
      'entry_id': 'entry_id',
      'entry_revision': 'entry_revision',
    },
    requiredMetadata: const {'source', 'role', 'provenance'},
    integerMetadata: const {'entry_revision'},
  );

  /// The conversation-message schema prepared by [SqliteSchemaGate].
  static final conversationChunks = SqliteFtsTable(
    baseTable: 'conversation_chunks',
    ftsTable: 'conversation_chunks_fts',
    idColumn: 'message_id',
    textColumn: 'text',
    chunkIndexColumn: 'chunk_index',
    timestampColumn: 'created_at',
    userColumn: 'user_id',
    metadataColumns: const {'session_id': 'session_id', 'role': 'role'},
    requiredMetadata: const {'session_id', 'role'},
  );

  /// Creates a validated table descriptor.
  new({
    required this.baseTable,
    required this.ftsTable,
    required this.idColumn,
    this.legacyIdFallbackColumn,
    required this.textColumn,
    required this.chunkIndexColumn,
    required this.timestampColumn,
    required this.userColumn,
    required Map<String, String> metadataColumns,
    Set<String> requiredMetadata = const {},
    Set<String> integerMetadata = const {},
  }) : metadataColumns = Map.unmodifiable(metadataColumns),
       requiredMetadata = Set.unmodifiable(requiredMetadata),
       integerMetadata = Set.unmodifiable(integerMetadata) {
    for (final identifier in <String>[
      baseTable,
      ftsTable,
      idColumn,
      ?legacyIdFallbackColumn,
      textColumn,
      chunkIndexColumn,
      timestampColumn,
      userColumn,
      ...this.metadataColumns.keys,
      ...this.metadataColumns.values,
    ]) {
      if (!_identifier.hasMatch(identifier)) {
        throw ArgumentError.value(identifier, 'identifier', 'must be a simple SQL identifier');
      }
    }
    final keys = this.metadataColumns.keys.toSet();
    if (!keys.containsAll(this.requiredMetadata)) {
      throw ArgumentError.value(requiredMetadata, 'requiredMetadata', 'must name declared metadata keys');
    }
    if (!keys.containsAll(this.integerMetadata)) {
      throw ArgumentError.value(integerMetadata, 'integerMetadata', 'must name declared metadata keys');
    }
  }

  /// Base content table.
  final String baseTable;

  /// External-content FTS5 table.
  final String ftsTable;

  /// Stable document identity column.
  final String idColumn;

  /// Legacy identity fallback used when [idColumn] is null.
  final String? legacyIdFallbackColumn;

  /// Stored chunk-text column.
  final String textColumn;

  /// Persisted zero-based chunk-position column.
  final String chunkIndexColumn;

  /// Stored source-timestamp column.
  final String timestampColumn;

  /// Stored user-scope column.
  final String userColumn;

  /// Opaque metadata keys mapped to stored columns in insertion order.
  final Map<String, String> metadataColumns;

  /// Metadata keys every stored document must carry.
  final Set<String> requiredMetadata;

  /// Metadata keys whose persisted column representation is an integer.
  final Set<String> integerMetadata;

  static final _identifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
}

/// SQLite FTS5 implementation of [FullTextIndex].
final class SqliteFtsIndex implements FullTextIndex {
  /// Creates an index whose mutations own their transactions.
  new(DatabaseBackend backend, {required SqliteFtsTable table})
    : _backend = backend,
      _table = table,
      _ownsTransactions = true;

  /// Creates an index that joins an already-open database transaction.
  new withinTransaction(DatabaseBackend tx, {required SqliteFtsTable table})
    : _backend = tx,
      _table = table,
      _ownsTransactions = false;

  final DatabaseBackend _backend;
  final SqliteFtsTable _table;
  final bool _ownsTransactions;

  String get _idExpression {
    final fallback = _table.legacyIdFallbackColumn;
    return fallback == null ? _table.idColumn : 'COALESCE(${_table.idColumn}, $fallback)';
  }

  @override
  Future<List<SearchResult>> search(String naturalLanguageQuery, {required String userId, int limit = 20}) async {
    final encoded = _encodeQuery(naturalLanguageQuery);
    if (encoded == null) return const [];
    final rows = await _backend.query(
      '''
      SELECT $_idExpression AS document_id, ${_table.textColumn} AS chunk,
             ${_table.chunkIndexColumn} AS chunk_index,
             ${_table.timestampColumn} AS document_timestamp,
             ${_metadataSelection()}, rank
      FROM ${_table.baseTable}
      JOIN ${_table.ftsTable} ON ${_table.baseTable}.rowid = ${_table.ftsTable}.rowid
      WHERE ${_table.ftsTable} MATCH ? AND ${_table.userColumn} = ?
      ORDER BY rank
      LIMIT ?
    ''',
      [encoded, userId, limit],
    );
    return rows.map((row) => _result(row, score: (row['rank'] as num).toDouble())).toList(growable: false);
  }

  @override
  Future<List<SearchResult>> listRecent({required String userId, int limit = 20}) async {
    final rows = await _backend.query(
      '''
      SELECT $_idExpression AS document_id, ${_table.textColumn} AS chunk,
             ${_table.chunkIndexColumn} AS chunk_index,
             ${_table.timestampColumn} AS document_timestamp,
             ${_metadataSelection()}
      FROM ${_table.baseTable}
      WHERE ${_table.userColumn} = ?
      ORDER BY ${_table.timestampColumn} DESC, rowid DESC
      LIMIT ?
    ''',
      [userId, limit],
    );
    return rows.map((row) => _result(row, score: 0)).toList(growable: false);
  }

  @override
  Future<List<SearchDocument>> fetch(Iterable<String> ids, {required String userId}) async {
    final requested = ids.toSet().toList(growable: false);
    if (requested.isEmpty) return const [];
    final placeholders = List.filled(requested.length, '?').join(',');
    final rows = await _backend.query(
      '''
      SELECT $_idExpression AS document_id, ${_table.textColumn} AS chunk,
             ${_table.timestampColumn} AS document_timestamp,
             ${_metadataSelection()}
      FROM ${_table.baseTable}
      WHERE ${_table.userColumn} = ? AND $_idExpression IN ($placeholders)
      ORDER BY $_idExpression, ${_table.chunkIndexColumn}
    ''',
      [userId, ...requested],
    );
    final documents = <String, _StoredDocument>{};
    for (final row in rows) {
      final id = row['document_id'] as String;
      final stored = documents.putIfAbsent(
        id,
        () => _StoredDocument(timestamp: DateTime.parse(row['document_timestamp'] as String), metadata: _metadata(row)),
      );
      stored.chunks.add(row['chunk'] as String);
    }
    return [
      for (final entry in documents.entries)
        SearchDocument(
          id: entry.key,
          chunks: entry.value.chunks,
          metadata: entry.value.metadata,
          timestamp: entry.value.timestamp,
        ),
    ];
  }

  @override
  Future<int> count({required String userId, Map<String, String> metadata = const {}}) async {
    final clauses = <String>['${_table.userColumn} = ?'];
    final parameters = <Object?>[userId];
    for (final entry in metadata.entries) {
      final column = _table.metadataColumns[entry.key];
      if (column == null) return 0;
      if (_table.integerMetadata.contains(entry.key)) {
        final parsed = int.tryParse(entry.value);
        if (parsed == null || parsed.toString() != entry.value) return 0;
      }
      clauses.add('$column = ?');
      parameters.add(_encodeMetadata(entry.key, entry.value));
    }
    final rows = await _backend.query(
      'SELECT COUNT(*) AS count FROM ${_table.baseTable} WHERE ${clauses.join(' AND ')}',
      parameters,
    );
    return rows.single['count'] as int;
  }

  @override
  Future<void> upsert(
    Iterable<SearchDocument> documents, {
    required String userId,
    Set<String> retire = const {},
  }) async {
    final replacements = _lastWins(documents);
    if (replacements.isEmpty && retire.isEmpty) return;
    await _mutate((backend) async {
      await _delete(backend, {...retire, ...replacements.keys}, userId);
      await _insert(backend, replacements.values, userId);
    });
  }

  @override
  Future<void> delete(Iterable<String> ids, {required String userId}) async {
    final selected = ids.toSet();
    if (selected.isEmpty) return;
    await _mutate((backend) => _delete(backend, selected, userId));
  }

  @override
  Future<void> replaceAll(Iterable<SearchDocument> documents, {required String userId}) async {
    final replacements = _lastWins(documents);
    await _mutate((backend) async {
      await backend.execute('DELETE FROM ${_table.baseTable} WHERE ${_table.userColumn} = ?', [userId]);
      await _insert(backend, replacements.values, userId);
    });
  }

  @override
  Future<void> verifyIntegrity() async {
    final integrity = await _backend.query('PRAGMA integrity_check');
    final value = integrity.single.values.first;
    if (value != 'ok') throw StateError('SQLite integrity check failed: $value');
    await _backend.execute("INSERT INTO ${_table.ftsTable}(${_table.ftsTable}) VALUES('integrity-check')");
  }

  Future<void> _mutate(Future<void> Function(DatabaseBackend backend) body) {
    return _ownsTransactions ? _backend.transaction(body) : body(_backend);
  }

  Map<String, SearchDocument> _lastWins(Iterable<SearchDocument> documents) {
    final replacements = <String, SearchDocument>{};
    for (final document in documents) {
      _validateDocument(document);
      replacements.remove(document.id);
      replacements[document.id] = document;
    }
    return replacements;
  }

  void _validateDocument(SearchDocument document) {
    if (document.id.isEmpty) throw ArgumentError.value(document.id, 'document.id', 'must not be empty');
    if (document.chunks.isEmpty) throw ArgumentError.value(document.chunks, 'document.chunks', 'must not be empty');
    final unsupported = document.metadata.keys.where((key) => !_table.metadataColumns.containsKey(key)).toList();
    if (unsupported.isNotEmpty) {
      throw ArgumentError.value(unsupported, 'document.metadata', 'contains keys unsupported by this table');
    }
    final missing = _table.requiredMetadata.where((key) => !document.metadata.containsKey(key)).toList();
    if (missing.isNotEmpty) {
      throw ArgumentError.value(missing, 'document.metadata', 'is missing required keys');
    }
    for (final key in _table.integerMetadata) {
      final value = document.metadata[key];
      final parsed = value == null ? null : int.tryParse(value);
      if (value != null && (parsed == null || parsed.toString() != value)) {
        throw ArgumentError.value(value, 'document.metadata[$key]', 'must be an integer');
      }
    }
  }

  Future<void> _delete(DatabaseBackend backend, Set<String> ids, String userId) async {
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(',');
    await backend.execute(
      'DELETE FROM ${_table.baseTable} WHERE ${_table.userColumn} = ? AND $_idExpression IN ($placeholders)',
      [userId, ...ids],
    );
  }

  Future<void> _insert(DatabaseBackend backend, Iterable<SearchDocument> documents, String userId) async {
    final columns = [
      _table.textColumn,
      _table.chunkIndexColumn,
      _table.idColumn,
      _table.timestampColumn,
      _table.userColumn,
      ..._table.metadataColumns.values,
    ];
    final placeholders = List.filled(columns.length, '?').join(', ');
    final statement = await backend.prepare(
      'INSERT INTO ${_table.baseTable} (${columns.join(', ')}) VALUES ($placeholders)',
    );
    try {
      for (final document in documents) {
        for (final (chunkIndex, chunk) in document.chunks.indexed) {
          await statement.execute([
            chunk,
            chunkIndex,
            document.id,
            document.timestamp.toIso8601String(),
            userId,
            for (final key in _table.metadataColumns.keys) _encodedMetadataValue(document.metadata[key], key),
          ]);
        }
      }
    } finally {
      await statement.close();
    }
  }

  SearchResult _result(Map<String, Object?> row, {required double score}) => SearchResult(
    id: row['document_id'] as String,
    chunk: row['chunk'] as String,
    chunkIndex: row['chunk_index'] as int,
    metadata: _metadata(row),
    timestamp: DateTime.parse(row['document_timestamp'] as String),
    score: score,
  );

  String _metadataSelection() =>
      _table.metadataColumns.entries.map((entry) => '${entry.value} AS metadata_${entry.key}').join(', ');

  Map<String, String> _metadata(Map<String, Object?> row) => {
    for (final key in _table.metadataColumns.keys)
      if (row['metadata_$key'] != null) key: row['metadata_$key'].toString(),
  };

  Object _encodeMetadata(String key, String value) => _table.integerMetadata.contains(key) ? int.parse(value) : value;

  Object? _encodedMetadataValue(String? value, String key) => value == null ? null : _encodeMetadata(key, value);

  static String? _encodeQuery(String query) {
    var cleaned = query.replaceAll('"', ' ');
    cleaned = cleaned.replaceAll(RegExp(r'\b(AND|OR|NOT|NEAR)\b', caseSensitive: false), ' ');
    cleaned = cleaned.replaceAll(RegExp(r'[*^:+\-()]'), ' ');
    final words = cleaned.split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList(growable: false);
    if (words.isEmpty) return null;
    return words.map((word) => '"$word"').join(' ');
  }
}

final class _StoredDocument {
  new({required this.timestamp, required this.metadata});

  final DateTime timestamp;
  final Map<String, String> metadata;
  final List<String> chunks = [];
}
