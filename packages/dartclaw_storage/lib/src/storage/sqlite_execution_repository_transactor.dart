import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart' show ExecutionRepositoryTransactor;
import 'package:sqlite3/sqlite3.dart';

/// SQLite-backed [ExecutionRepositoryTransactor].
///
/// Serializes concurrent [transaction] callers with a single-slot queue so
/// two callers cannot issue a nested `BEGIN` against the same connection
/// (SQLite rejects nested transactions without SAVEPOINTs).
final class SqliteExecutionRepositoryTransactor implements ExecutionRepositoryTransactor {
  final Database _db;
  Future<void> _tail = Future<void>.value();

  SqliteExecutionRepositoryTransactor(this._db);

  @override
  Future<T> transaction<T>(FutureOr<T> Function() action) {
    final completer = Completer<T>();
    final previous = _tail;
    _tail = completer.future.then<void>((_) {}, onError: (_) {});
    previous.whenComplete(() async {
      try {
        _db.execute('BEGIN');
        try {
          final result = await action();
          _db.execute('COMMIT');
          completer.complete(result);
        } catch (err, st) {
          _db.execute('ROLLBACK');
          completer.completeError(err, st);
        }
      } catch (err, st) {
        completer.completeError(err, st);
      }
    });
    return completer.future;
  }
}
