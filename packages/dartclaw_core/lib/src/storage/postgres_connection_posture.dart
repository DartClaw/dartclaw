import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:postgres/postgres.dart' as pg;

/// Parsed connection settings after DartClaw's PostgreSQL security checks.
final class PostgresConnectionPosture {
  /// Creates a checked connection posture.
  const new({
    required this.endpoint,
    required this.sslMode,
    required this.databaseIdentity,
    required this.credentialRef,
  });

  /// Driver endpoint containing the in-memory connection credential.
  final pg.Endpoint endpoint;

  /// TLS mode passed to the driver.
  final pg.SslMode sslMode;

  /// Safe host, port, database, and optional namespace label.
  final String databaseIdentity;

  /// Configuration reference name, never the resolved credential value.
  final String credentialRef;
}

/// Parses [dsn] and applies the PostgreSQL TLS posture before any connection is opened.
///
/// Only PostgreSQL URI connection strings are accepted. Cleartext is allowed
/// only for the three literal loopback hosts recognized by [isLoopbackHost].
PostgresConnectionPosture evaluatePostgresConnectionPosture(
  String dsn, {
  required String credentialRef,
  String? namespace,
}) {
  if (namespace != null && !RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(namespace)) {
    throw StorageConnectionException(operation: 'connect', guidance: 'Provide a valid PostgreSQL namespace.');
  }
  final Uri uri;
  try {
    uri = Uri.parse(dsn);
  } on FormatException {
    throw _malformed('Use a postgres or postgresql URI connection string.');
  }
  if ((uri.scheme != 'postgres' && uri.scheme != 'postgresql') || uri.host.isEmpty || uri.hasFragment) {
    throw _malformed('Use a postgres or postgresql URI connection string.');
  }
  if (uri.pathSegments.length > 1) {
    throw _malformed('Use a PostgreSQL URL with one database path segment.');
  }

  for (final entry in uri.queryParametersAll.entries) {
    if (entry.key != 'sslmode') {
      throw _malformed('Unsupported PostgreSQL URL parameter "${entry.key}".');
    }
    if (entry.value.length != 1) {
      throw _malformed('PostgreSQL URL parameter "sslmode" must appear once.');
    }
  }

  final loopback = isLoopbackHost(uri.host);
  final sslMode = switch (uri.queryParameters['sslmode']) {
    null => loopback ? pg.SslMode.require : pg.SslMode.verifyFull,
    'verify-full' || 'verify-ca' => pg.SslMode.verifyFull,
    'require' => pg.SslMode.require,
    'disable' when loopback => pg.SslMode.disable,
    'disable' => throw StorageConnectionException(
      operation: 'connect',
      guidance:
          'Cleartext PostgreSQL connections to non-loopback hosts are refused. '
          'Only localhost, 127.0.0.1, and ::1 are exempt.',
    ),
    _ => throw _malformed('Unsupported PostgreSQL URL parameter "sslmode" value.'),
  };

  final database = uri.pathSegments.isEmpty || uri.pathSegments.single.isEmpty ? 'postgres' : uri.pathSegments.single;
  final String? username;
  final String? password;
  try {
    final userInfo = uri.userInfo;
    final separator = userInfo.indexOf(':');
    username = userInfo.isEmpty
        ? null
        : Uri.decodeComponent(separator < 0 ? userInfo : userInfo.substring(0, separator));
    password = separator < 0 ? null : Uri.decodeComponent(userInfo.substring(separator + 1));
  } on FormatException {
    throw _malformed('PostgreSQL URL userinfo is malformed.');
  }
  final port = uri.hasPort ? uri.port : 5432;
  final identity = '${uri.host}:$port/$database${namespace == null ? '' : '/$namespace'}';
  return PostgresConnectionPosture(
    endpoint: pg.Endpoint(host: uri.host, port: port, database: database, username: username, password: password),
    sslMode: sslMode,
    databaseIdentity: identity,
    credentialRef: credentialRef,
  );
}

StorageConnectionException _malformed(String guidance) =>
    StorageConnectionException(operation: 'connect', guidance: guidance);
