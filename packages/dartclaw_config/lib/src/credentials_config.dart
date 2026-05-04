import 'package:collection/collection.dart';

/// Supported credential entry shapes.
enum CredentialType {
  /// Legacy API key / provider secret entry.
  apiKey,

  /// GitHub token used for project automation.
  githubToken,
}

const _credentialEntriesEquality = MapEquality<String, CredentialEntry>();
const _envVarsEquality = ListEquality<String>();

/// A single credential entry with a resolved secret value.
class CredentialEntry {
  /// The credential type.
  final CredentialType type;

  /// The resolved secret value.
  final String secret;

  /// Optional repository policy for project-scoped credentials.
  final String? repository;

  /// Env var names referenced by the original YAML template (e.g. `GITHUB_TOKEN`
  /// for `token: ${GITHUB_TOKEN}`), preserved so downstream diagnostics can
  /// name the real variable even after `envSubstitute` has resolved the value.
  /// Empty when the credential was configured with a literal value.
  final List<String> envVars;

  const CredentialEntry({required String apiKey, this.envVars = const <String>[]})
    : type = CredentialType.apiKey,
      secret = apiKey,
      repository = null;

  /// Creates a first-class GitHub token credential.
  const CredentialEntry.githubToken({required String token, this.repository, this.envVars = const <String>[]})
    : type = CredentialType.githubToken,
      secret = token;

  /// Backward-compatible API-key getter used by provider credential lookup.
  String get apiKey => secret;

  /// Token getter for typed token credentials.
  String get token => secret;

  /// Whether the secret value is non-empty.
  bool get isPresent => secret.isNotEmpty;

  /// Whether this entry is a provider-style API key credential.
  bool get isApiKeyCredential => type == CredentialType.apiKey;

  /// Whether this entry is a GitHub token credential.
  bool get isGitHubToken => type == CredentialType.githubToken;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CredentialEntry &&
          type == other.type &&
          secret == other.secret &&
          repository == other.repository &&
          _envVarsEquality.equals(envVars, other.envVars);

  @override
  int get hashCode => Object.hash(type, secret, repository, _envVarsEquality.hash(envVars));

  @override
  String toString() =>
      'CredentialEntry(type: ${type.name}, secret: ${secret.isEmpty ? "<empty>" : "***"}'
      '${repository == null ? "" : ", repository: $repository"}'
      '${envVars.isEmpty ? "" : ", envVars: $envVars"})';
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
