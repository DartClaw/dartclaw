import 'dart:typed_data';

/// Opens a database backend at [path].
typedef DatabaseBackendFactory = Future<DatabaseBackend> Function(String path);

/// Portable database operations shared by storage repositories.
///
/// SQL uses positional `?` placeholders. Values and result rows use SQLite's
/// portable scalar set: [int], [double], [String], [Uint8List], and `null`.
/// Booleans are represented as `0` or `1`, and timestamps as ISO 8601 strings.
/// Insert-and-fetch operations use `RETURNING`; engine-specific row-id access
/// is deliberately not part of this contract.
abstract interface class DatabaseBackend {
  /// Executes [sql] and returns the number of affected rows.
  Future<int> execute(String sql, [List<Object?> parameters = const <Object?>[]]);

  /// Executes [sql] and returns its result rows.
  Future<List<Map<String, Object?>>> query(String sql, [List<Object?> parameters = const <Object?>[]]);

  /// Prepares [sql] for repeated execution.
  ///
  /// A statement prepared through a transaction handle, or through its owning
  /// backend from the transaction body, is valid only until that transaction
  /// completes. Later [DatabaseStatement.execute] and
  /// [DatabaseStatement.query] calls throw [StateError].
  Future<DatabaseStatement> prepare(String sql);

  /// Runs [body] atomically and returns its result.
  ///
  /// Operations issued through the transaction handle join the transaction.
  /// SQLite backends also join calls made reentrantly through the owning backend
  /// from [body], while unrelated SQLite operations wait until it completes.
  /// Nested calls throw [NestedTransactionError]. Closing a transaction handle
  /// always throws [StateError]; other use after [body] completes does likewise.
  /// An error from [body] is rethrown with its original stack after rollback,
  /// including when rollback cleanup itself fails.
  Future<T> transaction<T>(Future<T> Function(DatabaseBackend tx) body);

  /// Closes an owning backend. Repeated calls on that owner are no-ops.
  ///
  /// Transaction handles reject this operation with [StateError].
  Future<void> close();
}

/// A prepared portable database statement.
abstract interface class DatabaseStatement {
  /// Executes this statement and returns the number of affected rows.
  ///
  /// Throws [StateError] after [close], after its owning backend closes, or
  /// after the transaction that created this statement has completed.
  Future<int> execute([List<Object?> parameters = const <Object?>[]]);

  /// Executes this statement and returns its result rows.
  ///
  /// Throws [StateError] after [close], after its owning backend closes, or
  /// after the transaction that created this statement has completed.
  Future<List<Map<String, Object?>>> query([List<Object?> parameters = const <Object?>[]]);

  /// Releases this statement. Repeated calls and cleanup after its owning
  /// backend or transaction closes are safe no-ops.
  Future<void> close();
}

/// Raised when a transaction is requested from an active transaction body.
final class NestedTransactionError implements Exception {
  /// Creates the nested-transaction error.
  const new();

  @override
  String toString() => 'NestedTransactionError: nested transactions are not supported';
}
