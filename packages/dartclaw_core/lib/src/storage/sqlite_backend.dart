import 'dart:async';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// SQLite implementation of the portable [DatabaseBackend] contract.
final class SqliteBackend implements DatabaseBackend {
  final sqlite.Database _database;
  final Object _transactionZoneKey = Object();
  Future<void> _tail = Future<void>.value();
  _SqliteTransaction? _activeTransaction;
  bool _closed = false;

  /// Wraps an existing open SQLite [sqlite.Database].
  new(this._database);

  /// Opens a SQLite backend at [path].
  static Future<SqliteBackend> open(String path) async => SqliteBackend(sqlite.sqlite3.open(path));

  /// Opens an in-memory SQLite backend.
  static SqliteBackend openInMemory() => SqliteBackend(sqlite.sqlite3.openInMemory());

  @override
  Future<int> execute(String sql, [List<Object?> parameters = const <Object?>[]]) {
    return _run(() => _executeDirect(sql, parameters));
  }

  @override
  Future<List<Map<String, Object?>>> query(String sql, [List<Object?> parameters = const <Object?>[]]) {
    return _run(() => _queryDirect(sql, parameters));
  }

  @override
  Future<DatabaseStatement> prepare(String sql) {
    return _run(() => _prepareDirect(sql, _matchingZoneTransaction));
  }

  @override
  Future<T> transaction<T>(Future<T> Function(DatabaseBackend tx) body) {
    _ensureOpen();
    if (_matchingZoneTransaction != null) {
      return Future<T>.error(const NestedTransactionError());
    }

    return _enqueue(() async {
      _ensureOpen();
      _database.execute('BEGIN');
      final transaction = _SqliteTransaction(this);
      _activeTransaction = transaction;
      try {
        final result = await runZoned(() => body(transaction), zoneValues: {_transactionZoneKey: transaction});
        _database.execute('COMMIT');
        return result;
      } catch (error, stackTrace) {
        try {
          _database.execute('ROLLBACK');
        } catch (_) {}
        Error.throwWithStackTrace(error, stackTrace);
      } finally {
        transaction._deactivate();
        if (identical(_activeTransaction, transaction)) {
          _activeTransaction = null;
        }
      }
    });
  }

  @override
  Future<void> close() {
    if (_closed) return Future<void>.value();
    if (_matchingZoneTransaction != null) {
      return Future<void>.error(StateError('Cannot close a backend from its active transaction'));
    }
    return _enqueue(() {
      if (_closed) return;
      _database.close();
      _closed = true;
    });
  }

  _SqliteTransaction? get _matchingZoneTransaction {
    final transaction = Zone.current[_transactionZoneKey];
    return transaction is _SqliteTransaction && identical(transaction, _activeTransaction) && transaction._active
        ? transaction
        : null;
  }

  Future<T> _run<T>(T Function() operation) {
    _ensureOpen();
    final transaction = _matchingZoneTransaction;
    if (transaction != null) {
      return Future<T>.sync(() {
        transaction._ensureActive();
        _ensureOpen();
        return operation();
      });
    }
    return _enqueue(() {
      _ensureOpen();
      return operation();
    });
  }

  Future<void> _closeStatement(void Function() close) {
    if (_matchingZoneTransaction != null) {
      return Future<void>.sync(close);
    }
    return _enqueue(close);
  }

  Future<T> _enqueue<T>(FutureOr<T> Function() operation) {
    final completer = Completer<T>();
    final previous = _tail;
    _tail = completer.future.then<void>((_) {}, onError: (_) {});
    previous.whenComplete(() async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  int _executeDirect(String sql, List<Object?> parameters) {
    _database.execute(sql, parameters);
    return _database.updatedRows;
  }

  List<Map<String, Object?>> _queryDirect(String sql, List<Object?> parameters) {
    return _database.select(sql, parameters).map((row) => Map<String, Object?>.from(row)).toList(growable: false);
  }

  _SqliteStatement _prepareDirect(String sql, _SqliteTransaction? transaction) {
    final statement = _SqliteStatement(this, _database.prepare(sql), transaction);
    transaction?._statements.add(statement);
    return statement;
  }

  void _ensureOpen() {
    if (_closed) throw StateError('Database backend is closed');
  }
}

final class _SqliteTransaction implements DatabaseBackend {
  final SqliteBackend _owner;
  final List<_SqliteStatement> _statements = [];
  bool _active = true;

  new(this._owner);

  @override
  Future<int> execute(String sql, [List<Object?> parameters = const <Object?>[]]) {
    return _run(() => _owner._executeDirect(sql, parameters));
  }

  @override
  Future<List<Map<String, Object?>>> query(String sql, [List<Object?> parameters = const <Object?>[]]) {
    return _run(() => _owner._queryDirect(sql, parameters));
  }

  @override
  Future<DatabaseStatement> prepare(String sql) {
    return _run(() => _owner._prepareDirect(sql, this));
  }

  @override
  Future<T> transaction<T>(Future<T> Function(DatabaseBackend tx) body) {
    try {
      _ensureActive();
    } catch (error, stackTrace) {
      return Future<T>.error(error, stackTrace);
    }
    return Future<T>.error(const NestedTransactionError());
  }

  @override
  Future<void> close() => Future<void>.error(StateError('Transaction handles cannot be closed'));

  Future<T> _run<T>(T Function() operation) {
    return Future<T>.sync(() {
      _ensureActive();
      _owner._ensureOpen();
      return operation();
    });
  }

  void _ensureActive() {
    if (!_active || !identical(_owner._activeTransaction, this)) {
      throw StateError('Transaction is no longer active');
    }
  }

  void _deactivate() {
    _active = false;
    for (final statement in _statements) {
      statement._closeDirect();
    }
  }
}

final class _SqliteStatement implements DatabaseStatement {
  final SqliteBackend _owner;
  final sqlite.PreparedStatement _statement;
  final _SqliteTransaction? _transaction;
  bool _closed = false;

  new(this._owner, this._statement, this._transaction);

  @override
  Future<int> execute([List<Object?> parameters = const <Object?>[]]) {
    return _run(() {
      _ensureUsable();
      _statement.execute(parameters);
      return _owner._database.updatedRows;
    });
  }

  @override
  Future<List<Map<String, Object?>>> query([List<Object?> parameters = const <Object?>[]]) {
    return _run(() {
      _ensureUsable();
      return _statement.select(parameters).map((row) => Map<String, Object?>.from(row)).toList(growable: false);
    });
  }

  @override
  Future<void> close() {
    if (_closed) return Future<void>.value();
    final transaction = _transaction;
    if (transaction != null) {
      if (!transaction._active) {
        _closeDirect();
        return Future<void>.value();
      }
      return transaction._run(_closeDirect);
    }
    return _owner._closeStatement(_closeDirect);
  }

  Future<T> _run<T>(T Function() operation) {
    final transaction = _transaction;
    return transaction == null ? _owner._run(operation) : transaction._run(operation);
  }

  void _ensureUsable() {
    if (_closed) throw StateError('Database statement is closed');
    _transaction?._ensureActive();
  }

  void _closeDirect() {
    if (_closed) return;
    _statement.close();
    _closed = true;
  }
}
