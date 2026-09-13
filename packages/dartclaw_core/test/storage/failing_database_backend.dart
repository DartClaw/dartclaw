import 'package:dartclaw_kernel/dartclaw_kernel.dart';

/// Test decorator that fails one transaction-bound execute call.
final class FailingDatabaseBackend implements DatabaseBackend {
  new(this._delegate, {required int failAt}) : _failAt = failAt;

  final DatabaseBackend _delegate;
  int? _failAt;
  var _executeCount = 0;

  int get executeCount => _executeCount;

  void disableFailure() => _failAt = null;

  @override
  Future<void> close() => _delegate.close();

  @override
  Future<int> execute(String sql, [List<Object?> parameters = const []]) => _delegate.execute(sql, parameters);

  @override
  Future<DatabaseStatement> prepare(String sql) => _delegate.prepare(sql);

  @override
  Future<List<Map<String, Object?>>> query(String sql, [List<Object?> parameters = const []]) =>
      _delegate.query(sql, parameters);

  @override
  Future<T> transaction<T>(Future<T> Function(DatabaseBackend tx) body) {
    _executeCount = 0;
    return _delegate.transaction((tx) => body(_FailingTransaction(tx, this)));
  }

  Future<int> _execute(DatabaseBackend tx, String sql, List<Object?> parameters) {
    _executeCount++;
    if (_executeCount == _failAt) {
      return Future<int>.error(StateError('injected execute failure $_executeCount'));
    }
    return tx.execute(sql, parameters);
  }
}

final class _FailingTransaction implements DatabaseBackend {
  const new(this._delegate, this._owner);

  final DatabaseBackend _delegate;
  final FailingDatabaseBackend _owner;

  @override
  Future<void> close() => _delegate.close();

  @override
  Future<int> execute(String sql, [List<Object?> parameters = const []]) => _owner._execute(_delegate, sql, parameters);

  @override
  Future<DatabaseStatement> prepare(String sql) => _delegate.prepare(sql);

  @override
  Future<List<Map<String, Object?>>> query(String sql, [List<Object?> parameters = const []]) =>
      _delegate.query(sql, parameters);

  @override
  Future<T> transaction<T>(Future<T> Function(DatabaseBackend tx) body) => _delegate.transaction(body);
}
