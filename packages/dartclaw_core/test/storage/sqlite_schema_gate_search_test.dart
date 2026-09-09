import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show SchemaIncompatibleException;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'schema_fixtures.dart';

void main() {
  group('derived search store', () {
    test('fresh bootstrap and compatible reopen are complete and idempotent', () async {
      final store = _SearchStore.empty();

      await SqliteSchemaGate.prepareSearch(store.backend, storeName: 'search.db');

      expect(await store.state(), SqliteSchemaState.current);
      final schemaVersion = store.database.select('PRAGMA schema_version').single.values.single;
      store.database.execute('CREATE TABLE operator_notes (note TEXT)');
      final withForeignObject = _snapshot(store.database);
      await SqliteSchemaGate.prepareSearch(store.backend, storeName: 'search.db');
      expect(_snapshot(store.database), withForeignObject);
      expect(store.database.select('PRAGMA schema_version').single.values.single, (schemaVersion as int) + 1);
      await store.close();

      final released = _SearchStore.currentUnmarked();
      final releasedBefore = _snapshot(released.database);
      await SqliteSchemaGate.prepareSearch(released.backend, storeName: 'search.db');
      expect(await released.state(), SqliteSchemaState.current);
      expect(_withoutMarker(_snapshot(released.database)), _withoutMarker(releasedBefore));
      await released.close();
    });

    test('classifies each missing FTS object without changing the store', () async {
      for (final object in SchemaIdentity.search.sqliteObjects) {
        final store = _SearchStore.currentUnmarked();
        store.database.execute('DROP ${object.type.toUpperCase()} "${object.name}"');
        final before = _snapshot(store.database);

        final inspection = await SqliteSchemaGate.inspect(store.backend, SchemaIdentity.search, storeName: 'search.db');

        expect(inspection.state, SqliteSchemaState.incompatible, reason: object.name);
        expect(inspection.differences, contains('missing or mismatched ${object.type} ${object.name}'));
        expect(_snapshot(store.database), before, reason: object.name);
        await store.close();
      }
    });

    test('each existing FTS object declaration property is required', () async {
      final store = _SearchStore.currentUnmarked();
      final before = _snapshot(store.database);
      for (final object in SchemaIdentity.search.sqliteObjects) {
        for (final changed in [
          SqliteSchemaObject('view', object.name, object.table, object.sql),
          SqliteSchemaObject(object.type, object.name, 'wrong_table', object.sql),
          SqliteSchemaObject(object.type, object.name, object.table, '${object.sql} WHERE 0'),
        ]) {
          final identity = SchemaIdentity(
            tables: SchemaIdentity.search.tables,
            indexes: SchemaIdentity.search.indexes,
            sqliteObjects: SchemaIdentity.search.sqliteObjects
                .map((candidate) => candidate == object ? changed : candidate)
                .toList(),
            bootstrapStatements: SchemaIdentity.search.bootstrapStatements,
          );
          final inspection = await SqliteSchemaGate.inspect(store.backend, identity, storeName: 'search.db');
          expect(inspection.state, SqliteSchemaState.incompatible);
          expect(inspection.differences, ['missing or mismatched ${changed.type} ${object.name}']);
        }
      }
      expect(_snapshot(store.database), before);
      await store.close();
    });

    test('unavailable complete source degrades every readable health state before refusing', () async {
      for (final state in ['absent', 'healthy', 'degraded', 'rebuilding']) {
        for (final missing in ['both', 'populate', 'authenticate']) {
          final root = Directory.systemTemp.createTempSync('schema_gate_unavailable_');
          final health = IndexHealthStore(workspaceDir: root.path);
          await _seedHealth(health, state);
          final store = _SearchStore.legacy();
          final before = _snapshot(store.database);
          final version = store.database.select('PRAGMA schema_version').single.values.single;
          await expectLater(
            SqliteSchemaGate.prepareSearch(
              store.backend,
              storeName: 'search.db',
              rebuild: SqliteSearchRebuild(
                manifestRevision: 6,
                manifestFingerprint: 'prior-6',
                healthStore: health,
                populate: missing == 'authenticate' ? (_) async => fail('incomplete source must not populate') : null,
                authenticateComplete: missing == 'populate'
                    ? () async {
                        fail('incomplete source must not authenticate');
                      }
                    : null,
              ),
            ),
            throwsA(
              isA<SchemaIncompatibleException>().having(
                (error) => error.toString(),
                'stage',
                contains('unavailable-source'),
              ),
            ),
          );
          expect(_snapshot(store.database), before);
          expect(store.database.select('PRAGMA schema_version').single.values.single, version);
          final evidence = await health.read(canonicalRevision: 6, canonicalFingerprint: 'prior-6');
          expect(evidence.state, IndexHealthState.degraded, reason: '$state/$missing');
          expect(evidence.failureStage, 'unavailable-source');
          await store.close();
          root.deleteSync(recursive: true);
        }
      }
    });

    test('incomplete memory source refuses even with a complete conversation source', () async {
      for (final missing in ['populate', 'authenticate']) {
        final root = Directory.systemTemp.createTempSync('schema_gate_incomplete_memory_');
        final health = IndexHealthStore(workspaceDir: root.path);
        final store = _SearchStore.legacy();
        final before = _snapshot(store.database);
        var conversationCalls = 0;

        await expectLater(
          SqliteSchemaGate.prepareSearch(
            store.backend,
            storeName: 'search.db',
            rebuild: SqliteSearchRebuild(
              manifestRevision: 7,
              manifestFingerprint: 'incomplete-$missing',
              healthStore: health,
              populate: missing == 'authenticate' ? (_) async => fail('must refuse before population') : null,
              authenticateComplete: missing == 'populate'
                  ? () async {
                      fail('must refuse before authentication');
                    }
                  : null,
              corpora: [
                SqliteSearchCorpusRebuild(
                  populate: (_) async => conversationCalls++,
                  authenticateComplete: () async {
                    conversationCalls++;
                    return true;
                  },
                ),
              ],
            ),
          ),
          throwsA(
            isA<SchemaIncompatibleException>().having(
              (error) => error.toString(),
              'stage',
              contains('unavailable-source'),
            ),
          ),
        );

        expect(conversationCalls, 0, reason: missing);
        expect(_snapshot(store.database), before, reason: missing);
        final evidence = await health.read(canonicalRevision: 7, canonicalFingerprint: 'incomplete-$missing');
        expect(evidence.state, IndexHealthState.degraded, reason: missing);
        expect(evidence.failureStage, 'unavailable-source', reason: missing);
        await store.close();
        root.deleteSync(recursive: true);
      }
    });

    test('released memory-only schema is incompatible and rebuilds both corpora atomically', () async {
      final root = Directory.systemTemp.createTempSync('schema_gate_corpora_');
      final health = IndexHealthStore(workspaceDir: root.path);
      final store = _SearchStore.released025();
      final before = _snapshot(store.database);
      var failConversation = true;
      final rebuild = SqliteSearchRebuild(
        manifestRevision: 1,
        manifestFingerprint: 'corpora',
        healthStore: health,
        populate: (tx) => tx.execute("INSERT INTO memory_chunks(text, source) VALUES ('memory', 'source')"),
        authenticateComplete: () async => true,
        corpora: [
          SqliteSearchCorpusRebuild(
            populate: (tx) async {
              await tx.execute(
                'INSERT INTO conversation_chunks(message_id, user_id, text, session_id, role, created_at) '
                "VALUES ('message', 'owner', 'conversation', 'session', 'user', '2026-09-08T00:00:00Z')",
              );
              if (failConversation) throw StateError('conversation source failed');
            },
            authenticateComplete: () async => true,
          ),
        ],
      );

      expect((await store.state()), SqliteSchemaState.incompatible);
      await expectLater(
        SqliteSchemaGate.prepareSearch(store.backend, storeName: 'search.db', rebuild: rebuild),
        throwsA(isA<SchemaIncompatibleException>()),
      );
      expect(_snapshot(store.database), before);
      failConversation = false;
      await SqliteSchemaGate.prepareSearch(store.backend, storeName: 'search.db', rebuild: rebuild);
      expect(await store.state(), SqliteSchemaState.current);
      expect(store.database.select('SELECT text FROM memory_chunks').single['text'], 'memory');
      expect(store.database.select('SELECT text FROM conversation_chunks').single['text'], 'conversation');
      await store.close();
      root.deleteSync(recursive: true);
    });

    test('healthy publication and commit failures preserve prior contents and retry cleanly', () async {
      for (final failure in ['publish', 'commit']) {
        final root = Directory.systemTemp.createTempSync('schema_gate_publish_');
        var injectFailure = true;
        final health = IndexHealthStore(
          workspaceDir: root.path,
          writer: (file, evidence) async {
            if (injectFailure && failure == 'publish' && evidence['state'] == 'healthy') {
              throw FileSystemException('injected publication failure', file.path);
            }
            await atomicWriteJson(file, evidence);
          },
        );
        final store = _SearchStore.legacy();
        store.database.execute('PRAGMA foreign_keys = ON');
        store.database.execute('CREATE TABLE parent(id INTEGER PRIMARY KEY)');
        store.database.execute(
          'CREATE TABLE child(parent_id INTEGER REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED)',
        );
        final before = _snapshot(store.database);
        final rebuild = SqliteSearchRebuild(
          manifestRevision: 11,
          manifestFingerprint: 'fingerprint-11',
          healthStore: health,
          populate: (tx) async {
            await tx.execute("INSERT INTO memory_chunks(text, source) VALUES ('replacement', 'canonical')");
            if (injectFailure && failure == 'commit') await tx.execute('INSERT INTO child VALUES (1)');
          },
          authenticateComplete: () async => true,
        );
        await expectLater(
          SqliteSchemaGate.prepareSearch(store.backend, storeName: 'search.db', rebuild: rebuild),
          throwsA(
            isA<SchemaIncompatibleException>().having(
              (error) => error.toString(),
              'stage',
              contains('$failure failed'),
            ),
          ),
        );
        expect(_snapshot(store.database), before, reason: failure);
        final evidence = await health.read(canonicalRevision: 11, canonicalFingerprint: 'fingerprint-11');
        expect(evidence.state, IndexHealthState.degraded);
        expect(evidence.failureStage, failure);
        injectFailure = false;
        await SqliteSchemaGate.prepareSearch(store.backend, storeName: 'search.db', rebuild: rebuild);
        expect(await store.state(), SqliteSchemaState.current);
        expect(store.database.select('SELECT text FROM memory_chunks').map((row) => row['text']), ['replacement']);
        expect(
          (await health.read(canonicalRevision: 11, canonicalFingerprint: 'fingerprint-11')).state,
          IndexHealthState.healthy,
        );
        await store.close();
        root.deleteSync(recursive: true);
      }
    });

    test('malformed optional health fields refuse with unchanged bytes', () async {
      for (final field in ['failureStage', 'reason', 'action']) {
        for (final value in <Object>[1, false, <String>[], <String, Object>{}]) {
          final root = Directory.systemTemp.createTempSync('schema_gate_bad_health_field_');
          final evidenceFile = File(p.join(root.path, '.dartclaw-memory-index.json'))
            ..writeAsStringSync(
              jsonEncode({
                'state': 'healthy',
                'canonicalRevision': 10,
                'canonicalFingerprint': 'fingerprint-10',
                field: value,
              }),
            );
          final health = IndexHealthStore(workspaceDir: root.path);
          final store = _SearchStore.legacy();
          final before = _snapshot(store.database);
          final bytes = evidenceFile.readAsBytesSync();
          await expectLater(
            SqliteSchemaGate.prepareSearch(
              store.backend,
              storeName: 'search.db',
              rebuild: SqliteSearchRebuild(
                manifestRevision: 10,
                manifestFingerprint: 'fingerprint-10',
                healthStore: health,
                populate: (_) async => fail('unparseable evidence must not populate'),
                authenticateComplete: () async => true,
              ),
            ),
            throwsA(
              isA<SchemaIncompatibleException>().having((error) => error.toString(), 'detail', contains('unparseable')),
            ),
          );
          expect(_snapshot(store.database), before);
          expect(evidenceFile.readAsBytesSync(), bytes);
          await store.close();
          root.deleteSync(recursive: true);
        }
      }
    });

    test('rebuilds incompatible search from every readable health state', () async {
      for (final healthState in ['absent', 'healthy', 'degraded', 'rebuilding']) {
        final root = Directory.systemTemp.createTempSync('schema_gate_search_');
        final health = IndexHealthStore(workspaceDir: root.path, now: () => DateTime.utc(2026, 9, 2));
        await _seedHealth(health, healthState);
        final store = _SearchStore.legacy();

        await SqliteSchemaGate.prepareSearch(
          store.backend,
          storeName: 'search.db',
          rebuild: SqliteSearchRebuild(
            manifestRevision: 7,
            manifestFingerprint: 'fingerprint-7',
            healthStore: health,
            populate: (tx) => tx
                .execute('INSERT INTO memory_chunks (text, source, user_id) VALUES (?, ?, ?)', [
                  'reconstructed content',
                  'canonical',
                  'owner',
                ])
                .then((_) {}),
            authenticateComplete: () async => true,
          ),
        );

        expect(await store.state(), SqliteSchemaState.current, reason: healthState);
        expect(
          store.database.select("SELECT rowid FROM memory_chunks_fts WHERE memory_chunks_fts MATCH 'reconstructed'"),
          hasLength(1),
          reason: healthState,
        );
        final evidence = await health.read(canonicalRevision: 7, canonicalFingerprint: 'fingerprint-7');
        expect(evidence.state, IndexHealthState.healthy, reason: healthState);
        expect(evidence.indexRevision, 7, reason: healthState);
        expect(evidence.indexFingerprint, 'fingerprint-7', reason: healthState);
        await store.close();
        root.deleteSync(recursive: true);
      }
    });

    test('authenticated empty corpus rebuilds to a current zero-row index', () async {
      final root = Directory.systemTemp.createTempSync('schema_gate_empty_search_');
      final health = IndexHealthStore(workspaceDir: root.path);
      final store = _SearchStore.legacy();

      await SqliteSchemaGate.prepareSearch(
        store.backend,
        storeName: 'search.db',
        rebuild: SqliteSearchRebuild(
          manifestRevision: 8,
          manifestFingerprint: 'empty-8',
          healthStore: health,
          populate: (_) async {},
          authenticateComplete: () async => true,
        ),
      );

      expect(await store.state(), SqliteSchemaState.current);
      expect(store.database.select('SELECT COUNT(*) AS count FROM memory_chunks').single['count'], 0);
      expect(
        (await health.read(canonicalRevision: 8, canonicalFingerprint: 'empty-8')).state,
        IndexHealthState.healthy,
      );
      await store.close();
      root.deleteSync(recursive: true);
    });

    test('refuses missing or failing rebuild inputs without changing the prior store', () async {
      final unavailable = _SearchStore.legacy();
      final unavailableBefore = _snapshot(unavailable.database);
      await expectLater(
        SqliteSchemaGate.prepareSearch(unavailable.backend, storeName: 'search.db'),
        throwsA(
          isA<SchemaIncompatibleException>()
              .having((error) => error.toString(), 'store', contains('search.db'))
              .having((error) => error.toString(), 'action', contains('dartclaw rebuild-index'))
              .having((error) => error.toString(), 'stopped', contains('stopped')),
        ),
      );
      expect(_snapshot(unavailable.database), unavailableBefore);
      await unavailable.close();

      for (final failure in ['populate', 'authenticate']) {
        final root = Directory.systemTemp.createTempSync('schema_gate_failed_search_');
        final health = IndexHealthStore(workspaceDir: root.path);
        final store = _SearchStore.epoch(2);
        final before = _snapshot(store.database);

        await expectLater(
          SqliteSchemaGate.prepareSearch(
            store.backend,
            storeName: 'search.db',
            rebuild: SqliteSearchRebuild(
              manifestRevision: 9,
              manifestFingerprint: 'fingerprint-9',
              healthStore: health,
              populate: (tx) async {
                await tx.execute("INSERT INTO memory_chunks (text, source) VALUES ('partial', 'canonical')");
                if (failure == 'populate') throw StateError('populate failed');
              },
              authenticateComplete: () async => failure != 'authenticate',
            ),
          ),
          throwsA(isA<SchemaIncompatibleException>()),
        );

        expect(_snapshot(store.database), before, reason: failure);
        final evidence = await health.read(canonicalRevision: 9, canonicalFingerprint: 'fingerprint-9');
        expect(evidence.state, IndexHealthState.degraded, reason: failure);
        expect(evidence.failureStage, failure, reason: failure);
        await store.close();
        root.deleteSync(recursive: true);
      }
    });

    test('unparseable health evidence leaves the store and evidence byte-identical', () async {
      final root = Directory.systemTemp.createTempSync('schema_gate_bad_health_');
      final evidenceFile = File(p.join(root.path, '.dartclaw-memory-index.json'))..writeAsStringSync('{broken');
      final health = IndexHealthStore(workspaceDir: root.path);
      final store = _SearchStore.legacy();
      final storeBefore = _snapshot(store.database);
      final evidenceBefore = evidenceFile.readAsBytesSync();

      await expectLater(
        SqliteSchemaGate.prepareSearch(
          store.backend,
          storeName: 'search.db',
          rebuild: SqliteSearchRebuild(
            manifestRevision: 10,
            manifestFingerprint: 'fingerprint-10',
            healthStore: health,
            populate: (_) async {},
            authenticateComplete: () async => true,
          ),
        ),
        throwsA(
          isA<SchemaIncompatibleException>().having((error) => error.toString(), 'detail', contains('unparseable')),
        ),
      );

      expect(_snapshot(store.database), storeBefore);
      expect(evidenceFile.readAsBytesSync(), evidenceBefore);
      await store.close();
      root.deleteSync(recursive: true);
    });
  });
}

final class _SearchStore {
  new(this.database) : backend = SqliteBackend(database);

  factory empty() => _SearchStore(sqlite3.openInMemory());

  factory legacy() {
    final database = sqlite3.openInMemory();
    create023SearchSchema(database);
    database.execute("INSERT INTO memory_chunks (text, source) VALUES ('prior content', 'legacy')");
    return _SearchStore(database);
  }

  factory currentUnmarked() {
    final database = sqlite3.openInMemory();
    for (final sql in SchemaIdentity.search.bootstrapStatements) {
      database.execute(sql);
    }
    return _SearchStore(database);
  }

  factory released025() {
    final database = sqlite3.openInMemory();
    createReleased025SearchSchema(database);
    return _SearchStore(database);
  }

  factory epoch(int epoch) {
    final database = sqlite3.openInMemory();
    createReleased025SearchSchema(database);
    database.execute('CREATE TABLE dartclaw_schema (id INTEGER PRIMARY KEY, epoch INTEGER NOT NULL)');
    database.execute('INSERT INTO dartclaw_schema VALUES (1, ?)', [epoch]);
    database.execute("INSERT INTO memory_chunks (text, source) VALUES ('prior content', 'legacy')");
    return _SearchStore(database);
  }

  final Database database;
  final SqliteBackend backend;

  Future<SqliteSchemaState> state() async =>
      (await SqliteSchemaGate.inspect(backend, SchemaIdentity.search, storeName: 'search.db')).state;

  Future<void> close() => backend.close();
}

Future<void> _seedHealth(IndexHealthStore health, String state) async {
  switch (state) {
    case 'absent':
      return;
    case 'healthy':
      await health.recordHealthy(canonicalRevision: 6, canonicalFingerprint: 'prior-6');
      return;
    case 'degraded':
      await health.recordDegraded(
        canonicalRevision: 6,
        canonicalFingerprint: 'prior-6',
        stage: 'prior',
        reason: 'prior failure',
      );
      return;
    case 'rebuilding':
      await health.recordRebuilding(canonicalRevision: 6, canonicalFingerprint: 'prior-6');
      return;
  }
}

String _snapshot(Database database) {
  final objects = database.select(
    "SELECT type, name, tbl_name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name",
  );
  final data = <String, Object?>{};
  for (final row in objects.where((row) => row['type'] == 'table')) {
    final name = row['name'] as String;
    if (name.contains('_fts')) continue;
    data[name] = database.select('SELECT * FROM "$name"').map((item) => item.values.toList()).toList();
  }
  return jsonEncode({'objects': objects.map((row) => row.values.toList()).toList(), 'data': data});
}

String _withoutMarker(String encoded) {
  final snapshot = jsonDecode(encoded) as Map<String, dynamic>;
  final objects = (snapshot['objects'] as List).where((row) => (row as List)[1] != 'dartclaw_schema').toList();
  final data = Map<String, dynamic>.from(snapshot['data'] as Map)..remove('dartclaw_schema');
  return jsonEncode({'objects': objects, 'data': data});
}
