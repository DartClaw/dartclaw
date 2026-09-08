import 'dart:async';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:postgres/postgres.dart' as pg;

import 'authoritative_store_adoption.dart';
import 'postgres_backend.dart';
import 'postgres_connection_posture.dart';

/// Read-only classification of a retained, inactive PostgreSQL reference.
enum InactivePostgresStoreState { abandoned, empty, inUse, couldNotVerify }

/// Safe result of a best-effort inactive-store probe.
final class InactivePostgresStoreProbe {
  const new(this.state, {this.databaseIdentity, this.reasonClass});

  final InactivePostgresStoreState state;
  final String? databaseIdentity;
  final String? reasonClass;

  /// Operator notice, or `null` when there is no inactive data to report.
  String? get notice => switch (state) {
    InactivePostgresStoreState.abandoned => PostgresStorageMessages.abandoned(databaseIdentity!),
    InactivePostgresStoreState.empty => null,
    InactivePostgresStoreState.inUse => PostgresStorageMessages.inUse(databaseIdentity!),
    InactivePostgresStoreState.couldNotVerify => PostgresStorageMessages.couldNotVerify(reasonClass!),
  };
}

/// Inspects a retained PostgreSQL reference without preparing or changing it.
///
/// Resolution, posture, connection, catalog, audit, and close failures become
/// safe result classifications. An absent reference opens no connection.
Future<InactivePostgresStoreProbe> probeInactivePostgresStore(
  DatabaseConfig config, {
  required ({String dsn, String credentialRef}) Function(DatabaseConfig) resolveDsn,
  GuardAuditLogger? auditLogger,
  Future<pg.Connection> Function(PostgresConnectionPosture)? connectionFactory,
  int interlockKey = PostgresInterlock.defaultKey,
}) async {
  if (config.url == null && config.credential == null) {
    return const InactivePostgresStoreProbe(InactivePostgresStoreState.empty);
  }
  pg.Connection? connection;
  PostgresConnectionPosture? posture;
  var reason = 'unresolved reference';
  var result = const InactivePostgresStoreProbe(
    InactivePostgresStoreState.couldNotVerify,
    reasonClass: 'unresolved reference',
  );
  Future<void> audit(String decision, String verdict) async {
    final checked = posture;
    if (checked == null) return;
    await auditLogger?.writeEntry(
      AuditEntry(
        timestamp: DateTime.now(),
        guard: 'DatabaseEgress',
        hook: 'connection',
        verdict: verdict,
        server: checked.databaseIdentity,
        decision: decision,
        credentialRef: checked.credentialRef,
      ),
    );
  }

  try {
    final reference = resolveDsn(config);
    reason = 'posture refused';
    final checked = posture = evaluatePostgresConnectionPosture(reference.dsn, credentialRef: reference.credentialRef);
    reason = 'unreachable';
    connection =
        await (connectionFactory?.call(checked) ??
            pg.Connection.open(
              checked.endpoint,
              settings: pg.ConnectionSettings(
                sslMode: checked.sslMode,
                connectTimeout: const Duration(seconds: 5),
                queryTimeout: const Duration(seconds: 5),
              ),
            ));
    await audit('open', 'allow');
    reason = 'unknown schema';
    final marker = await connection.execute('SELECT id, epoch FROM dartclaw_schema');
    if (marker.length != 1 || marker.single.length != 2 || marker.single[0] != 1 || marker.single[1] != 1) {
      result = const InactivePostgresStoreProbe(
        InactivePostgresStoreState.couldNotVerify,
        reasonClass: 'unknown schema',
      );
    } else {
      final predicates = authoritativeStoreContentTables.map((table) => 'EXISTS (SELECT 1 FROM $table LIMIT 1)');
      final content = await connection.execute('SELECT ${predicates.join(' OR ')}');
      final holders = await connection.execute(
        r'''
        SELECT 1 FROM pg_locks
        WHERE locktype = 'advisory' AND granted
          AND database = (SELECT oid FROM pg_database WHERE datname = current_database())
          AND classid = $1 AND objid = $2 AND objsubid = 1
        LIMIT 1
      ''',
        parameters: [interlockKey >> 32, interlockKey & 0xffffffff],
      );
      result = InactivePostgresStoreProbe(
        holders.isNotEmpty
            ? InactivePostgresStoreState.inUse
            : content.single.single == true
            ? InactivePostgresStoreState.abandoned
            : InactivePostgresStoreState.empty,
        databaseIdentity: checked.databaseIdentity,
      );
    }
  } on Object catch (error) {
    if (error is TimeoutException) reason = 'timeout';
    if (error is pg.ServerException && (error.code?.startsWith('28') ?? false)) {
      reason = 'authentication failed';
      try {
        await audit('auth_failure', 'deny');
      } on Object {
        /* The probe cannot abort the active backend. */
      }
    }
    result = InactivePostgresStoreProbe(InactivePostgresStoreState.couldNotVerify, reasonClass: reason);
  } finally {
    if (connection != null) {
      try {
        await connection.close();
        await audit('close', 'allow');
      } on Object {
        result = const InactivePostgresStoreProbe(
          InactivePostgresStoreState.couldNotVerify,
          reasonClass: 'close failed',
        );
      }
    }
  }
  return result;
}
