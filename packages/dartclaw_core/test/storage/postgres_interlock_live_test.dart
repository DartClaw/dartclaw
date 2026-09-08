@Tags(['integration'])
library;

import 'dart:async';
import 'dart:math';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:test/test.dart';

import 'postgres_live_support.dart';

void main() {
  test('the session lock refuses a competitor and releases immediately', () async {
    await withPostgresBackend((backend, _) async {
      final key = _testKey();
      final admin = await _openAdmin(backend);
      final first = PostgresInterlock(key: key);
      final second = PostgresInterlock(key: key);
      try {
        await first.acquire(backend: backend, onFatalLoss: (_) => fail('the held lock must remain healthy'));
        expect(await _holderCount(admin, key), 1);
        final sessionsBeforeRefusal = await _applicationSessionCount(admin);

        await expectLater(
          () => second.acquire(backend: backend, onFatalLoss: (_) => fail('startup refusal is not recovery')),
          throwsA(
            isA<StorageConnectionException>()
                .having((error) => error.message, 'message', contains('owns this PostgreSQL database'))
                .having(
                  (error) => '$error',
                  'rendering',
                  isNot(contains(backend.connectionPosture.endpoint.password!)),
                ),
          ),
        );
        expect(await _holderCount(admin, key), 1);
        expect(await _applicationSessionCount(admin), sessionsBeforeRefusal);

        first.beginShutdown();
        await backend.close();
        await first.release();
        expect(await _holderCount(admin, key), 0);

        await second.acquire(backend: backend, onFatalLoss: (_) => fail('reacquired lock must remain healthy'));
        expect(await _holderCount(admin, key), 1);
        second.beginShutdown();
        await second.release();
        expect(await _holderCount(admin, key), 0);
      } finally {
        first.beginShutdown();
        second.beginShutdown();
        await first.release();
        await second.release();
        await admin.close();
      }
    });
  });

  test('terminated ownership quarantines every caller until version and schema pass', () async {
    await withPostgresBackend((backend, namespace) async {
      await PostgresSchemaGate.prepare(backend, databaseIdentity: backend.databaseIdentity);
      final statement = await backend.prepare('SELECT COUNT(*) AS count FROM tasks');
      final memory = PostgresFtsIndex(backend, table: PostgresFtsTable.memoryChunks, language: 'english');
      final knowledge = TemporalKnowledgeGraphService(backend);
      final key = _testKey();
      final admin = await _openAdmin(backend);
      final schemaStarted = Completer<void>();
      final schemaRelease = Completer<void>();
      final interlock = PostgresInterlock(
        key: key,
        schemaGate: (_) async {
          schemaStarted.complete();
          await schemaRelease.future;
        },
      );
      try {
        final catalogBefore = await _catalog(admin, namespace);
        await interlock.acquire(backend: backend, onFatalLoss: (error) => fail('recovery failed: $error'));
        final pid = await _holderPid(admin, key);
        expect(
          (await admin.execute('SELECT pg_terminate_backend($pid) AS terminated')).single.toColumnMap()['terminated'],
          isTrue,
        );
        await schemaStarted.future.timeout(const Duration(seconds: 10));

        var transactionBodyRan = false;
        final refused = <Future<void> Function()>[
          () async => backend.execute('DELETE FROM tasks'),
          () async => backend.query('SELECT 1'),
          () async => backend.query('INSERT INTO tasks DEFAULT VALUES RETURNING id'),
          () async => backend.prepare('SELECT 1'),
          () async => backend.transaction<void>((_) async => transactionBodyRan = true),
          () async => statement.query(),
          () async => memory.search('anything', userId: 'owner'),
          () async => knowledge.allFacts(),
        ];
        for (final operation in refused) {
          await expectLater(operation, throwsA(_recoveryPending));
        }
        expect(transactionBodyRan, isFalse);
        expect(await _catalog(admin, namespace), catalogBefore);

        schemaRelease.complete();
        await _waitUntilRecovered(backend);
        expect(await backend.query('SELECT 1 AS value'), [
          {'value': 1},
        ]);
        final afterRecovery = await backend.prepare('SELECT 1 AS value');
        expect(await afterRecovery.query(), [
          {'value': 1},
        ]);
        await afterRecovery.close();
        expect(await backend.transaction((tx) => tx.query('SELECT 1 AS value')), [
          {'value': 1},
        ]);
        expect(await statement.query(), [
          {'count': 0},
        ]);
        expect(await memory.search('anything', userId: 'owner'), isEmpty);
        expect(await knowledge.allFacts(), isEmpty);
        expect(await _catalog(admin, namespace), catalogBefore);

        interlock.beginShutdown();
        await backend.close();
        await interlock.release();
        expect(await _holderCount(admin, key), 0);
      } finally {
        interlock.beginShutdown();
        await interlock.release();
        await statement.close();
        await admin.close();
      }
    });
  });
}

final _recoveryPending = isA<StorageConnectionException>().having(
  (error) => error.message,
  'message',
  contains('ownership recovery is pending'),
);

Future<pg.Connection> _openAdmin(PostgresBackend backend) {
  return pg.Connection.open(
    backend.connectionPosture.endpoint,
    settings: pg.ConnectionSettings(sslMode: backend.connectionPosture.sslMode),
  );
}

int _testKey() {
  final nonce = DateTime.now().microsecondsSinceEpoch ^ Random().nextInt(1 << 30);
  return 0x6400000000000000 | (nonce & 0x00ffffffffffffff);
}

Future<int> _holderCount(pg.Connection connection, int key) async {
  final result = await connection.execute('''
    SELECT COUNT(*)::integer AS count
    FROM pg_locks
    WHERE locktype = 'advisory'
      AND classid = ${_high(key)}::oid
      AND objid = ${_low(key)}::oid
      AND objsubid = 1
      AND granted
  ''');
  return result.single.toColumnMap()['count'] as int;
}

Future<int> _holderPid(pg.Connection connection, int key) async {
  final result = await connection.execute('''
    SELECT pid
    FROM pg_locks
    WHERE locktype = 'advisory'
      AND classid = ${_high(key)}::oid
      AND objid = ${_low(key)}::oid
      AND objsubid = 1
      AND granted
  ''');
  return result.single.toColumnMap()['pid'] as int;
}

Future<int> _applicationSessionCount(pg.Connection connection) async {
  final result = await connection.execute('''
    SELECT COUNT(*)::integer AS count
    FROM pg_stat_activity
    WHERE datname = current_database() AND application_name = 'dartclaw'
  ''');
  return result.single.toColumnMap()['count'] as int;
}

int _high(int key) => (key >> 32) & 0xffffffff;

int _low(int key) => key & 0xffffffff;

Future<List<Map<String, Object?>>> _catalog(pg.Connection connection, String namespace) async {
  final result = await connection.execute('''
    SELECT 'table' AS kind, table_name AS name, '' AS detail
    FROM information_schema.tables
    WHERE table_schema = '$namespace'
    UNION ALL
    SELECT 'column', table_name || '.' || column_name, data_type || ':' || is_nullable
    FROM information_schema.columns
    WHERE table_schema = '$namespace'
    UNION ALL
    SELECT 'index', indexname, indexdef
    FROM pg_indexes
    WHERE schemaname = '$namespace'
    ORDER BY kind, name
  ''');
  return result.map((row) => row.toColumnMap()).toList(growable: false);
}

Future<void> _waitUntilRecovered(PostgresBackend backend) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    try {
      await backend.query('SELECT 1');
      return;
    } on StorageConnectionException {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
  fail('backend remained quarantined after the recovery schema gate passed');
}
