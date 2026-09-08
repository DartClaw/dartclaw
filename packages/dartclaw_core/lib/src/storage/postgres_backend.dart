import 'dart:async';
import 'dart:typed_data';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:postgres/postgres.dart' as pg;

import 'postgres_dispatch_policy.dart';
import 'sql_placeholder_rewriter.dart';

/// PostgreSQL implementation of the portable database contract.
final class PostgresBackend implements DatabaseBackend {
  new _(this._pool, this.databaseIdentity) : _policy = PostgresDispatchPolicy(databaseIdentity);

  final pg.Pool<void> _pool;
  final Object _transactionZoneKey = Object();
  final PostgresDispatchPolicy _policy;

  /// Safe host, port, and database label.
  final String databaseIdentity;

  bool _closed = false;

  /// Opens one bounded pool and verifies PostgreSQL 14 or newer.
  static Future<PostgresBackend> open({required String dsn, required int poolSize, String? namespace}) async {
    final uri = Uri.parse(dsn);
    if (uri.host.isEmpty || poolSize <= 0) {
      throw StorageConnectionException(
        operation: 'connect',
        guidance: 'Provide a valid PostgreSQL URL and positive pool size.',
      );
    }
    final database = uri.pathSegments.isEmpty || uri.pathSegments.first.isEmpty ? 'postgres' : uri.pathSegments.first;
    if (namespace != null && !RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(namespace)) {
      throw StorageConnectionException(operation: 'connect', guidance: 'Provide a valid PostgreSQL namespace.');
    }
    final identity = '${uri.host}:${uri.hasPort ? uri.port : 5432}/$database${namespace == null ? '' : '/$namespace'}';
    final userInfo = uri.userInfo;
    final separator = userInfo.indexOf(':');
    final endpoint = pg.Endpoint(
      host: uri.host,
      port: uri.hasPort ? uri.port : 5432,
      database: database,
      username: userInfo.isEmpty
          ? null
          : Uri.decodeComponent(separator < 0 ? userInfo : userInfo.substring(0, separator)),
      password: separator < 0 ? null : Uri.decodeComponent(userInfo.substring(separator + 1)),
    );
    final policy = PostgresDispatchPolicy(identity);
    final pool = pg.Pool<void>.withEndpoints(
      [endpoint],
      settings: pg.PoolSettings(
        maxConnectionCount: poolSize,
        connectTimeout: policy.poolWaitCeiling,
        onOpen: namespace == null
            ? null
            : (connection) => connection.execute('SET search_path TO "$namespace"', queryMode: pg.QueryMode.simple),
        sslMode: switch (uri.queryParameters['sslmode']) {
          'disable' => pg.SslMode.disable,
          'verify-ca' || 'verify-full' => pg.SslMode.verifyFull,
          _ => pg.SslMode.require,
        },
      ),
    );
    try {
      final version = await policy.run<int>('server version', (markDispatched) {
        return _withBoundedLease(pool, policy.poolWaitCeiling, (connection) async {
          markDispatched();
          final result = await _driverExecute(connection, 'SHOW server_version_num');
          return int.parse(result.single.single.toString());
        });
      }, timeoutMeansPoolExhausted: false);
      if (version < 140000) {
        throw StorageConnectionException(
          operation: 'server version',
          databaseIdentity: identity,
          guidance: 'PostgreSQL 14 or newer is required.',
        );
      }
      return PostgresBackend._(pool, identity);
    } on Object {
      await pool.close(force: true);
      rethrow;
    }
  }

  @override
  Future<int> execute(String sql, [List<Object?> parameters = const []]) async {
    final result = await _run('execute', sql, parameters);
    return result.affectedRows;
  }

  @override
  Future<List<Map<String, Object?>>> query(String sql, [List<Object?> parameters = const []]) async {
    final result = await _run('query', sql, parameters);
    return _rows(result);
  }

  @override
  Future<DatabaseStatement> prepare(String sql) async {
    _ensureOpen();
    final transaction = _matchingTransaction;
    if (transaction != null) return transaction._prepare(sql);
    return _PostgresOwnerStatement(this, sql);
  }

  @override
  Future<T> transaction<T>(Future<T> Function(DatabaseBackend tx) body) async {
    _ensureOpen();
    if (_matchingTransaction != null) throw const NestedTransactionError();
    try {
      return await _policy.run<T>('transaction', (markDispatched) {
        return _withBoundedLease(_pool, _policy.poolWaitCeiling, (connection) async {
          _ensureOpen();
          markDispatched();
          await _driverExecute(connection, 'BEGIN', queryMode: pg.QueryMode.simple);
          final transaction = _PostgresTransaction(this, connection);
          late T value;
          try {
            value = await runZoned(() => body(transaction), zoneValues: {_transactionZoneKey: transaction});
          } catch (error, stackTrace) {
            try {
              await _driverExecute(connection, 'ROLLBACK', queryMode: pg.QueryMode.simple);
            } catch (_) {}
            await transaction._deactivate();
            if (error is StorageException) rethrow;
            throw _PostgresBodyFailure(error, stackTrace);
          }
          try {
            await _driverExecute(connection, 'COMMIT', queryMode: pg.QueryMode.simple);
            return value;
          } finally {
            await transaction._deactivate();
          }
        });
      }, passThrough: (error) => error is _PostgresBodyFailure);
    } on _PostgresBodyFailure catch (failure) {
      Error.throwWithStackTrace(failure.error, failure.stackTrace);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    if (_matchingTransaction != null) {
      throw StateError('Cannot close a backend from its active transaction');
    }
    _closed = true;
    await _pool.close();
  }

  Future<pg.Result> _run(String operation, String sql, List<Object?> parameters) {
    _ensureOpen();
    final transaction = _matchingTransaction;
    if (transaction != null) {
      return transaction._run(operation, _portableSql(sql), parameters);
    }
    final query = _portableSql(sql);
    return _policy.run<pg.Result>(operation, (markDispatched) {
      return _withBoundedLease(_pool, _policy.poolWaitCeiling, (connection) async {
        _ensureOpen();
        markDispatched();
        return _driverExecute(connection, query, parameters: parameters);
      });
    });
  }

  _PostgresTransaction? get _matchingTransaction {
    final transaction = Zone.current[_transactionZoneKey];
    return transaction is _PostgresTransaction && identical(transaction._owner, this) && transaction._active
        ? transaction
        : null;
  }

  void _ensureOpen() {
    if (_closed) throw StateError('Database backend is closed');
  }
}

final class _PostgresTransaction implements DatabaseBackend {
  new(this._owner, this._connection);

  final PostgresBackend _owner;
  final pg.Connection _connection;
  final List<_PostgresTransactionStatement> _statements = [];
  bool _active = true;

  @override
  Future<int> execute(String sql, [List<Object?> parameters = const []]) async =>
      (await _run('execute', _portableSql(sql), parameters)).affectedRows;

  @override
  Future<List<Map<String, Object?>>> query(String sql, [List<Object?> parameters = const []]) async =>
      _rows(await _run('query', _portableSql(sql), parameters));

  @override
  Future<DatabaseStatement> prepare(String sql) => _prepare(sql);

  @override
  Future<T> transaction<T>(Future<T> Function(DatabaseBackend tx) body) {
    _ensureActive();
    return Future<T>.error(const NestedTransactionError());
  }

  @override
  Future<void> close() => Future<void>.error(StateError('Transaction handles cannot be closed'));

  Future<pg.Result> _run(String operation, pg.Sql sql, List<Object?> parameters) async {
    _ensureActive();
    _owner._ensureOpen();
    try {
      return await _driverExecute(_connection, sql, parameters: parameters);
    } on PostgresServerFailure catch (error) {
      throw StorageQueryException(
        operation: operation,
        databaseIdentity: _owner.databaseIdentity,
        sqlState: error.sqlState,
        guidance: 'Correct the request before retrying.',
      );
    } on StorageException {
      rethrow;
    } on Object {
      throw StorageUnknownOutcomeException(
        operation: operation,
        databaseIdentity: _owner.databaseIdentity,
        guidance: 'Verify database state before retrying this operation.',
      );
    }
  }

  Future<_PostgresTransactionStatement> _prepare(String sql) async {
    _ensureActive();
    try {
      final statement = await _connection.prepare(_portableSql(sql));
      final wrapped = _PostgresTransactionStatement(this, statement);
      _statements.add(wrapped);
      return wrapped;
    } on pg.ServerException catch (error) {
      throw StorageQueryException(
        operation: 'prepare',
        databaseIdentity: _owner.databaseIdentity,
        sqlState: error.code,
        guidance: 'Correct the request before retrying.',
      );
    } on Object {
      throw StorageUnknownOutcomeException(
        operation: 'prepare',
        databaseIdentity: _owner.databaseIdentity,
        guidance: 'Verify database state before retrying this operation.',
      );
    }
  }

  void _ensureActive() {
    if (!_active) throw StateError('Transaction is no longer active');
  }

  Future<void> _deactivate() async {
    _active = false;
    for (final statement in _statements) {
      await statement._closeDirect();
    }
  }
}

final class _PostgresOwnerStatement implements DatabaseStatement {
  new(this._owner, this._sql);

  final PostgresBackend _owner;
  final String _sql;
  bool _closed = false;

  @override
  Future<int> execute([List<Object?> parameters = const []]) async {
    _ensureUsable();
    return (await _owner._run('execute prepared statement', _sql, parameters)).affectedRows;
  }

  @override
  Future<List<Map<String, Object?>>> query([List<Object?> parameters = const []]) async {
    _ensureUsable();
    return _rows(await _owner._run('query prepared statement', _sql, parameters));
  }

  @override
  Future<void> close() async => _closed = true;

  void _ensureUsable() {
    if (_closed) throw StateError('Database statement is closed');
    _owner._ensureOpen();
  }
}

final class _PostgresTransactionStatement implements DatabaseStatement {
  new(this._transaction, this._statement);

  final _PostgresTransaction _transaction;
  final pg.Statement _statement;
  bool _closed = false;

  @override
  Future<int> execute([List<Object?> parameters = const []]) async => (await _run(parameters)).affectedRows;

  @override
  Future<List<Map<String, Object?>>> query([List<Object?> parameters = const []]) async =>
      _rows(await _run(parameters));

  Future<pg.Result> _run(List<Object?> parameters) async {
    _ensureUsable();
    try {
      return await _statement.run(parameters);
    } on pg.ServerException catch (error) {
      throw StorageQueryException(
        operation: 'prepared statement',
        databaseIdentity: _transaction._owner.databaseIdentity,
        sqlState: error.code,
        guidance: 'Correct the request before retrying.',
      );
    } on Object {
      throw StorageUnknownOutcomeException(
        operation: 'prepared statement',
        databaseIdentity: _transaction._owner.databaseIdentity,
        guidance: 'Verify database state before retrying this operation.',
      );
    }
  }

  @override
  Future<void> close() => _closeDirect();

  Future<void> _closeDirect() async {
    if (_closed) return;
    _closed = true;
    await _statement.dispose();
  }

  void _ensureUsable() {
    if (_closed) throw StateError('Database statement is closed');
    _transaction._ensureActive();
  }
}

pg.Sql _portableSql(String sql) => pg.Sql(rewriteSqlPlaceholders(sql, (ordinal) => '\$$ordinal'));

Future<pg.Result> _driverExecute(
  pg.Session session,
  Object query, {
  List<Object?> parameters = const [],
  pg.QueryMode? queryMode,
}) async {
  try {
    return await session.execute(
      query,
      parameters: [for (final value in parameters) pg.TypedValue(pg.Type.unspecified, value)],
      queryMode: queryMode,
    );
  } on pg.ServerException catch (error) {
    throw PostgresServerFailure(error.code);
  }
}

List<Map<String, Object?>> _rows(pg.Result result) => result
    .map((row) => row.toColumnMap().map((key, value) => MapEntry(key, _canonicalScalar(value))))
    .toList(growable: false);

Object? _canonicalScalar(Object? value) => switch (value) {
  null || int() || double() || String() || Uint8List() => value,
  bool() => value ? 1 : 0,
  DateTime() => value.toUtc().toIso8601String(),
  _ => throw StateError('PostgreSQL returned an unsupported scalar type'),
};

Future<T> _withBoundedLease<T>(
  pg.Pool<void> pool,
  Duration ceiling,
  Future<T> Function(pg.Connection connection) operation,
) async {
  final acquired = Completer<void>();
  var expired = false;
  final lease = pool.withConnection((connection) {
    if (expired) throw const _ExpiredLease();
    acquired.complete();
    return operation(connection);
  });
  unawaited(
    lease.then<void>(
      (_) {
        if (!acquired.isCompleted) acquired.complete();
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!acquired.isCompleted) acquired.completeError(error, stackTrace);
      },
    ),
  );
  try {
    await acquired.future.timeout(ceiling);
  } on TimeoutException {
    expired = true;
    lease.ignore();
    rethrow;
  }
  return lease;
}

final class _ExpiredLease implements Exception {
  const new();
}

final class _PostgresBodyFailure implements Exception {
  const new(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
}
