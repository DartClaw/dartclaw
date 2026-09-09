import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'schema_identity.dart';

/// Classifies and prepares the current PostgreSQL schema.
abstract final class PostgresSchemaGate {
  static const _markerTableSql = '''
    CREATE TABLE dartclaw_schema (
      id bigint PRIMARY KEY CHECK (id = 1),
      epoch bigint NOT NULL
    )
  ''';
  static const _markerRowSql = 'INSERT INTO dartclaw_schema (id, epoch) VALUES (1, 1)';
  static final _memoryTable = SchemaTable('memory_chunks', [
    ...SchemaIdentity.search.tables.firstWhere((table) => table.name == 'memory_chunks').columns,
    const SchemaColumn('content_tsv', 'TSVECTOR', notNull: true),
  ]);
  static const _memoryIndex = SchemaIndex('memory_chunks_content_tsv_idx', 'memory_chunks', ['content_tsv']);
  static final _conversationTable = SchemaTable('conversation_chunks', [
    ...SchemaIdentity.search.tables.firstWhere((table) => table.name == 'conversation_chunks').columns,
    const SchemaColumn('content_tsv', 'TSVECTOR', notNull: true),
  ]);
  static const _conversationIndex = SchemaIndex('conversation_chunks_content_tsv_idx', 'conversation_chunks', [
    'content_tsv',
  ]);
  static final _vectorTables = SchemaIdentity.vectors.tables.map(_postgresVectorTable).toList(growable: false);
  static final _vectorIndexes = SchemaIdentity.vectors.indexes;

  /// Verifies that pgvector is installed in public and usable by the runtime role.
  static Future<void> preflightVectorExtension(DatabaseBackend backend, {required String databaseIdentity}) async {
    List<Map<String, Object?>> catalog;
    try {
      catalog = await backend.query('''
        SELECT
          EXISTS (
            SELECT 1
            FROM pg_catalog.pg_extension extension
            JOIN pg_catalog.pg_namespace namespace ON namespace.oid = extension.extnamespace
            WHERE extension.extname = 'vector' AND namespace.nspname = 'public'
          )::integer AS extension_available,
          EXISTS (
            SELECT 1
            FROM pg_catalog.pg_type type
            JOIN pg_catalog.pg_namespace namespace ON namespace.oid = type.typnamespace
            WHERE type.typname = 'vector' AND namespace.nspname = 'public'
          )::integer AS type_available
      ''');
    } on StorageException {
      throw _vectorExtensionRefusal(databaseIdentity, ['public vector extension catalog is inaccessible']);
    }
    late final Map<String, Object?> catalogProof;
    try {
      catalogProof = _singleResult(catalog, 'vector extension catalog');
      _resultFlag(catalogProof, 'extension_available');
      _resultFlag(catalogProof, 'type_available');
    } on FormatException {
      throw _vectorExtensionRefusal(databaseIdentity, ['public vector extension catalog returned an invalid result']);
    }
    if (catalogProof['extension_available'] != 1 || catalogProof['type_available'] != 1) {
      throw _vectorExtensionRefusal(databaseIdentity, [
        if (catalogProof['extension_available'] != 1) 'missing extension vector in public',
        if (catalogProof['type_available'] != 1) 'missing type public.vector',
      ]);
    }

    try {
      final capability = await backend.query(
        '''
          SELECT CAST(CAST(? AS public.vector) AS text) AS cast_value,
                 public.vector_dims(CAST(? AS public.vector)) AS dimensions,
                 CAST(? AS public.vector) OPERATOR(public.<=>) CAST(? AS public.vector) AS distance,
                 public.vector_norm(CAST(? AS public.vector)) AS norm
        ''',
        const ['[1,0]', '[1,0]', '[1,0]', '[1,0]', '[1,0]'],
      );
      final proof = _singleResult(capability, 'vector capability');
      if (_resultString(proof, 'cast_value') != '[1,0]' ||
          _resultInt(proof, 'dimensions') != 2 ||
          _resultFiniteNumber(proof, 'distance') != 0 ||
          _resultFiniteNumber(proof, 'norm') != 1) {
        throw const FormatException('unexpected vector capability result');
      }
    } on StorageException {
      throw _vectorExtensionRefusal(databaseIdentity, [
        'public.vector cast, public.vector_dims, public.vector_norm or public.<=> is unavailable to the runtime role',
      ]);
    } on FormatException {
      throw _vectorExtensionRefusal(databaseIdentity, ['public.vector capability checks returned an invalid result']);
    }
  }

  /// Creates or validates the optional derived vector projection.
  static Future<void> prepareVectorProjection(DatabaseBackend backend, {required String databaseIdentity}) async {
    await validateCurrent(backend, databaseIdentity: databaseIdentity);
    final found = await _relations(backend);
    final present = _vectorTables.where((table) => found.contains(table.name)).toList(growable: false);
    final indexes = await _indexes(backend);
    final presentIndexes = _vectorIndexes
        .where((index) => indexes.any((row) => row['indexname'] == index.name))
        .toList(growable: false);
    if (present.isEmpty && presentIndexes.isEmpty) {
      await _bootstrapVectors(backend);
      return;
    }
    if (present.length != _vectorTables.length || presentIndexes.length != _vectorIndexes.length) {
      throw _vectorProjectionRefusal(databaseIdentity, [
        for (final table in _vectorTables)
          if (!found.contains(table.name)) 'missing table ${table.name}',
        for (final index in _vectorIndexes)
          if (!indexes.any((row) => row['indexname'] == index.name)) 'missing index ${index.name}',
      ]);
    }
    final differences = await _vectorDifferences(backend, indexes);
    if (differences.isNotEmpty) throw _vectorProjectionRefusal(databaseIdentity, differences);
  }

  /// Creates an empty schema or validates an exact current schema.
  static Future<void> prepare(DatabaseBackend backend, {required String databaseIdentity}) async {
    final found = await _relations(backend);
    if (found.isEmpty) {
      await _bootstrap(backend);
      return;
    }

    await _validate(backend, found, databaseIdentity);
  }

  /// Validates an exact current schema without bootstrapping an empty namespace.
  static Future<void> validateCurrent(DatabaseBackend backend, {required String databaseIdentity}) async {
    await _validate(backend, await _relations(backend), databaseIdentity);
  }

  static Future<void> _validate(DatabaseBackend backend, Set<String> found, String databaseIdentity) async {
    final differences = await _differences(backend, found);
    final epoch = await _epoch(backend, found);
    if (epoch.isCurrent && differences.isEmpty) return;
    throw SchemaIncompatibleException(
      storeName: databaseIdentity,
      foundEpoch: epoch.found,
      differences: [...differences, ...epoch.differences],
      action: 'Back up $databaseIdentity, then reset/recreate it for this release or restore a compatible database.',
    );
  }

  static Future<Set<String>> _relations(DatabaseBackend backend) async {
    final relations = await backend.query('''
      SELECT table_name
      FROM information_schema.tables
      WHERE table_schema = current_schema()
    ''');
    return relations.map((row) => row['table_name']).whereType<String>().toSet();
  }

  static Future<void> _bootstrap(DatabaseBackend backend) {
    return backend.transaction((tx) async {
      final statements = [...SchemaIdentity.tasks.bootstrapStatements];
      final workflowStep = statements.removeAt(
        statements.indexWhere((sql) => sql.trimLeft().startsWith('CREATE TABLE workflow_step_executions')),
      );
      final taskIndex = statements.indexWhere((sql) => sql.trimLeft().startsWith('CREATE TABLE tasks'));
      statements.insert(taskIndex + 1, workflowStep);
      for (final sql in statements) {
        await tx.execute(_postgresSql(sql));
      }
      await tx.execute(_postgresSql(SchemaIdentity.search.bootstrapStatements.first));
      await tx.execute('ALTER TABLE memory_chunks ADD COLUMN content_tsv tsvector NOT NULL');
      await tx.execute('CREATE INDEX memory_chunks_content_tsv_idx ON memory_chunks USING gin (content_tsv)');
      final conversationTable = SchemaIdentity.search.bootstrapStatements.firstWhere(
        (sql) => sql.trimLeft().startsWith('CREATE TABLE conversation_chunks'),
      );
      await tx.execute(_postgresSql(conversationTable));
      await tx.execute('ALTER TABLE conversation_chunks ADD COLUMN content_tsv tsvector NOT NULL');
      await tx.execute(
        'CREATE INDEX conversation_chunks_content_tsv_idx ON conversation_chunks USING gin (content_tsv)',
      );
      await tx.execute(_markerTableSql);
      await tx.execute(_markerRowSql);
    });
  }

  static Future<void> _bootstrapVectors(DatabaseBackend backend) {
    return backend.transaction((tx) async {
      for (final sql in SchemaIdentity.vectors.bootstrapStatements) {
        await tx.execute(_postgresVectorSql(sql));
      }
    });
  }

  static Future<List<String>> _vectorDifferences(DatabaseBackend backend, List<Map<String, Object?>> indexes) async {
    final differences = <String>[];
    for (final table in _vectorTables) {
      final rows = await backend.query(
        '''
          SELECT column_name, data_type, is_nullable, column_default, is_identity, udt_schema, udt_name
          FROM information_schema.columns
          WHERE table_schema = current_schema() AND table_name = ?
        ''',
        [table.name],
      );
      final live = {for (final row in rows) row['column_name'] as String: row};
      final primaryKeys = await backend.query(
        '''
          SELECT kcu.column_name
          FROM information_schema.table_constraints tc
          JOIN information_schema.key_column_usage kcu
            ON tc.constraint_name = kcu.constraint_name AND tc.constraint_schema = kcu.constraint_schema
          WHERE tc.constraint_schema = current_schema()
            AND tc.table_name = ? AND tc.constraint_type = 'PRIMARY KEY'
          ORDER BY kcu.ordinal_position
        ''',
        [table.name],
      );
      final primaryNames = primaryKeys.map((row) => row['column_name']).whereType<String>().toList(growable: false);
      final expectedPrimary = table.columns.where((column) => column.primaryKey).map((column) => column.name).toList();
      if (!_sameList(primaryNames, expectedPrimary)) {
        differences.add('mismatched primary key ${table.name}');
      }
      for (final column in table.columns) {
        final actual = live[column.name];
        if (actual == null) {
          differences.add('missing column ${table.name}.${column.name}');
          continue;
        }
        final typeMatches = column.type == 'PUBLIC.VECTOR'
            ? actual['data_type'] == 'USER-DEFINED' &&
                  actual['udt_schema'] == 'public' &&
                  actual['udt_name'] == 'vector'
            : actual['data_type'] == _postgresType(column.type);
        if (!typeMatches ||
            (actual['is_nullable'] == 'NO') != column.notNull ||
            primaryNames.contains(column.name) != column.primaryKey ||
            actual['is_identity'] == 'YES' ||
            actual['column_default'] != null) {
          differences.add('mismatched column ${table.name}.${column.name}');
        }
      }
    }

    final byName = {for (final row in indexes) row['indexname'] as String: row};
    for (final index in _vectorIndexes) {
      final actual = byName[index.name];
      final definition = actual?['indexdef'] as String?;
      if (actual == null ||
          actual['tablename'] != index.table ||
          definition!.toUpperCase().contains(' UNIQUE ') != index.unique ||
          !_sameList(_indexColumns(definition), index.columns) ||
          !RegExp(r'\bUSING btree\s*\(', caseSensitive: false).hasMatch(definition) ||
          RegExp(r'\bWHERE\b', caseSensitive: false).hasMatch(definition)) {
        differences.add('missing or mismatched index ${index.name}');
      }
    }
    return differences;
  }

  static Future<List<Map<String, Object?>>> _indexes(DatabaseBackend backend) => backend.query('''
      SELECT indexname, tablename, indexdef
      FROM pg_indexes
      WHERE schemaname = current_schema()
    ''');

  static Future<List<String>> _differences(DatabaseBackend backend, Set<String> found) async {
    final differences = <String>[];
    final tables = [
      ...SchemaIdentity.tasks.tables,
      _memoryTable,
      _conversationTable,
      const SchemaTable('dartclaw_schema', [
        SchemaColumn('id', 'BIGINT', primaryKey: true),
        SchemaColumn('epoch', 'BIGINT', notNull: true),
      ]),
    ];
    for (final table in tables) {
      if (!found.contains(table.name)) {
        differences.add('missing table ${table.name}');
        continue;
      }
      final rows = await backend.query(
        '''
          SELECT column_name, data_type, is_nullable, column_default, is_identity
          FROM information_schema.columns
          WHERE table_schema = current_schema() AND table_name = ?
          ''',
        [table.name],
      );
      final primaryKeys = await backend.query(
        '''
          SELECT kcu.column_name
          FROM information_schema.table_constraints tc
          JOIN information_schema.key_column_usage kcu
            ON tc.constraint_name = kcu.constraint_name AND tc.constraint_schema = kcu.constraint_schema
          WHERE tc.constraint_schema = current_schema()
            AND tc.table_name = ? AND tc.constraint_type = 'PRIMARY KEY'
          ''',
        [table.name],
      );
      final primaryNames = primaryKeys.map((row) => row['column_name']).whereType<String>().toSet();
      final live = {for (final row in rows) row['column_name'] as String: row};
      for (final column in table.columns) {
        final actual = live[column.name];
        if (actual == null) {
          differences.add('missing column ${table.name}.${column.name}');
          continue;
        }
        final identityDefault = column.type == 'INTEGER' && column.primaryKey;
        if (actual['data_type'] != _postgresType(column.type) ||
            (actual['is_nullable'] == 'NO') != column.notNull && !column.primaryKey ||
            primaryNames.contains(column.name) != column.primaryKey ||
            (actual['is_identity'] == 'YES') != identityDefault ||
            !_sameDefault(actual['column_default'] as String?, column.defaultValue, identityDefault)) {
          differences.add('mismatched column ${table.name}.${column.name}');
        }
      }
    }

    final indexes = await backend.query('''
      SELECT indexname, tablename, indexdef
      FROM pg_indexes
      WHERE schemaname = current_schema()
    ''');
    final byName = {for (final row in indexes) row['indexname'] as String: row};
    for (final index in [...SchemaIdentity.tasks.indexes, _memoryIndex, _conversationIndex]) {
      final actual = byName[index.name];
      final definition = actual?['indexdef'] as String?;
      final columns = definition == null ? const <String>[] : _indexColumns(definition);
      if (actual == null ||
          actual['tablename'] != index.table ||
          definition!.toUpperCase().contains(' UNIQUE ') != index.unique ||
          !_sameList(columns, index.columns) ||
          (index == _memoryIndex || index == _conversationIndex) &&
              (!RegExp(r'\bUSING gin\s*\(', caseSensitive: false).hasMatch(definition) ||
                  RegExp(r'\bWHERE\b', caseSensitive: false).hasMatch(definition))) {
        differences.add('missing or mismatched index ${index.name}');
      }
    }
    return differences;
  }

  static Future<({bool isCurrent, String found, List<String> differences})> _epoch(
    DatabaseBackend backend,
    Set<String> found,
  ) async {
    if (!found.contains('dartclaw_schema')) {
      return (isCurrent: false, found: 'absent', differences: const ['schema marker table is absent']);
    }
    try {
      final rows = await backend.query('SELECT id, epoch FROM dartclaw_schema');
      if (rows.isEmpty) {
        return (isCurrent: false, found: 'empty', differences: const ['schema marker row is absent']);
      }
      if (rows.length != 1) {
        return (isCurrent: false, found: 'duplicated', differences: ['schema marker has ${rows.length} rows']);
      }
      final row = rows.single;
      if (row['id'] != 1 || row['epoch'] is! int) {
        return (isCurrent: false, found: 'non-integer', differences: const ['schema marker row is malformed']);
      }
      final value = row['epoch'] as int;
      return (
        isCurrent: value == SchemaIdentity.currentEpoch,
        found: '$value',
        differences: value == SchemaIdentity.currentEpoch ? const <String>[] : ['unsupported schema epoch $value'],
      );
    } on StorageException {
      return (isCurrent: false, found: 'malformed', differences: const ['schema marker is unreadable']);
    }
  }

  static SchemaIncompatibleException _vectorExtensionRefusal(String databaseIdentity, List<String> differences) {
    return SchemaIncompatibleException(
      storeName: databaseIdentity,
      foundEpoch: 'vector extension unavailable',
      differences: differences,
      action: 'Ask a database administrator to run CREATE EXTENSION vector WITH SCHEMA public.',
    );
  }

  static SchemaIncompatibleException _vectorProjectionRefusal(String databaseIdentity, List<String> differences) {
    return SchemaIncompatibleException(
      storeName: databaseIdentity,
      foundEpoch: '${SchemaIdentity.currentEpoch}',
      differences: differences,
      action: 'Reset and rebuild only memory_vectors and conversation_vectors.',
    );
  }
}

String _postgresSql(String sql) => sql
    .replaceAll(
      RegExp(r'INTEGER PRIMARY KEY AUTOINCREMENT', caseSensitive: false),
      'bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY',
    )
    .replaceAll(
      RegExp(r'INTEGER PRIMARY KEY', caseSensitive: false),
      'bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY',
    )
    .replaceAll(RegExp(r'\bINTEGER\b', caseSensitive: false), 'bigint')
    .replaceAll(RegExp(r'\bREAL\b', caseSensitive: false), 'double precision')
    .replaceAll(RegExp(r'\bBLOB\b', caseSensitive: false), 'bytea')
    .replaceAll(RegExp(r"\(?datetime\('now'\)\)?", caseSensitive: false), '(CURRENT_TIMESTAMP::text)');

String _postgresVectorSql(String sql) => _postgresSql(sql).replaceAll(RegExp(r'\bbytea\b'), 'public.vector');

SchemaTable _postgresVectorTable(SchemaTable table) => SchemaTable(table.name, [
  for (final column in table.columns)
    SchemaColumn(
      column.name,
      column.name == 'embedding' ? 'PUBLIC.VECTOR' : column.type,
      notNull: column.notNull,
      defaultValue: column.defaultValue,
      primaryKey: column.primaryKey,
    ),
]);

String _postgresType(String sqliteType) => switch (sqliteType) {
  'TEXT' => 'text',
  'INTEGER' => 'bigint',
  'REAL' => 'double precision',
  'BLOB' => 'bytea',
  _ => sqliteType.toLowerCase(),
};

bool _sameDefault(String? actual, String? expected, bool identity) {
  if (identity) return actual == null;
  if (expected == null) return actual == null;
  final normalized = actual?.toLowerCase().replaceAll(RegExp(r'[()\s]'), '').replaceAll('::text', '');
  final wanted = expected
      .toLowerCase()
      .replaceAll("datetime('now')", 'current_timestamp')
      .replaceAll(RegExp(r'[()\s]'), '');
  return normalized == wanted;
}

List<String> _indexColumns(String definition) {
  final start = definition.lastIndexOf('(');
  final end = definition.lastIndexOf(')');
  if (start < 0 || end <= start) return const [];
  return definition
      .substring(start + 1, end)
      .split(',')
      .map((column) => column.trim().replaceAll('"', ''))
      .toList(growable: false);
}

bool _sameList(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

Map<String, Object?> _singleResult(List<Map<String, Object?>> rows, String name) {
  if (rows.length != 1) throw FormatException('$name must return one row');
  return rows.single;
}

int _resultFlag(Map<String, Object?> row, String name) {
  final value = row[name];
  if (value is! int || value != 0 && value != 1) throw FormatException('$name must be 0 or 1');
  return value;
}

String _resultString(Map<String, Object?> row, String name) {
  final value = row[name];
  if (value is! String) throw FormatException('$name must be text');
  return value;
}

int _resultInt(Map<String, Object?> row, String name) {
  final value = row[name];
  if (value is! int) throw FormatException('$name must be an integer');
  return value;
}

double _resultFiniteNumber(Map<String, Object?> row, String name) {
  final value = row[name];
  if (value is! num || !value.toDouble().isFinite) throw FormatException('$name must be finite numeric data');
  return value.toDouble();
}
