/// Supported authoritative database engines.
enum DatabaseBackendKind {
  /// Local SQLite files.
  sqlite,

  /// One PostgreSQL database.
  postgres,
}

/// Boot-time configuration for authoritative storage.
final class DatabaseConfig {
  /// Creates database configuration.
  const new({this.backend = DatabaseBackendKind.sqlite, this.url, this.credential, this.poolSize = 5});

  /// Default SQLite configuration.
  const new defaults() : this();

  /// Selected database engine.
  final DatabaseBackendKind backend;

  /// PostgreSQL connection URL, when configured directly.
  final String? url;

  /// Named credential containing a PostgreSQL connection URL.
  final String? credential;

  /// Maximum PostgreSQL pool size.
  final int poolSize;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DatabaseConfig &&
          backend == other.backend &&
          url == other.url &&
          credential == other.credential &&
          poolSize == other.poolSize;

  @override
  int get hashCode => Object.hash(backend, url, credential, poolSize);
}
