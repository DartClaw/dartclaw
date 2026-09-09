import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'index_reconciler.dart';
import 'schema_identity.dart';

/// Structural state found by [SqliteSchemaGate.inspect].
enum SqliteSchemaState {
  /// No application-owned or foreign object exists.
  empty,

  /// The current marker and every required object agree.
  current,

  /// Every required released object exists, but the marker does not.
  releasedUnmarked,

  /// The marker or required structure cannot be used by this release.
  incompatible,
}

/// Read-only result of inspecting one SQLite store.
final class SqliteSchemaInspection {
  /// Creates an inspection result.
  const new({required this.state, required this.storeName, required this.foundEpoch, this.differences = const []});

  /// Classified store state.
  final SqliteSchemaState state;

  /// Caller-supplied store name.
  final String storeName;

  /// Human-readable marker state.
  final String foundEpoch;

  /// Required-object or marker differences.
  final List<String> differences;
}

/// Carries derived-search health context and an optional complete projection.
final class SqliteSearchRebuild {
  /// Creates a complete-source rebuild contract.
  const new({
    required this.manifestRevision,
    required this.manifestFingerprint,
    required this.healthStore,
    this.populate,
    this.authenticateComplete,
    this.corpora = const [],
  });

  /// Canonical collection revision projected by [populate].
  final int manifestRevision;

  /// Canonical manifest fingerprint projected by [populate].
  final String manifestFingerprint;

  /// Durable derived-index evidence store.
  final IndexHealthStore healthStore;

  /// Populates the replacement through the active transaction handle.
  ///
  /// If either source callback is absent, preparation refuses with degraded evidence.
  final Future<void> Function(DatabaseBackend tx)? populate;

  /// Confirms that the source still matches the projected manifest.
  final Future<bool> Function()? authenticateComplete;

  /// Complete derived corpora populated and authenticated in list order.
  final List<SqliteSearchCorpusRebuild> corpora;
}

/// One complete corpus source used while rebuilding the shared search store.
final class SqliteSearchCorpusRebuild {
  /// Creates a corpus rebuild pair.
  const new({required this.populate, required this.authenticateComplete});

  /// Populates this corpus through the active transaction handle.
  final Future<void> Function(DatabaseBackend tx) populate;

  /// Confirms the authoritative source still matches what was populated.
  final Future<bool> Function() authenticateComplete;
}

/// Classifies and prepares SQLite schemas before repository construction.
abstract final class SqliteSchemaGate {
  static const _markerTableSql = '''
    CREATE TABLE dartclaw_schema (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      epoch INTEGER NOT NULL CHECK (typeof(epoch) = 'integer')
    )
  ''';
  static const _markerRowSql = 'INSERT INTO dartclaw_schema (id, epoch) VALUES (1, 1)';

  /// Inspects [backend] without changing schema or data.
  static Future<SqliteSchemaInspection> inspect(
    DatabaseBackend backend,
    SchemaIdentity identity, {
    required String storeName,
  }) async {
    final objects = await backend.query('''
      SELECT type, name, tbl_name, sql
      FROM sqlite_master
      WHERE name NOT LIKE 'sqlite_%'
      ORDER BY type, name
    ''');
    if (objects.isEmpty) {
      return SqliteSchemaInspection(state: SqliteSchemaState.empty, storeName: storeName, foundEpoch: 'absent');
    }

    final differences = await _structureDifferences(backend, identity, objects);
    final marker = objects
        .where((row) => row['type'] != 'trigger' && (row['name'] as String).toLowerCase() == 'dartclaw_schema')
        .firstOrNull;
    if (marker == null) {
      return SqliteSchemaInspection(
        state: differences.isEmpty ? SqliteSchemaState.releasedUnmarked : SqliteSchemaState.incompatible,
        storeName: storeName,
        foundEpoch: 'absent',
        differences: differences,
      );
    }

    if (marker['type'] != 'table') {
      return SqliteSchemaInspection(
        state: SqliteSchemaState.incompatible,
        storeName: storeName,
        foundEpoch: 'malformed',
        differences: [...differences, 'schema marker name is occupied by ${marker['type']}'],
      );
    }

    final epoch = await _readEpoch(backend);
    final markerDifferences = _normalizeSql(marker['sql'] as String?) == _normalizeSql(_markerTableSql)
        ? const <String>[]
        : const ['schema marker table is malformed'];
    final allDifferences = [...differences, ...markerDifferences, ...epoch.differences];
    return SqliteSchemaInspection(
      state: epoch.isCurrent && allDifferences.isEmpty ? SqliteSchemaState.current : SqliteSchemaState.incompatible,
      storeName: storeName,
      foundEpoch: epoch.found,
      differences: allDifferences,
    );
  }

  /// Prepares the authoritative task store or refuses it without mutation.
  static Future<void> prepareTasks(DatabaseBackend backend, {required String storeName}) async {
    await backend.execute('PRAGMA journal_mode=WAL');
    await backend.execute('PRAGMA foreign_keys=ON');
    final inspection = await inspect(backend, SchemaIdentity.tasks, storeName: storeName);
    switch (inspection.state) {
      case SqliteSchemaState.empty:
        await _bootstrap(backend, SchemaIdentity.tasks);
      case SqliteSchemaState.releasedUnmarked:
        await _adopt(backend);
      case SqliteSchemaState.current:
        return;
      case SqliteSchemaState.incompatible:
        throw _authoritativeRefusal(inspection);
    }
  }

  /// Prepares the derived search store, rebuilding incompatible owned objects when a complete source is supplied.
  ///
  /// Supply [rebuild] whenever health evidence exists, even if its source callbacks
  /// are unavailable. Without that context, refusal cannot identify a health file.
  static Future<void> prepareSearch(
    DatabaseBackend backend, {
    required String storeName,
    SqliteSearchRebuild? rebuild,
  }) async {
    final inspection = await inspect(backend, SchemaIdentity.search, storeName: storeName);
    switch (inspection.state) {
      case SqliteSchemaState.empty:
        await _bootstrap(backend, SchemaIdentity.search);
        return;
      case SqliteSchemaState.releasedUnmarked:
        await _adopt(backend);
        return;
      case SqliteSchemaState.current:
        return;
      case SqliteSchemaState.incompatible:
        if (rebuild == null) {
          throw _searchRefusal(inspection, ['complete supported rebuild inputs are unavailable']);
        }
    }

    await _rebuildSearch(backend, inspection, rebuild);
  }

  static Future<void> _bootstrap(DatabaseBackend backend, SchemaIdentity identity) {
    return backend.transaction((tx) async {
      for (final sql in identity.bootstrapStatements) {
        await tx.execute(sql);
      }
      await tx.execute(_markerTableSql);
      await tx.execute(_markerRowSql);
    });
  }

  static Future<void> _adopt(DatabaseBackend backend) {
    return backend.transaction((tx) async {
      await tx.execute(_markerTableSql);
      await tx.execute(_markerRowSql);
    });
  }

  static Future<void> _rebuildSearch(
    DatabaseBackend backend,
    SqliteSchemaInspection inspection,
    SqliteSearchRebuild rebuild,
  ) async {
    IndexHealthEvidence previous;
    try {
      previous = await rebuild.healthStore.read(
        canonicalRevision: rebuild.manifestRevision,
        canonicalFingerprint: rebuild.manifestFingerprint,
      );
    } on FormatException catch (error) {
      throw _searchRefusal(inspection, ['index health evidence is unparseable: $error']);
    } on FileSystemException catch (error) {
      throw _searchRefusal(inspection, ['index health evidence is unreadable: $error']);
    }

    var stage = 'unavailable-source';
    try {
      if ((rebuild.populate == null) != (rebuild.authenticateComplete == null)) {
        throw StateError('complete supported rebuild inputs are unavailable');
      }
      final corpora = [
        if (rebuild.populate != null && rebuild.authenticateComplete != null)
          SqliteSearchCorpusRebuild(populate: rebuild.populate!, authenticateComplete: rebuild.authenticateComplete!),
        ...rebuild.corpora,
      ];
      if (corpora.isEmpty) {
        throw StateError('complete supported rebuild inputs are unavailable');
      }
      stage = 'record-rebuilding';
      await rebuild.healthStore.recordRebuilding(
        canonicalRevision: rebuild.manifestRevision,
        canonicalFingerprint: rebuild.manifestFingerprint,
        previous: previous,
      );
      await backend.transaction((tx) async {
        stage = 'schema-rebuild';
        for (final sql in SchemaIdentity.search.dropStatements) {
          await tx.execute(sql);
        }
        for (final sql in SchemaIdentity.search.bootstrapStatements) {
          await tx.execute(sql);
        }
        await tx.execute(_markerTableSql);
        await tx.execute(_markerRowSql);
        stage = 'populate';
        for (final corpus in corpora) {
          await corpus.populate(tx);
        }
        stage = 'authenticate';
        for (final corpus in corpora) {
          if (!await corpus.authenticateComplete()) {
            throw StateError('derived rebuild source changed before completion');
          }
        }
        stage = 'publish';
        await rebuild.healthStore.recordHealthy(
          canonicalRevision: rebuild.manifestRevision,
          canonicalFingerprint: rebuild.manifestFingerprint,
        );
        stage = 'commit';
      });
    } catch (error, stackTrace) {
      try {
        await rebuild.healthStore.recordDegraded(
          canonicalRevision: rebuild.manifestRevision,
          canonicalFingerprint: rebuild.manifestFingerprint,
          stage: stage,
          reason: error,
          previous: previous,
        );
      } catch (_) {}
      Error.throwWithStackTrace(_searchRefusal(inspection, ['$stage failed: $error']), stackTrace);
    }
  }

  static Future<List<String>> _structureDifferences(
    DatabaseBackend backend,
    SchemaIdentity identity,
    List<Map<String, Object?>> objects,
  ) async {
    final differences = <String>[];
    final byName = {for (final row in objects) row['name'] as String: row};
    for (final table in identity.tables) {
      final object = byName[table.name];
      if (object == null || object['type'] != 'table') {
        differences.add('missing table ${table.name}');
        continue;
      }
      final liveColumns = {
        for (final row in await backend.query('PRAGMA table_info(${_identifier(table.name)})'))
          row['name'] as String: row,
      };
      for (final column in table.columns) {
        final live = liveColumns[column.name];
        if (live == null) {
          differences.add('missing column ${table.name}.${column.name}');
          continue;
        }
        final liveType = (live['type'] as String).toUpperCase();
        final liveNotNull = live['notnull'] == 1;
        final liveDefault = live['dflt_value'] as String?;
        final livePrimaryKey = live['pk'] != 0;
        if (liveType != column.type ||
            liveNotNull != column.notNull ||
            liveDefault != column.defaultValue ||
            livePrimaryKey != column.primaryKey) {
          differences.add('mismatched column ${table.name}.${column.name}');
        }
      }
    }
    for (final index in identity.indexes) {
      final object = byName[index.name];
      if (object == null || object['type'] != 'index' || object['tbl_name'] != index.table) {
        differences.add('missing or mismatched index ${index.name}');
        continue;
      }
      final indexRows = await backend.query('PRAGMA index_list(${_identifier(index.table)})');
      final listed = indexRows.where((row) => row['name'] == index.name).firstOrNull;
      final columns = (await backend.query('PRAGMA index_info(${_identifier(index.name)})'))
          .map((row) => row['name'])
          .toList(growable: false);
      if (listed == null || (listed['unique'] == 1) != index.unique || !_sameList(columns, index.columns)) {
        differences.add('mismatched index ${index.name}');
      }
    }
    for (final required in identity.sqliteObjects) {
      final object = byName[required.name];
      if (object == null ||
          object['type'] != required.type ||
          object['tbl_name'] != required.table ||
          _normalizeSql(object['sql'] as String?) != _normalizeSql(required.sql)) {
        differences.add('missing or mismatched ${required.type} ${required.name}');
      }
    }
    return differences;
  }

  static Future<({bool isCurrent, String found, List<String> differences})> _readEpoch(DatabaseBackend backend) async {
    List<Map<String, Object?>> rows;
    try {
      rows = await backend.query('SELECT id, epoch, typeof(epoch) AS epoch_type FROM dartclaw_schema');
    } on Exception catch (error) {
      return (isCurrent: false, found: 'malformed', differences: ['schema marker is unreadable: $error']);
    }
    if (rows.isEmpty) {
      return (isCurrent: false, found: 'empty', differences: ['schema marker row is absent']);
    }
    if (rows.length != 1) {
      return (isCurrent: false, found: 'duplicated', differences: ['schema marker has ${rows.length} rows']);
    }
    final row = rows.single;
    if (row['id'] != 1 || row['epoch_type'] != 'integer' || row['epoch'] is! int) {
      return (isCurrent: false, found: 'non-integer', differences: ['schema marker row is malformed']);
    }
    final epoch = row['epoch'] as int;
    return (
      isCurrent: epoch == SchemaIdentity.currentEpoch,
      found: '$epoch',
      differences: epoch == SchemaIdentity.currentEpoch ? const <String>[] : ['unsupported schema epoch $epoch'],
    );
  }

  static SchemaIncompatibleException _authoritativeRefusal(SqliteSchemaInspection inspection) {
    return SchemaIncompatibleException(
      storeName: inspection.storeName,
      foundEpoch: inspection.foundEpoch,
      differences: inspection.differences,
      action: 'Back up ${inspection.storeName}, then reset/recreate it for this release or restore a compatible store.',
    );
  }

  static SchemaIncompatibleException _searchRefusal(SqliteSchemaInspection inspection, List<String> extra) {
    return SchemaIncompatibleException(
      storeName: inspection.storeName,
      foundEpoch: inspection.foundEpoch,
      differences: [...inspection.differences, ...extra],
      action: 'Run dartclaw rebuild-index while DartClaw is stopped, or restore supported rebuild sources.',
    );
  }

  static String _identifier(String value) => '"${value.replaceAll('"', '""')}"';

  static String _normalizeSql(String? sql) => (sql ?? '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAllMapped(RegExp(r'\s*([(),;=])\s*'), (match) => match[1]!)
      .trim();

  static bool _sameList(List<Object?> left, List<Object?> right) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) {
        return false;
      }
    }
    return true;
  }
}
