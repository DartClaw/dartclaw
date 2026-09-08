import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'postgres_backend.dart';
import 'postgres_schema_gate.dart';
import 'sqlite_backend.dart';
import 'sqlite_schema_gate.dart';

/// Selects the configured relational backend factory.
DatabaseBackendFactory databaseBackendFactoryFor(
  DatabaseConfig database, {
  required String Function(DatabaseConfig database) resolveDsn,
}) => switch (database.backend) {
  DatabaseBackendKind.sqlite => SqliteBackend.open,
  DatabaseBackendKind.postgres => (_) => PostgresBackend.open(dsn: resolveDsn(database), poolSize: database.poolSize),
};

/// Prepares the authoritative schema on the selected backend.
Future<void> prepareAuthoritativeStore(DatabaseBackend backend, {required String storeName}) {
  return switch (backend) {
    PostgresBackend() => PostgresSchemaGate.prepare(backend, databaseIdentity: backend.databaseIdentity),
    _ => SqliteSchemaGate.prepareTasks(backend, storeName: storeName),
  };
}
