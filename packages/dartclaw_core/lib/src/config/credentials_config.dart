import 'package:collection/collection.dart';

const _credentialEntriesEquality = MapEquality<String, CredentialEntry>();

/// A single credential entry with a resolved API key.
class CredentialEntry {
  /// The resolved API key value.
  final String apiKey;

  const CredentialEntry({required this.apiKey});

  /// Whether the API key is non-empty.
  bool get isPresent => apiKey.isNotEmpty;

  @override
  bool operator ==(Object other) => identical(this, other) || other is CredentialEntry && apiKey == other.apiKey;

  @override
  int get hashCode => apiKey.hashCode;

  @override
  String toString() => 'CredentialEntry(apiKey: ${apiKey.isEmpty ? "<empty>" : "***"})';
}

/// Multi-credential configuration.
class CredentialsConfig {
  /// Credential entries keyed by credential name.
  final Map<String, CredentialEntry> entries;

  const CredentialsConfig({this.entries = const {}});

  const CredentialsConfig.defaults() : this();

  /// Returns the entry for [name], or `null` if not configured.
  CredentialEntry? operator [](String name) => entries[name];

  /// Whether any credentials are explicitly configured.
  bool get isEmpty => entries.isEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is CredentialsConfig && _credentialEntriesEquality.equals(entries, other.entries);

  @override
  int get hashCode => _credentialEntriesEquality.hash(entries);

  @override
  String toString() => 'CredentialsConfig(entries: $entries)';
}
