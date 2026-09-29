import 'package:dartclaw_kernel/dartclaw_kernel.dart';

Future<DatabaseBackend> openPreparedTaskBackend() async => _PreparedTestBackend();

final class _PreparedTestBackend implements DatabaseBackend {
  var _closed = false;

  @override
  Future<void> close() async => _closed = true;

  @override
  Future<int> execute(String sql, [List<Object?> parameters = const []]) async {
    _ensureOpen();
    return 1;
  }

  @override
  Future<DatabaseStatement> prepare(String sql) async {
    _ensureOpen();
    return _PreparedTestStatement(this, sql);
  }

  @override
  Future<List<Map<String, Object?>>> query(String sql, [List<Object?> parameters = const []]) async {
    _ensureOpen();
    if (sql.trim().toUpperCase() == 'SELECT 1') {
      return const [
        <String, Object?>{'?column?': 1},
      ];
    }
    return const [];
  }

  @override
  Future<T> transaction<T>(Future<T> Function(DatabaseBackend tx) body) {
    _ensureOpen();
    return body(this);
  }

  void _ensureOpen() {
    if (_closed) throw StateError('Database backend is closed');
  }
}

final class _PreparedTestStatement implements DatabaseStatement {
  const new(this._backend, this._sql);

  final _PreparedTestBackend _backend;
  final String _sql;

  @override
  Future<void> close() async {}

  @override
  Future<int> execute([List<Object?> parameters = const []]) => _backend.execute(_sql, parameters);

  @override
  Future<List<Map<String, Object?>>> query([List<Object?> parameters = const []]) => _backend.query(_sql, parameters);
}
