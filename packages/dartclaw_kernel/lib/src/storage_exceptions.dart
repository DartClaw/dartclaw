/// Base class for safe database failures exposed outside a driver.
abstract base class StorageException implements Exception {
  /// Creates a storage failure from allow-listed diagnostic fields.
  const new({required this.operation, required this.message, this.databaseIdentity});

  /// Operation class that failed.
  final String operation;

  /// Redaction-safe operator guidance.
  final String message;

  /// Safe host, port, and database label, when available.
  final String? databaseIdentity;

  @override
  String toString() => '$runtimeType: $message';
}

/// A database connection could not be established or retained.
final class StorageConnectionException extends StorageException {
  /// Creates a connection failure.
  new({required super.operation, super.databaseIdentity, required String guidance})
    : super(message: _message(operation, databaseIdentity, guidance));
}

/// A database pool lease exceeded its bounded wait.
final class StoragePoolExhaustedException extends StorageException {
  /// Creates a pool-exhaustion failure.
  new({required super.operation, super.databaseIdentity, required String guidance})
    : super(message: _message(operation, databaseIdentity, guidance));
}

/// A database rejected a dispatched query.
final class StorageQueryException extends StorageException {
  /// Creates a query failure with an optional SQLSTATE.
  new({required super.operation, super.databaseIdentity, required String guidance, this.sqlState})
    : super(message: _message(operation, databaseIdentity, guidance, sqlState: sqlState));

  /// PostgreSQL SQLSTATE, when the server supplied one.
  final String? sqlState;
}

/// A dispatched operation lost its response, leaving its outcome unknown.
final class StorageUnknownOutcomeException extends StorageException {
  /// Creates an unknown-outcome failure.
  new({required super.operation, super.databaseIdentity, required String guidance})
    : super(message: _message(operation, databaseIdentity, guidance));
}

/// A configured storage value is unavailable on the selected backend.
final class StorageConfigurationException extends StorageException {
  /// Creates a configuration refusal from safe configuration fields.
  new({required this.key, required this.value, required List<String> validValues})
    : validValues = List.unmodifiable(validValues),
      super(
        operation: 'configuration',
        message:
            '$key "$value" is unavailable on this PostgreSQL server. '
            'Valid values: ${validValues.join(', ')}. '
            'Choose a listed value, restart DartClaw, and rebuild the memory search index.',
      );

  /// Configuration key that was refused.
  final String key;

  /// Configured value that was unavailable.
  final String value;

  /// Values reported by the selected backend.
  final List<String> validValues;
}

/// Refuses a store whose marker or required structure is unsupported.
final class SchemaIncompatibleException extends StorageException {
  /// Creates a typed compatibility refusal.
  new({required this.storeName, required this.foundEpoch, required this.differences, required this.action})
    : super(
        operation: 'schema compatibility',
        message:
            '$storeName is incompatible: expected epoch 1, found $foundEpoch; '
            '${differences.isEmpty ? 'no structural details available' : differences.join('; ')}. $action',
      );

  /// Caller-supplied safe store identity.
  final String storeName;

  /// Human-readable marker state.
  final String foundEpoch;

  /// Required-object or transition failures.
  final List<String> differences;

  /// Operator recovery guidance.
  final String action;
}

String _message(String operation, String? databaseIdentity, String guidance, {String? sqlState}) {
  final target = databaseIdentity == null ? '' : ' for $databaseIdentity';
  final state = sqlState == null ? '' : ' (SQLSTATE $sqlState)';
  return '$operation failed$target$state. $guidance';
}
