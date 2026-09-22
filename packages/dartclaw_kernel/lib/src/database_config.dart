import 'package:collection/collection.dart';

/// Boot-time configuration for authoritative storage.
final class DatabaseConfig {
  /// Creates database configuration.
  const new({this.url, this.credential, this.urlEnvVars = const [], this.poolSize = 5, this.ftsLanguage = 'english'});

  /// Default PostgreSQL configuration.
  const new defaults() : this();

  /// PostgreSQL connection URL, when configured directly.
  final String? url;

  /// Named credential containing a PostgreSQL connection URL.
  final String? credential;

  /// Environment variables referenced by the persisted URL template.
  final List<String> urlEnvVars;

  /// Maximum PostgreSQL pool size.
  final int poolSize;

  /// PostgreSQL text-search configuration shared by derived search paths.
  final String ftsLanguage;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DatabaseConfig &&
          url == other.url &&
          credential == other.credential &&
          const ListEquality<String>().equals(urlEnvVars, other.urlEnvVars) &&
          poolSize == other.poolSize &&
          ftsLanguage == other.ftsLanguage;

  @override
  int get hashCode =>
      Object.hash(url, credential, const ListEquality<String>().hash(urlEnvVars), poolSize, ftsLanguage);
}
