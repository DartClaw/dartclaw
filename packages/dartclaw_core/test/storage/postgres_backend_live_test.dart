@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:logging/logging.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:test/test.dart';

import 'postgres_live_support.dart';

void main() {
  test('portable operations and lifecycle', () async {
    await withPostgresBackend((backend, _) async {
      await backend.execute(
        'CREATE TABLE scalar_rows (id bigint PRIMARY KEY, i bigint, d double precision, s text, b bytea)',
      );
      final returned = await backend.query(
        'INSERT INTO scalar_rows (id, i, d, s, b) VALUES (?, ?, ?, ?, ?) RETURNING id',
        [
          1,
          2,
          3.5,
          'four',
          Uint8List.fromList([5]),
        ],
      );
      expect(returned.single['id'], 1);
      expect(await backend.execute('UPDATE scalar_rows SET s = ? WHERE id = ?', ['changed', 1]), 1);
      expect(
        (await backend.query('SELECT i, d, s, b, true AS flag, CURRENT_TIMESTAMP AS stamp FROM scalar_rows')).single,
        containsPair('flag', 1),
      );

      final statement = await backend.prepare('SELECT s FROM scalar_rows WHERE id = ?');
      expect((await statement.query([1])).single['s'], 'changed');
      expect((await statement.query([1])).single['s'], 'changed');
      await statement.close();
      await statement.close();

      await backend.close();
      await backend.close();
      await expectLater(() => backend.execute('SELECT 1'), throwsStateError);
    });
  });

  test('transaction joins owner calls, rolls back, and isolates foreign work', () async {
    await withPostgresBackend((backend, _) async {
      await backend.execute('CREATE TABLE tx_rows (id bigint PRIMARY KEY, label text NOT NULL)');
      final ownerStatement = await backend.prepare('INSERT INTO tx_rows (id, label) VALUES (?, ?)');
      expect(
        await backend.transaction((tx) async {
          await tx.execute('INSERT INTO tx_rows VALUES (?, ?)', [0, 'commit']);
          return 42;
        }),
        42,
      );
      DatabaseStatement? transactionStatement;
      final bodyStarted = Completer<void>();
      final releaseBody = Completer<void>();
      final transaction = backend.transaction<void>((tx) async {
        await tx.execute('INSERT INTO tx_rows VALUES (?, ?)', [1, 'tx']);
        await backend.execute('INSERT INTO tx_rows VALUES (?, ?)', [2, 'owner']);
        await ownerStatement.execute([3, 'statement']);
        transactionStatement = await tx.prepare('SELECT label FROM tx_rows WHERE id = ?');
        expect((await transactionStatement!.query([1])).single['label'], 'tx');
        await expectLater(() => tx.transaction<void>((_) async {}), throwsA(isA<NestedTransactionError>()));
        await expectLater(() => backend.transaction<void>((_) async {}), throwsA(isA<NestedTransactionError>()));
        bodyStarted.complete();
        await releaseBody.future;
        throw const _BodyFailure();
      });

      await bodyStarted.future;
      expect(await backend.query('SELECT id FROM tx_rows WHERE id > 0'), isEmpty);
      await backend.execute('INSERT INTO tx_rows VALUES (?, ?)', [4, 'concurrent']);
      releaseBody.complete();
      await expectLater(transaction, throwsA(isA<_BodyFailure>()));
      expect((await backend.query('SELECT id FROM tx_rows ORDER BY id')).map((row) => row['id']), [0, 4]);
      await expectLater(() => transactionStatement!.query([1]), throwsStateError);
      await transactionStatement!.close();
      await transactionStatement!.close();
      await ownerStatement.close();
    });
  });

  test('audits open and close with safe connection identity', () async {
    final auditDir = Directory.systemTemp.createTempSync('postgres_backend_audit_');
    addTearDown(() {
      if (auditDir.existsSync()) auditDir.deleteSync(recursive: true);
    });
    final logger = GuardAuditLogger(dataDir: auditDir.path);
    String? identity;

    await withPostgresBackend(
      (backend, _) async => identity = backend.databaseIdentity,
      auditLogger: logger,
      credentialRef: 'database-main',
    );

    final entries = _auditEntries(logger);
    expect(entries.map((entry) => entry['decision']), ['open', 'close']);
    for (final entry in entries) {
      expect(entry, containsPair('guard', 'DatabaseEgress'));
      expect(entry, containsPair('hook', 'connection'));
      expect(entry, containsPair('verdict', 'allow'));
      expect(entry, containsPair('server', identity));
      expect(entry, containsPair('credentialRef', 'database-main'));
    }
  });

  test('authentication refusal emits one secret-free denial', () async {
    final auditDir = Directory.systemTemp.createTempSync('postgres_backend_auth_audit_');
    addTearDown(() {
      if (auditDir.existsSync()) auditDir.deleteSync(recursive: true);
    });
    final logger = GuardAuditLogger(dataDir: auditDir.path);
    final base = _configuredDsn();
    final nonce = DateTime.now().microsecondsSinceEpoch;
    final username = 'missing_runtime_$nonce';
    const password = 'AuthenticationFixturePasswordX9';
    final dsn = base.replace(userInfo: '$username:$password').toString();

    Object? refusal;
    try {
      await PostgresBackend.open(dsn: dsn, poolSize: 1, credentialRef: 'DARTCLAW_DATABASE_URL', auditLogger: logger);
    } catch (error) {
      refusal = error;
    }

    expect(refusal, isA<StorageConnectionException>());
    final entries = _auditEntries(logger);
    expect(entries, hasLength(1));
    expect(entries.single, containsPair('decision', 'auth_failure'));
    expect(entries.single, containsPair('verdict', 'deny'));
    expect(entries.single, containsPair('credentialRef', 'DARTCLAW_DATABASE_URL'));
    final observable = '$refusal\n${jsonEncode(entries)}';
    expect(observable, isNot(contains(username)));
    expect(observable, isNot(contains(password)));
    expect(observable, isNot(contains(dsn)));
  });

  test('an audit write failure aborts an otherwise valid open', () async {
    final root = Directory.systemTemp.createTempSync('postgres_backend_audit_failure_');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    final blocker = File('${root.path}/blocker')..writeAsStringSync('not a directory');
    final logger = GuardAuditLogger(dataDir: '${blocker.path}/audit');

    await expectLater(
      () => PostgresBackend.open(
        dsn: _configuredDsn().toString(),
        poolSize: 1,
        credentialRef: 'database-main',
        auditLogger: logger,
      ),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('warns once for a superuser and stays silent for a schema owner', () async {
    final configured = _configuredDsn();
    final admin = await pg.Connection.openFromUrl(configured.toString());
    final nonce = '${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(1 << 20)}';
    final role = 'dc_runtime_$nonce';
    final namespace = 'dc_role_$nonce';
    const password = 'LeastPrivilegeFixturePasswordY8';
    PostgresBackend? superuserBackend;
    PostgresBackend? runtimeBackend;
    final warnings = <LogRecord>[];
    final oldLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    final subscription = Logger.root.onRecord
        .where((record) => record.loggerName == 'PostgresBackend' && record.level == Level.WARNING)
        .listen(warnings.add);
    try {
      final result = await admin.execute('SELECT rolsuper FROM pg_roles WHERE rolname = current_user');
      expect(result.single.toColumnMap()['rolsuper'], isTrue, reason: 'the live role fixture requires a superuser');
      await admin.execute('CREATE ROLE "$role" LOGIN PASSWORD \'$password\' NOSUPERUSER');
      await admin.execute('CREATE SCHEMA "$namespace" AUTHORIZATION "$role"');

      superuserBackend = await PostgresBackend.open(dsn: configured.toString(), poolSize: 1);
      expect(warnings, hasLength(1));
      expect(warnings.single.message, contains('administrator role'));
      expect(warnings.single.message, contains('least-privilege runtime role'));
      await superuserBackend.close();
      superuserBackend = null;

      warnings.clear();
      final runtimeDsn = configured.replace(userInfo: '$role:$password');
      runtimeBackend = await PostgresBackend.open(dsn: runtimeDsn.toString(), poolSize: 1, namespace: namespace);
      expect(warnings, isEmpty);
    } finally {
      await runtimeBackend?.close();
      await superuserBackend?.close();
      await subscription.cancel();
      Logger.root.level = oldLevel;
      await admin.execute('DROP SCHEMA IF EXISTS "$namespace" CASCADE');
      await admin.execute('DROP ROLE IF EXISTS "$role"');
      await admin.close();
    }
  });
}

Uri _configuredDsn() {
  final configured = Platform.environment['DARTCLAW_TEST_POSTGRES_URL'];
  if (configured == null || configured.isEmpty) {
    throw StateError('DARTCLAW_TEST_POSTGRES_URL is required');
  }
  final uri = Uri.parse(configured);
  return uri.replace(queryParameters: {...uri.queryParameters, 'sslmode': 'disable'});
}

List<Map<String, dynamic>> _auditEntries(GuardAuditLogger logger) =>
    File(logger.auditFilePath)
        .readAsLinesSync()
        .where((line) => line.trim().isNotEmpty)
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .toList();

final class _BodyFailure implements Exception {
  const new();
}
