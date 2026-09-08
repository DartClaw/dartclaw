import 'dart:io';
import 'dart:math';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:postgres/postgres.dart';

Future<T> withPostgresBackend<T>(
  Future<T> Function(PostgresBackend backend, String namespace) body, {
  GuardAuditLogger? auditLogger,
  String credentialRef = 'DARTCLAW_TEST_POSTGRES_URL',
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
  PostgresBackend? backend;
  try {
    backend = await PostgresBackend.open(
      dsn: dsn,
      poolSize: 3,
      namespace: namespace,
      auditLogger: auditLogger,
      credentialRef: credentialRef,
    );
    return await body(backend, namespace);
  } finally {
    await backend?.close();
    await admin.execute('DROP SCHEMA IF EXISTS "$namespace" CASCADE');
    await admin.close();
  }
}
