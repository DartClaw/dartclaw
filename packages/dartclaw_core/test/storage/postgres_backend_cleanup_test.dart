import 'dart:async';

import 'package:dartclaw_core/src/storage/postgres_backend.dart';
import 'package:dartclaw_core/src/storage/postgres_connection_posture.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:test/test.dart';

void main() {
  test('statement cleanup preserves a body error when rollback and every disposal fail', () async {
    final statements = [_FailingStatement(), _FailingStatement()];
    final connection = _Connection(statements, failRollback: true);
    final backend = _backend(connection);
    final bodyError = StateError('body failed');

    Object? actualError;
    StackTrace? actualStack;
    try {
      await backend.transaction<void>((tx) async {
        await tx.prepare('SELECT 1');
        await tx.prepare('SELECT 2');
        _throwBody(bodyError);
      });
    } catch (error, stackTrace) {
      actualError = error;
      actualStack = stackTrace;
    }

    expect(actualError, same(bodyError));
    expect('$actualStack', contains('_throwBody'));
    expect(connection.commands, ['BEGIN', 'ROLLBACK']);
    expect(statements.map((statement) => statement.disposeCount), everyElement(1));
    await backend.close();
  });

  test('statement cleanup preserves a commit failure and attempts every disposal', () async {
    final statements = [_FailingStatement(), _FailingStatement()];
    final commitError = StorageQueryException(operation: 'commit', guidance: 'fixture failure');
    final connection = _Connection(statements, commitError: commitError);
    final backend = _backend(connection);

    await expectLater(
      () => backend.transaction<void>((tx) async {
        await tx.prepare('SELECT 1');
        await tx.prepare('SELECT 2');
      }),
      throwsA(same(commitError)),
    );

    expect(connection.commands, ['BEGIN', 'COMMIT']);
    expect(statements.map((statement) => statement.disposeCount), everyElement(1));
    await backend.close();
  });

  test('statement cleanup preserves a committed value and makes every statement inactive first', () async {
    final firstDisposeStarted = Completer<void>();
    final releaseFirstDispose = Completer<void>();
    final statements = [
      _FailingStatement(started: firstDisposeStarted, release: releaseFirstDispose),
      _FailingStatement(),
    ];
    final connection = _Connection(statements);
    final backend = _backend(connection);
    late DatabaseStatement second;

    final transaction = backend.transaction<int>((tx) async {
      await tx.prepare('SELECT 1');
      second = await tx.prepare('SELECT 2');
      return 42;
    });
    await firstDisposeStarted.future;

    await expectLater(() => second.query(), throwsStateError);
    releaseFirstDispose.complete();
    expect(await transaction, 42);
    expect(connection.commands, ['BEGIN', 'COMMIT']);
    expect(statements.map((statement) => statement.disposeCount), everyElement(1));
    await backend.close();
  });
}

Never _throwBody(Object error) => throw error;

PostgresBackend _backend(_Connection connection) => PostgresBackend.forTesting(
  pool: _Pool(connection),
  connectionPosture: PostgresConnectionPosture(
    endpoint: pg.Endpoint(host: 'db.example.com', database: 'app'),
    sslMode: pg.SslMode.verifyFull,
    databaseIdentity: 'db.example.com:5432/app/dc_test',
    credentialRef: 'database-main',
  ),
);

final class _Pool implements pg.Pool<void> {
  new(this.connection);

  final _Connection connection;

  @override
  Future<R> withConnection<R>(
    Future<R> Function(pg.Connection connection) fn, {
    pg.ConnectionSettings? settings,
    void locality,
  }) => fn(connection);

  @override
  Future<void> close({bool force = false}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Connection implements pg.Connection {
  new(this.statements, {this.failRollback = false, this.commitError});

  final List<_FailingStatement> statements;
  final bool failRollback;
  final Object? commitError;
  final List<String> commands = [];
  var _nextStatement = 0;

  @override
  Future<pg.Result> execute(
    Object query, {
    Object? parameters,
    bool ignoreRows = false,
    pg.QueryMode? queryMode,
    Duration? timeout,
  }) async {
    final command = query as String;
    commands.add(command);
    if (command == 'ROLLBACK' && failRollback) throw StateError('rollback failed');
    if (command == 'COMMIT') {
      if (commitError case final error?) throw error;
    }
    return pg.Result(rows: const [], affectedRows: 0, schema: pg.ResultSchema(const []));
  }

  @override
  Future<pg.Statement> prepare(Object query) async => statements[_nextStatement++];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FailingStatement implements pg.Statement {
  new({this.started, this.release});

  final Completer<void>? started;
  final Completer<void>? release;
  var disposeCount = 0;

  @override
  Future<void> dispose() async {
    disposeCount++;
    started?.complete();
    await release?.future;
    throw StateError('statement disposal failed');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
