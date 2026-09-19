import 'dart:io';
import 'dart:math';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:postgres/postgres.dart';

Future<T> withPostgresBackend<T>(
  Future<T> Function(PostgresBackend backend, String namespace) body, {
  GuardAuditLogger? auditLogger,
  String credentialRef = 'DARTCLAW_TEST_POSTGRES_URL',
  bool restrictedRole = false,
}) async {
  final configured = Platform.environment['DARTCLAW_TEST_POSTGRES_URL'];
  if (configured == null || configured.isEmpty) {
    throw StateError('DARTCLAW_TEST_POSTGRES_URL is required');
  }
  final uri = Uri.parse(configured);
  final dsn = uri.replace(queryParameters: {...uri.queryParameters, 'sslmode': 'disable'}).toString();
  final namespace = 'dc_test_${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(1 << 20)}';
  final admin = await Connection.openFromUrl(dsn);
  await admin.execute('CREATE SCHEMA "$namespace"');
  final role = '${namespace}_runtime';
  var roleCreated = false;
  PostgresBackend? backend;
  try {
    var backendDsn = dsn;
    if (restrictedRole) {
      const password = 'RestrictedVectorFixturePasswordX9';
      await admin.execute('CREATE ROLE "$role" LOGIN PASSWORD \'$password\' NOSUPERUSER NOCREATEDB NOCREATEROLE');
      roleCreated = true;
      await admin.execute('ALTER SCHEMA "$namespace" OWNER TO "$role"');
      backendDsn = Uri.parse(dsn).replace(userInfo: '$role:$password').toString();
    }
    backend = await PostgresBackend.open(
      dsn: backendDsn,
      poolSize: 3,
      namespace: namespace,
      auditLogger: auditLogger,
      credentialRef: credentialRef,
    );
    return await body(backend, namespace);
  } finally {
    await backend?.close();
    await admin.execute('DROP SCHEMA IF EXISTS "$namespace" CASCADE');
    if (roleCreated) await admin.execute('DROP ROLE "$role"');
    await admin.close();
  }
}

Future<Connection> openPostgresTestConnection(PostgresConnectionPosture posture, {required String namespace}) async {
  final connection = await Connection.open(posture.endpoint, settings: ConnectionSettings(sslMode: posture.sslMode));
  try {
    await connection.execute('SET search_path TO "$namespace"');
    return connection;
  } catch (_) {
    await connection.close();
    rethrow;
  }
}
