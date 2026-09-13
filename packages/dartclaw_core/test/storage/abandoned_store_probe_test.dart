import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:test/test.dart';

const _dsn = 'postgresql://probe:InactiveStoreSecretX9@localhost/app?sslmode=disable';
const _config = DatabaseConfig(url: _dsn);

void main() {
  test('absent reference does not resolve or connect', () async {
    final result = await probeInactivePostgresStore(
      const DatabaseConfig(),
      resolveDsn: (_) => throw StateError('must not resolve'),
      connectionFactory: (_) => throw StateError('must not connect'),
    );
    expect(result.state, InactivePostgresStoreState.empty);
    expect(result.notice, isNull);
  });

  test('resolution and posture refusal open no socket and never echo failed values', () async {
    var opens = 0;
    for (final unresolved in [true, false]) {
      final result = await probeInactivePostgresStore(
        _config,
        resolveDsn: (_) => unresolved
            ? throw StateError(_dsn)
            : (dsn: 'postgresql://probe:InactiveStoreSecretX9@db.example.com/app?sslmode=disable', credentialRef: 'db'),
        connectionFactory: (_) async {
          opens++;
          throw StateError('must not connect');
        },
      );
      expect(result.state, InactivePostgresStoreState.couldNotVerify);
      expect(result.reasonClass, unresolved ? 'unresolved reference' : 'posture refused');
      expect(result.notice, isNot(contains('InactiveStoreSecretX9')));
    }
    expect(opens, 0);
  });

  for (final row in [
    (content: false, held: false, expected: InactivePostgresStoreState.empty),
    (content: true, held: false, expected: InactivePostgresStoreState.abandoned),
    (content: false, held: true, expected: InactivePostgresStoreState.inUse),
    (content: true, held: true, expected: InactivePostgresStoreState.inUse),
  ]) {
    test('content=${row.content}, held=${row.held} reports ${row.expected.name} and closes', () async {
      final connection = _ProbeConnection(content: row.content, held: row.held);
      final audit = _Audit();
      final result = await _probe(connection, audit: audit);
      expect(result.state, row.expected);
      expect(connection.closedCount, 1);
      expect(audit.entries.map((entry) => entry.decision), ['open', 'close']);
      expect(audit.entries.every((entry) => entry.guard == 'DatabaseEgress' && entry.credentialRef == 'db'), isTrue);
      expect(connection.queries.every((query) => query.trimLeft().startsWith('SELECT')), isTrue);
      expect(connection.lockParameters, [
        PostgresInterlock.defaultKey >> 32,
        PostgresInterlock.defaultKey & 0xffffffff,
      ]);
      expect(result.notice ?? '', isNot(contains('InactiveStoreSecretX9')));
      if (row.expected == InactivePostgresStoreState.empty) expect(result.notice, isNull);
    });
  }

  for (final marker in [
    <Object?>[],
    <Object?>[1, 2],
    <Object?>[2, 1],
  ]) {
    test('unknown marker $marker cannot be classified as empty', () async {
      final connection = _ProbeConnection(marker: marker);
      final result = await _probe(connection);
      expect(result.state, InactivePostgresStoreState.couldNotVerify);
      expect(result.reasonClass, 'unknown schema');
      expect(connection.closedCount, 1);
      expect(connection.queries, hasLength(1));
    });
  }

  test('catalog and close failures are safe best-effort verdicts', () async {
    for (final atClose in [false, true]) {
      final connection = _ProbeConnection(failQuery: !atClose, failClose: atClose);
      final result = await _probe(connection);
      expect(result.state, InactivePostgresStoreState.couldNotVerify);
      expect(result.notice, isNot(contains('InactiveStoreSecretX9')));
      expect(connection.closedCount, 1);
    }
  });

  test('connection timeout and authentication failures never escape and auth is audited', () async {
    for (final error in <Object>[TimeoutException(_dsn), const SocketException(_dsn), _AuthenticationFailure()]) {
      final audit = _Audit();
      final result = await probeInactivePostgresStore(
        _config,
        resolveDsn: (_) => (dsn: _dsn, credentialRef: 'db'),
        auditLogger: audit,
        connectionFactory: (_) async => throw error,
      );
      expect(result.state, InactivePostgresStoreState.couldNotVerify);
      expect(result.notice, isNot(contains(_dsn)));
      expect(result.notice, isNot(contains('secret')));
      expect(audit.entries.map((entry) => entry.decision), error is pg.ServerException ? ['auth_failure'] : isEmpty);
    }
  });

  test('audit failure cannot prevent connection cleanup or abort the active backend', () async {
    final connection = _ProbeConnection();
    final result = await _probe(connection, audit: _Audit()..fail = true);
    expect(result.state, InactivePostgresStoreState.couldNotVerify);
    expect(connection.closedCount, 1);
  });

  test('local probes preserve empty, populated, ambiguous and unreadable files', () async {
    final directory = Directory.systemTemp.createTempSync('inactive_local_');
    try {
      final current = '${directory.path}/dartclaw.db';
      expect(await probeAuthoritativeStore(current), isA<AuthoritativeStoreAbsent>());
      final backend = await SqliteBackend.open(current);
      await backend.execute('CREATE TABLE tasks (id TEXT)');
      await backend.close();
      final emptyBytes = File(current).readAsBytesSync();
      expect(
        await probeAuthoritativeStore(current),
        isA<AuthoritativeStorePresent>().having(
          (probe) => probe.content,
          'content',
          AuthoritativeStoreContentState.empty,
        ),
      );
      expect(File(current).readAsBytesSync(), emptyBytes);
      final populated = await SqliteBackend.open(current);
      await populated.execute("INSERT INTO tasks VALUES ('one')");
      await populated.close();
      final bytes = File(current).readAsBytesSync();
      expect(
        await probeAuthoritativeStore(current),
        isA<AuthoritativeStorePresent>().having(
          (probe) => probe.content,
          'content',
          AuthoritativeStoreContentState.nonEmpty,
        ),
      );
      expect(File(current).readAsBytesSync(), bytes);
      File(current).copySync('${directory.path}/tasks.db');
      expect(await probeAuthoritativeStore(current), isA<AuthoritativeStoreAmbiguous>());
      expect(File(current).readAsBytesSync(), bytes);
      expect(File('${directory.path}/tasks.db').readAsBytesSync(), bytes);
      File('${directory.path}/tasks.db').deleteSync();
      File(current).writeAsStringSync('unreadable database');
      expect(
        await probeAuthoritativeStore(current),
        isA<AuthoritativeStorePresent>().having(
          (probe) => probe.content,
          'content',
          AuthoritativeStoreContentState.couldNotVerify,
        ),
      );
      expect(File(current).readAsStringSync(), 'unreadable database');
    } finally {
      directory.deleteSync(recursive: true);
    }
  });
}

Future<InactivePostgresStoreProbe> _probe(_ProbeConnection connection, {GuardAuditLogger? audit}) =>
    probeInactivePostgresStore(
      _config,
      resolveDsn: (_) => (dsn: _dsn, credentialRef: 'db'),
      connectionFactory: (_) async => connection,
      auditLogger: audit,
    );

final class _ProbeConnection implements pg.Connection {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(invocation.memberName.toString());
  new({
    this.content = false,
    this.held = false,
    this.marker = const [1, 1],
    this.failQuery = false,
    this.failClose = false,
  });
  final bool content, held, failQuery, failClose;
  final List<Object?> marker;
  final queries = <String>[];
  Object? lockParameters;
  var closedCount = 0;
  @override
  Future<pg.Result> execute(
    Object query, {
    Object? parameters,
    bool ignoreRows = false,
    pg.QueryMode? queryMode,
    Duration? timeout,
  }) async {
    final sql = query as String;
    queries.add(sql);
    if (failQuery) throw StateError(_dsn);
    final rows = sql.contains('dartclaw_schema')
        ? (marker.isEmpty ? <List<Object?>>[] : [marker])
        : sql.contains('pg_locks')
        ? (held
              ? <List<Object?>>[
                  [1],
                ]
              : <List<Object?>>[])
        : <List<Object?>>[
            [content],
          ];
    if (sql.contains('pg_locks')) lockParameters = parameters;
    final schema = pg.ResultSchema([]);
    return pg.Result(
      rows: [for (final values in rows) pg.ResultRow(values: values, schema: schema)],
      affectedRows: 0,
      schema: schema,
    );
  }

  @override
  Future<void> close({bool force = false}) async {
    closedCount++;
    if (failClose) throw StateError(_dsn);
  }
}

final class _Audit extends GuardAuditLogger {
  final entries = <AuditEntry>[];
  var fail = false;
  @override
  Future<void> writeEntry(AuditEntry entry) async {
    if (fail) throw StateError(_dsn);
    entries.add(entry);
  }
}

final class _AuthenticationFailure implements pg.ServerException {
  @override
  String get code => '28P01';
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(invocation.memberName.toString());
}
