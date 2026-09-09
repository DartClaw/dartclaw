import 'dart:math' as math;

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';

/// Records portable database operations while delegating their behavior.
final class RecordingDatabaseBackend implements DatabaseBackend {
  new(DatabaseBackend delegate) : this._(delegate, _DatabaseOperationCounts());

  const new _(this._delegate, this._counts);

  final DatabaseBackend _delegate;
  final _DatabaseOperationCounts _counts;

  int get executeCount => _counts.execute;
  int get prepareCount => _counts.prepare;
  int get queryCount => _counts.query;
  int get transactionCount => _counts.transaction;

  /// Clears all recorded operation counts.
  void reset() => _counts.reset();

  @override
  Future<void> close() => _delegate.close();

  @override
  Future<int> execute(String sql, [List<Object?> parameters = const []]) {
    _counts.execute++;
    return _delegate.execute(sql, parameters);
  }

  @override
  Future<DatabaseStatement> prepare(String sql) {
    _counts.prepare++;
    return _delegate.prepare(sql);
  }

  @override
  Future<List<Map<String, Object?>>> query(String sql, [List<Object?> parameters = const []]) {
    _counts.query++;
    return _delegate.query(sql, parameters);
  }

  @override
  Future<T> transaction<T>(Future<T> Function(DatabaseBackend tx) body) {
    _counts.transaction++;
    return _delegate.transaction((tx) => body(RecordingDatabaseBackend._(tx, _counts)));
  }
}

final class _DatabaseOperationCounts {
  var execute = 0;
  var prepare = 0;
  var query = 0;
  var transaction = 0;

  void reset() {
    execute = 0;
    prepare = 0;
    query = 0;
    transaction = 0;
  }
}

/// Injects a failure into transaction-bound vector mutations.
final class FailingVectorMutationBackend implements DatabaseBackend {
  new(this._delegate, {required this.failAt});

  final DatabaseBackend _delegate;
  final int failAt;
  var _operation = 0;
  var mutationOutsideTransaction = false;

  @override
  Future<void> close() => _delegate.close();

  @override
  Future<int> execute(String sql, [List<Object?> parameters = const []]) {
    mutationOutsideTransaction = true;
    return Future<int>.error(StateError('vector mutation executed outside a transaction'));
  }

  @override
  Future<DatabaseStatement> prepare(String sql) {
    mutationOutsideTransaction = true;
    return Future<DatabaseStatement>.error(StateError('vector mutation prepared outside a transaction'));
  }

  @override
  Future<List<Map<String, Object?>>> query(String sql, [List<Object?> parameters = const []]) =>
      _delegate.query(sql, parameters);

  @override
  Future<T> transaction<T>(Future<T> Function(DatabaseBackend tx) body) {
    _operation = 0;
    return _delegate.transaction((tx) => body(_FailingVectorTransaction(tx, this)));
  }

  void _fail() {
    _operation++;
    if (_operation == failAt) throw StateError('injected vector mutation failure');
  }
}

final class _FailingVectorTransaction implements DatabaseBackend {
  const new(this._delegate, this._owner);

  final DatabaseBackend _delegate;
  final FailingVectorMutationBackend _owner;

  @override
  Future<void> close() => _delegate.close();

  @override
  Future<int> execute(String sql, [List<Object?> parameters = const []]) {
    _owner._fail();
    return _delegate.execute(sql, parameters);
  }

  @override
  Future<DatabaseStatement> prepare(String sql) async => _FailingVectorStatement(await _delegate.prepare(sql), _owner);

  @override
  Future<List<Map<String, Object?>>> query(String sql, [List<Object?> parameters = const []]) =>
      _delegate.query(sql, parameters);

  @override
  Future<T> transaction<T>(Future<T> Function(DatabaseBackend tx) body) => _delegate.transaction(body);
}

final class _FailingVectorStatement implements DatabaseStatement {
  const new(this._delegate, this._owner);

  final DatabaseStatement _delegate;
  final FailingVectorMutationBackend _owner;

  @override
  Future<void> close() => _delegate.close();

  @override
  Future<int> execute([List<Object?> parameters = const []]) {
    _owner._fail();
    return _delegate.execute(parameters);
  }

  @override
  Future<List<Map<String, Object?>>> query([List<Object?> parameters = const []]) => _delegate.query(parameters);
}

/// In-memory PostgreSQL vector backend double with a deliberately small SQL contract.
final class PostgresVectorTestBackend implements DatabaseBackend {
  Map<String, _VectorRow> _rows = {};
  final List<({String sql, List<Object?> parameters})> queries = [];
  final List<String> prepared = [];
  List<Map<String, Object?>>? listResultOverride;
  List<Map<String, Object?>>? searchResultOverride;
  var transactions = 0;
  var failNextInsert = false;
  var _closed = false;

  @override
  Future<void> close() async => _closed = true;

  @override
  Future<int> execute(String sql, [List<Object?> parameters = const []]) async {
    _ensureOpen();
    final table = _table(sql);
    if (!RegExp('^DELETE FROM $table WHERE user_id = \\?', caseSensitive: false).hasMatch(sql.trimLeft())) {
      throw StateError('Unexpected vector delete SQL: $sql');
    }
    if (parameters.isEmpty || parameters.first is! String || parameters.length.isEven) {
      throw StateError('Unexpected vector delete parameters: $parameters');
    }
    final owner = parameters.first as String;
    final before = _rows.length;
    if (parameters.length == 1) {
      _rows.removeWhere((_, row) => row.table == table && row.userId == owner);
    } else {
      final selected = <String>{};
      for (var index = 1; index < parameters.length; index += 2) {
        if (parameters[index] is! String || parameters[index + 1] is! int) {
          throw StateError('Unexpected vector identity parameters: $parameters');
        }
        selected.add(_key(table, owner, parameters[index] as String, parameters[index + 1] as int));
      }
      _rows.removeWhere((key, _) => selected.contains(key));
    }
    return before - _rows.length;
  }

  @override
  Future<DatabaseStatement> prepare(String sql) async {
    _ensureOpen();
    final table = _table(sql);
    _requireSql(
      sql,
      RegExp(
        'INSERT INTO $table\\s*\\(user_id, document_id, chunk_index, content_hash, model_fingerprint, dimension, embedding\\)'
        '\\s*VALUES \\(\\?, \\?, \\?, \\?, \\?, \\?, CAST\\(\\? AS public\\.vector\\)\\)',
        caseSensitive: false,
      ),
      'vector insert',
    );
    prepared.add(sql);
    return _PostgresVectorInsertStatement(this, sql);
  }

  @override
  Future<List<Map<String, Object?>>> query(String sql, [List<Object?> parameters = const []]) async {
    _ensureOpen();
    queries.add((sql: sql, parameters: List.unmodifiable(parameters)));
    final table = _table(sql);
    if (sql.contains('WITH query_vector')) {
      _validateSearchSql(sql, parameters);
      final override = searchResultOverride;
      if (override != null) return override;
      final query = _parseVector(parameters[0] as String);
      final owner = parameters[1] as String;
      final fingerprint = parameters[2] as String;
      final dimension = parameters[3] as int;
      final limit = parameters[5] as int;
      final matches = _rows.values
          .where(
            (row) =>
                row.table == table &&
                row.userId == owner &&
                row.fingerprint == fingerprint &&
                row.dimension == dimension &&
                row.vector.length == dimension &&
                _norm(row.vector) > 0,
          )
          .map(
            (row) => <String, Object?>{
              'document_id': row.documentId,
              'chunk_index': row.chunkIndex,
              'content_hash': row.contentHash,
              'score': _dot(query, row.vector) / (_norm(query) * _norm(row.vector)),
            },
          )
          .toList();
      matches.sort((left, right) {
        final scoreOrder = (right['score'] as double).compareTo(left['score'] as double);
        if (scoreOrder != 0) return scoreOrder;
        final documentOrder = (left['document_id'] as String).compareTo(right['document_id'] as String);
        return documentOrder != 0 ? documentOrder : (left['chunk_index'] as int).compareTo(right['chunk_index'] as int);
      });
      return matches.take(limit).toList(growable: false);
    }
    _validateListSql(sql, parameters);
    final override = listResultOverride;
    if (override != null) return override;
    final owner = parameters.single as String;
    final selected = _rows.values.where((row) => row.table == table && row.userId == owner).toList()
      ..sort((left, right) {
        final documentOrder = left.documentId.compareTo(right.documentId);
        return documentOrder != 0 ? documentOrder : left.chunkIndex.compareTo(right.chunkIndex);
      });
    return [
      for (final row in selected)
        {
          'document_id': row.documentId,
          'chunk_index': row.chunkIndex,
          'content_hash': row.contentHash,
          'model_fingerprint': row.fingerprint,
          'dimension': row.dimension,
          'embedding': '[${row.vector.join(',')}]',
        },
    ];
  }

  @override
  Future<T> transaction<T>(Future<T> Function(DatabaseBackend tx) body) async {
    _ensureOpen();
    transactions++;
    final before = Map<String, _VectorRow>.from(_rows);
    try {
      return await body(this);
    } catch (_) {
      _rows = before;
      rethrow;
    }
  }

  void _insert(String sql, List<Object?> parameters) {
    if (failNextInsert) {
      failNextInsert = false;
      throw StateError('injected insert failure');
    }
    if (parameters.length != 7 ||
        parameters[0] is! String ||
        parameters[1] is! String ||
        parameters[2] is! int ||
        parameters[3] is! String ||
        parameters[4] is! String ||
        parameters[5] is! int ||
        parameters[6] is! String) {
      throw StateError('Unexpected vector insert parameters: $parameters');
    }
    final table = _table(sql);
    final vector = _parseVector(parameters[6] as String);
    final dimension = parameters[5] as int;
    if (dimension != vector.length) throw StateError('Vector insert dimension does not match its literal');
    final row = _VectorRow(
      table: table,
      userId: parameters[0] as String,
      documentId: parameters[1] as String,
      chunkIndex: parameters[2] as int,
      contentHash: parameters[3] as String,
      fingerprint: parameters[4] as String,
      dimension: dimension,
      vector: vector,
    );
    _rows[_key(table, row.userId, row.documentId, row.chunkIndex)] = row;
  }

  void _validateSearchSql(String sql, List<Object?> parameters) {
    _requireSql(
      sql,
      RegExp(
        r'WHERE\s+user_id = \?\s+AND model_fingerprint = \?\s+AND dimension = \?'
        r'\s+AND public\.vector_dims\(embedding\) = \?\s+AND public\.vector_norm\(embedding\) > 0',
        caseSensitive: false,
      ),
      'vector search predicates',
    );
    _requireSql(
      sql,
      RegExp(r'ORDER BY\s+score DESC,\s*document_id,\s*chunk_index\s+LIMIT \?', caseSensitive: false),
      'vector search order',
    );
    if (parameters.length != 6 ||
        parameters[0] is! String ||
        parameters[1] is! String ||
        parameters[2] is! String ||
        parameters[3] is! int ||
        parameters[4] is! int ||
        parameters[5] is! int) {
      throw StateError('Unexpected vector search parameters: $parameters');
    }
    final vector = _parseVector(parameters[0] as String);
    final dimension = parameters[3] as int;
    if (dimension != vector.length || parameters[4] != dimension || (parameters[5] as int) <= 0) {
      throw StateError('Vector search parameters are bound in the wrong order: $parameters');
    }
  }

  void _validateListSql(String sql, List<Object?> parameters) {
    _requireSql(
      sql,
      RegExp(r'WHERE\s+user_id = \?\s+ORDER BY\s+document_id,\s*chunk_index', caseSensitive: false),
      'vector list',
    );
    if (parameters.length != 1 || parameters.single is! String) {
      throw StateError('Unexpected vector list parameters: $parameters');
    }
  }

  void _ensureOpen() {
    if (_closed) throw StateError('closed');
  }

  static String _table(String sql) {
    final memory = RegExp(r'\bmemory_vectors\b').hasMatch(sql);
    final conversation = RegExp(r'\bconversation_vectors\b').hasMatch(sql);
    if (memory == conversation) throw StateError('SQL must name exactly one vector table: $sql');
    return memory ? 'memory_vectors' : 'conversation_vectors';
  }

  static String _key(String table, String owner, String documentId, int chunkIndex) =>
      '$table\u0000$owner\u0000$documentId\u0000$chunkIndex';
}

final class _PostgresVectorInsertStatement implements DatabaseStatement {
  new(this._backend, this._sql);

  final PostgresVectorTestBackend _backend;
  final String _sql;
  var _closed = false;

  @override
  Future<void> close() async => _closed = true;

  @override
  Future<int> execute([List<Object?> parameters = const []]) async {
    if (_closed) throw StateError('closed statement');
    _backend._insert(_sql, parameters);
    return 1;
  }

  @override
  Future<List<Map<String, Object?>>> query([List<Object?> parameters = const []]) =>
      throw StateError('vector insert statements do not return rows');
}

final class _VectorRow {
  const new({
    required this.table,
    required this.userId,
    required this.documentId,
    required this.chunkIndex,
    required this.contentHash,
    required this.fingerprint,
    required this.dimension,
    required this.vector,
  });

  final String table;
  final String userId;
  final String documentId;
  final int chunkIndex;
  final String contentHash;
  final String fingerprint;
  final int dimension;
  final List<double> vector;
}

/// PostgreSQL schema backend double for vector gate tests.
final class PostgresVectorSchemaTestBackend implements DatabaseBackend {
  new _({
    required Set<String> relations,
    required Set<String> vectorIndexes,
    required this.extensionAvailable,
    required this.typeAvailable,
    required this.failCapability,
    required this.programmingFailure,
    required this.mismatchedVectorColumn,
    required this.failVectorExecuteAt,
  }) : relations = Set.of(relations),
       vectorIndexes = Set.of(vectorIndexes);

  factory empty() => PostgresVectorSchemaTestBackend._(
    relations: const {},
    vectorIndexes: const {},
    extensionAvailable: false,
    typeAvailable: false,
    failCapability: false,
    programmingFailure: false,
    mismatchedVectorColumn: false,
    failVectorExecuteAt: null,
  );

  factory current({
    bool extensionAvailable = true,
    bool typeAvailable = true,
    bool failCapability = false,
    bool programmingFailure = false,
    Set<String> vectorTables = const {},
    Set<String> vectorIndexes = const {},
    bool mismatchedVectorColumn = false,
    int? failVectorExecuteAt,
  }) => PostgresVectorSchemaTestBackend._(
    relations: {..._baseTables.map((table) => table.name), ...vectorTables},
    vectorIndexes: vectorIndexes,
    extensionAvailable: extensionAvailable,
    typeAvailable: typeAvailable,
    failCapability: failCapability,
    programmingFailure: programmingFailure,
    mismatchedVectorColumn: mismatchedVectorColumn,
    failVectorExecuteAt: failVectorExecuteAt,
  );

  final bool extensionAvailable;
  final bool typeAvailable;
  final bool failCapability;
  final bool programmingFailure;
  final bool mismatchedVectorColumn;
  final int? failVectorExecuteAt;
  final Set<String> relations;
  final Set<String> vectorIndexes;
  final List<({String sql, List<Object?> parameters})> queries = [];
  final List<String> executed = [];
  var transactions = 0;
  var authoritativeRows = 7;
  var _vectorExecuteCount = 0;

  @override
  Future<void> close() async {}

  @override
  Future<int> execute(String sql, [List<Object?> parameters = const []]) async {
    executed.add(sql);
    if (sql.contains('memory_vectors') || sql.contains('conversation_vectors')) {
      _vectorExecuteCount++;
      if (_vectorExecuteCount == failVectorExecuteAt) throw StateError('injected vector bootstrap failure');
    }
    final createTable = RegExp(r'^CREATE TABLE ([a-z_]+)').firstMatch(sql.trimLeft());
    if (createTable != null) relations.add(createTable.group(1)!);
    final createIndex = RegExp(r'^CREATE INDEX ([a-z_]+)').firstMatch(sql.trimLeft());
    if (createIndex != null && createIndex.group(1)!.contains('vectors')) {
      vectorIndexes.add(createIndex.group(1)!);
    }
    return 1;
  }

  @override
  Future<DatabaseStatement> prepare(String sql) => throw StateError('prepare is not expected');

  @override
  Future<List<Map<String, Object?>>> query(String sql, [List<Object?> parameters = const []]) async {
    queries.add((sql: sql, parameters: List.unmodifiable(parameters)));
    if (sql.contains('FROM pg_catalog.pg_extension')) {
      return [
        {'extension_available': extensionAvailable ? 1 : 0, 'type_available': typeAvailable ? 1 : 0},
      ];
    }
    if (sql.contains('CAST(CAST')) {
      if (programmingFailure) throw StateError('programming sentinel');
      if (failCapability) {
        throw StorageQueryException(operation: 'query', guidance: 'driver-secret');
      }
      return [
        {'cast_value': '[1,0]', 'dimensions': 2, 'distance': 0.0, 'norm': 1.0},
      ];
    }
    if (sql.contains('FROM information_schema.tables')) {
      return [
        for (final name in relations) {'table_name': name},
      ];
    }
    if (sql.contains('FROM information_schema.columns')) {
      final table = _table(parameters.single as String);
      return [for (final column in table.columns) _column(table, column)];
    }
    if (sql.contains("constraint_type = 'PRIMARY KEY'")) {
      final table = _table(parameters.single as String);
      return [
        for (final column in table.columns.where((column) => column.primaryKey)) {'column_name': column.name},
      ];
    }
    if (sql.contains('FROM pg_indexes')) return _indexes();
    if (sql.contains('SELECT id, epoch FROM dartclaw_schema')) {
      return [
        {'id': 1, 'epoch': 1},
      ];
    }
    throw StateError('Unexpected query: $sql');
  }

  @override
  Future<T> transaction<T>(Future<T> Function(DatabaseBackend tx) body) async {
    transactions++;
    final beforeRelations = Set<String>.of(relations);
    final beforeIndexes = Set<String>.of(vectorIndexes);
    final beforeRows = authoritativeRows;
    try {
      return await body(this);
    } catch (_) {
      relations
        ..clear()
        ..addAll(beforeRelations);
      vectorIndexes
        ..clear()
        ..addAll(beforeIndexes);
      authoritativeRows = beforeRows;
      rethrow;
    }
  }

  SchemaTable _table(String name) {
    if (name == 'memory_vectors' || name == 'conversation_vectors') {
      return _vectorTables.firstWhere((table) => table.name == name);
    }
    return _baseTables.firstWhere((table) => table.name == name);
  }

  Map<String, Object?> _column(SchemaTable table, SchemaColumn column) {
    final vector = column.type == 'PUBLIC.VECTOR';
    final mismatch = mismatchedVectorColumn && table.name == 'memory_vectors' && column.name == 'embedding';
    final identity = column.type == 'INTEGER' && column.primaryKey && !table.name.endsWith('_vectors');
    return {
      'column_name': column.name,
      'data_type': vector && !mismatch
          ? 'USER-DEFINED'
          : mismatch
          ? 'bytea'
          : _postgresType(column.type),
      'is_nullable': column.notNull || column.primaryKey ? 'NO' : 'YES',
      'column_default': identity ? null : _postgresDefault(column.defaultValue),
      'is_identity': identity ? 'YES' : 'NO',
      'udt_schema': vector && !mismatch ? 'public' : 'pg_catalog',
      'udt_name': vector && !mismatch ? 'vector' : _postgresType(column.type),
    };
  }

  List<Map<String, Object?>> _indexes() {
    final indexes = [
      ...SchemaIdentity.tasks.indexes,
      const SchemaIndex('memory_chunks_content_tsv_idx', 'memory_chunks', ['content_tsv']),
      const SchemaIndex('conversation_chunks_content_tsv_idx', 'conversation_chunks', ['content_tsv']),
      for (final index in SchemaIdentity.vectors.indexes)
        if (vectorIndexes.contains(index.name)) index,
    ];
    return [
      for (final index in indexes)
        {
          'indexname': index.name,
          'tablename': index.table,
          'indexdef':
              'CREATE ${index.unique ? 'UNIQUE ' : ''}INDEX ${index.name} ON app.${index.table} '
              'USING ${index.name.contains('content_tsv') ? 'gin' : 'btree'} (${index.columns.join(', ')})',
        },
    ];
  }
}

final _baseTables = <SchemaTable>[
  ...SchemaIdentity.tasks.tables,
  SchemaTable('memory_chunks', [
    ...SchemaIdentity.search.tables.firstWhere((table) => table.name == 'memory_chunks').columns,
    const SchemaColumn('content_tsv', 'TSVECTOR', notNull: true),
  ]),
  SchemaTable('conversation_chunks', [
    ...SchemaIdentity.search.tables.firstWhere((table) => table.name == 'conversation_chunks').columns,
    const SchemaColumn('content_tsv', 'TSVECTOR', notNull: true),
  ]),
  const SchemaTable('dartclaw_schema', [
    SchemaColumn('id', 'BIGINT', primaryKey: true),
    SchemaColumn('epoch', 'BIGINT', notNull: true),
  ]),
];

final _vectorTables = <SchemaTable>[
  for (final table in SchemaIdentity.vectors.tables)
    SchemaTable(table.name, [
      for (final column in table.columns)
        SchemaColumn(
          column.name,
          column.name == 'embedding' ? 'PUBLIC.VECTOR' : column.type,
          notNull: column.notNull,
          primaryKey: column.primaryKey,
        ),
    ]),
];

String _postgresType(String type) => switch (type) {
  'TEXT' => 'text',
  'INTEGER' || 'BIGINT' => 'bigint',
  'REAL' => 'double precision',
  'BLOB' => 'bytea',
  'TSVECTOR' => 'tsvector',
  _ => type.toLowerCase(),
};

String? _postgresDefault(String? value) => value?.replaceAll("datetime('now')", 'CURRENT_TIMESTAMP::text');

void _requireSql(String sql, RegExp expected, String operation) {
  if (!expected.hasMatch(sql)) throw StateError('Unexpected $operation SQL: $sql');
}

List<double> _parseVector(String value) {
  if (!value.startsWith('[') || !value.endsWith(']')) throw StateError('Unexpected vector literal: $value');
  return value.substring(1, value.length - 1).split(',').map(double.parse).toList(growable: false);
}

double _dot(List<double> left, List<double> right) {
  var value = 0.0;
  for (var index = 0; index < left.length; index++) {
    value += left[index] * right[index];
  }
  return value;
}

double _norm(List<double> vector) => math.sqrt(_dot(vector, vector));
