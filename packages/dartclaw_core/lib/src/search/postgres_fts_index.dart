import 'package:dartclaw_kernel/dartclaw_kernel.dart';

/// Refuses a PostgreSQL text-search configuration the server does not provide.
Future<void> validatePostgresFtsLanguage(DatabaseBackend backend, String language) async {
  final available = await backend.query(
    'SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_ts_config WHERE cfgname = ?) AS available',
    [language],
  );
  if (available.single['available'] == 1) return;

  final rows = await backend.query('SELECT cfgname FROM pg_catalog.pg_ts_config ORDER BY cfgname');
  throw StorageConfigurationException(
    key: 'database.fts_language',
    value: language,
    validValues: rows.map((row) => row['cfgname']).whereType<String>().toList(growable: false),
  );
}

/// Describes one PostgreSQL content table and its stored text-search vector.
final class PostgresFtsTable {
  /// The canonical memory-chunk schema prepared by [PostgresSchemaGate].
  static final memoryChunks = PostgresFtsTable(
    baseTable: 'memory_chunks',
    rowIdColumn: 'id',
    idColumn: 'locator',
    legacyIdFallbackColumn: 'source',
    textColumn: 'text',
    timestampColumn: 'created_at',
    userColumn: 'user_id',
    contentTsvColumn: 'content_tsv',
    contentTsvIndex: 'memory_chunks_content_tsv_idx',
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

  /// The conversation-message schema prepared by [PostgresSchemaGate].
  static final conversationChunks = PostgresFtsTable(
    baseTable: 'conversation_chunks',
    rowIdColumn: 'id',
    idColumn: 'message_id',
    textColumn: 'text',
    timestampColumn: 'created_at',
    userColumn: 'user_id',
    contentTsvColumn: 'content_tsv',
    contentTsvIndex: 'conversation_chunks_content_tsv_idx',
    metadataColumns: const {'session_id': 'session_id', 'role': 'role'},
    requiredMetadata: const {'session_id', 'role'},
  );

  /// Creates a validated table descriptor.
  new({
    required this.baseTable,
    required this.rowIdColumn,
    required this.idColumn,
    this.legacyIdFallbackColumn,
    required this.textColumn,
    required this.timestampColumn,
    required this.userColumn,
    required this.contentTsvColumn,
    required this.contentTsvIndex,
    required Map<String, String> metadataColumns,
    Set<String> requiredMetadata = const {},
    Set<String> integerMetadata = const {},
  }) : metadataColumns = Map.unmodifiable(metadataColumns),
       requiredMetadata = Set.unmodifiable(requiredMetadata),
       integerMetadata = Set.unmodifiable(integerMetadata) {
    for (final identifier in <String>[
      baseTable,
      rowIdColumn,
      idColumn,
      ?legacyIdFallbackColumn,
      textColumn,
      timestampColumn,
      userColumn,
      contentTsvColumn,
      contentTsvIndex,
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

  /// Content table.
  final String baseTable;

  /// Stored-row identity used for deterministic ordering.
  final String rowIdColumn;

  /// Stable document identity column.
  final String idColumn;

  /// Legacy identity fallback used when [idColumn] is null.
  final String? legacyIdFallbackColumn;

  /// Stored chunk-text column.
  final String textColumn;

  /// Stored source-timestamp column.
  final String timestampColumn;

  /// Stored user-scope column.
  final String userColumn;

  /// Stored text-search vector column.
  final String contentTsvColumn;

  /// GIN index that covers [contentTsvColumn].
  final String contentTsvIndex;

  /// Opaque metadata keys mapped to stored columns in insertion order.
  final Map<String, String> metadataColumns;

  /// Metadata keys every stored document must carry.
  final Set<String> requiredMetadata;

  /// Metadata keys whose persisted column representation is an integer.
  final Set<String> integerMetadata;

  static final _identifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
}

/// PostgreSQL implementation of [FullTextIndex].
final class PostgresFtsIndex implements FullTextIndex {
  /// Creates an index whose mutations own their transactions.
  new(DatabaseBackend backend, {required PostgresFtsTable table, required String language})
    : _backend = backend,
      _table = table,
      _language = language,
      _ownsTransactions = true;

  /// Creates an index that joins an already-open database transaction.
  new withinTransaction(DatabaseBackend tx, {required PostgresFtsTable table, required String language})
    : _backend = tx,
      _table = table,
      _language = language,
      _ownsTransactions = false;

  final DatabaseBackend _backend;
  final PostgresFtsTable _table;
  final String _language;
  final bool _ownsTransactions;

  String get _idExpression {
    final fallback = _table.legacyIdFallbackColumn;
    return fallback == null ? _table.idColumn : 'COALESCE(${_table.idColumn}, $fallback)';
  }

  @override
  Future<List<SearchResult>> search(String naturalLanguageQuery, {required String userId, int limit = 20}) async {
    final rows = await _backend.query(
      '''
      SELECT $_idExpression AS document_id, ${_table.textColumn} AS chunk,
             ${_table.timestampColumn} AS document_timestamp,
             ${_metadataSelection()},
             ts_rank(${_table.contentTsvColumn}, websearch_to_tsquery(?::regconfig, ?)) AS rank
      FROM ${_table.baseTable}
      WHERE ${_table.userColumn} = ?
        AND ${_table.contentTsvColumn} @@ websearch_to_tsquery(?::regconfig, ?)
      ORDER BY ts_rank(${_table.contentTsvColumn}, websearch_to_tsquery(?::regconfig, ?)) DESC,
               ${_table.timestampColumn} DESC, ${_table.rowIdColumn} DESC
      LIMIT ?
    ''',
      [
        _language,
        naturalLanguageQuery,
        userId,
        _language,
        naturalLanguageQuery,
        _language,
        naturalLanguageQuery,
        limit,
      ],
    );
    return rows.map((row) => _result(row, score: (row['rank'] as num).toDouble())).toList(growable: false);
  }

  @override
  Future<List<SearchResult>> listRecent({required String userId, int limit = 20}) async {
    final rows = await _backend.query(
      '''
      SELECT $_idExpression AS document_id, ${_table.textColumn} AS chunk,
             ${_table.timestampColumn} AS document_timestamp,
             ${_metadataSelection()}
      FROM ${_table.baseTable}
      WHERE ${_table.userColumn} = ?
      ORDER BY ${_table.timestampColumn} DESC, ${_table.rowIdColumn} DESC
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
      ORDER BY ${_table.rowIdColumn}
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
    final vector = await _backend.query(
      '''
      SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = current_schema() AND table_name = ? AND column_name = ? AND udt_name = 'tsvector'
      ) AS available
    ''',
      [_table.baseTable, _table.contentTsvColumn],
    );
    final index = await _backend.query(
      '''
      SELECT EXISTS (
        SELECT 1 FROM pg_catalog.pg_indexes
        WHERE schemaname = current_schema() AND tablename = ? AND indexname = ? AND indexdef ILIKE ?
      ) AS available
    ''',
      [_table.baseTable, _table.contentTsvIndex, '% USING gin (${_table.contentTsvColumn})%'],
    );
    if (vector.single['available'] != 1 || index.single['available'] != 1) {
      throw StateError('PostgreSQL full-text index structure is missing');
    }
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
      _table.idColumn,
      _table.timestampColumn,
      _table.userColumn,
      ..._table.metadataColumns.values,
      _table.contentTsvColumn,
    ];
    final valuePlaceholders = [
      for (var index = 0; index < columns.length - 1; index++) '?',
      'to_tsvector(?::regconfig, ?)',
    ];
    final statement = await backend.prepare(
      'INSERT INTO ${_table.baseTable} (${columns.join(', ')}) VALUES (${valuePlaceholders.join(', ')})',
    );
    try {
      for (final document in documents) {
        for (final chunk in document.chunks) {
          await statement.execute([
            chunk,
            document.id,
            document.timestamp.toIso8601String(),
            userId,
            for (final key in _table.metadataColumns.keys) _encodedMetadataValue(document.metadata[key], key),
            _language,
            chunk,
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
}

final class _StoredDocument {
  new({required this.timestamp, required this.metadata});

  final DateTime timestamp;
  final Map<String, String> metadata;
  final List<String> chunks = [];
}
