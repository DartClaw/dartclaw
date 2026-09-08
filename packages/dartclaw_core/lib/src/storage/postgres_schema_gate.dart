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
    ...SchemaIdentity.search.tables.single.columns,
    const SchemaColumn('content_tsv', 'TSVECTOR', notNull: true),
  ]);
  static const _memoryIndex = SchemaIndex('memory_chunks_content_tsv_idx', 'memory_chunks', ['content_tsv']);

  /// Creates an empty schema or validates an exact current schema.
  static Future<void> prepare(DatabaseBackend backend, {required String databaseIdentity}) async {
    final relations = await backend.query('''
      SELECT table_name
      FROM information_schema.tables
      WHERE table_schema = current_schema()
    ''');
    final found = relations.map((row) => row['table_name']).whereType<String>().toSet();
    if (found.isEmpty) {
      await _bootstrap(backend);
      return;
    }

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
      await tx.execute(_markerTableSql);
      await tx.execute(_markerRowSql);
    });
  }

  static Future<List<String>> _differences(DatabaseBackend backend, Set<String> found) async {
    final differences = <String>[];
    final tables = [
      ...SchemaIdentity.tasks.tables,
      _memoryTable,
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
    for (final index in [...SchemaIdentity.tasks.indexes, _memoryIndex]) {
      final actual = byName[index.name];
      final definition = actual?['indexdef'] as String?;
      final columns = definition == null ? const <String>[] : _indexColumns(definition);
      if (actual == null ||
          actual['tablename'] != index.table ||
          definition!.toUpperCase().contains(' UNIQUE ') != index.unique ||
          !_sameList(columns, index.columns) ||
          index == _memoryIndex &&
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
