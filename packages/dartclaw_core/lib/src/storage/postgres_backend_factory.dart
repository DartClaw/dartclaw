import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'postgres_backend.dart';

/// Creates the sole authoritative PostgreSQL backend factory.
DatabaseBackendFactory postgresBackendFactory(
  DatabaseConfig database, {
  required ({String dsn, String credentialRef}) Function(DatabaseConfig database) resolveDsn,
  GuardAuditLogger? auditLogger,
}) => (_) {
  final resolved = resolveDsn(database);
  return PostgresBackend.open(
    dsn: resolved.dsn,
    credentialRef: resolved.credentialRef,
    poolSize: database.poolSize,
    auditLogger: auditLogger,
  );
};
