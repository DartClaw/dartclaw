import 'package:collection/collection.dart';

/// Supported credential entry shapes.
enum CredentialType {
  /// Legacy API key / provider secret entry.
  apiKey,

  /// GitHub token used for project automation.
  githubToken,

  /// Subscription/OAuth token held in a DartClaw-owned dedicated store.
  subscription,
}

const _credentialEntriesEquality = MapEquality<String, CredentialEntry>();
const _envVarsEquality = ListEquality<String>();

/// Resolved lifetime of a subscription credential.
class CredentialExpiry {
  /// When the credential was issued into the dedicated store.
  final DateTime issuedAt;

  /// When the credential stops being accepted upstream.
  final DateTime expiresAt;

  /// Whether [expiresAt] is a best-effort estimate rather than a value read
  /// from the credential itself.
  ///
  /// A derived expiry drives proactive warnings only — a hard expiry the
  /// derivation misses is still caught by the live authentication failure.
  final bool derived;

  /// Creates a resolved expiry, flagged [derived] when estimated.
  const new({required this.issuedAt, required this.expiresAt, required this.derived});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CredentialExpiry &&
          issuedAt == other.issuedAt &&
          expiresAt == other.expiresAt &&
          derived == other.derived;

  @override
  int get hashCode => Object.hash(issuedAt, expiresAt, derived);

  @override
  String toString() =>
      'CredentialExpiry(issuedAt: ${issuedAt.toIso8601String()}, '
      'expiresAt: ${expiresAt.toIso8601String()}, derived: $derived)';
}

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

  /// Resolved lifetime, present only for subscription credentials whose expiry
  /// could be resolved.
  final CredentialExpiry? expiry;

  /// Creates an API-key credential.
  const new({required String apiKey, this.envVars = const <String>[]})
    : type = CredentialType.apiKey,
      secret = apiKey,
      repository = null,
      expiry = null;

  /// Creates a first-class GitHub token credential.
  const new githubToken({required String token, this.repository, this.envVars = const <String>[]})
    : type = CredentialType.githubToken,
      secret = token,
      expiry = null;

  /// Creates a subscription credential read from a dedicated store.
  const new subscription({required String token, this.expiry, this.envVars = const <String>[]})
    : type = CredentialType.subscription,
      secret = token,
      repository = null;

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

  /// Whether this entry is a subscription credential.
  bool get isSubscriptionCredential => type == CredentialType.subscription;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CredentialEntry &&
          type == other.type &&
          secret == other.secret &&
          repository == other.repository &&
          expiry == other.expiry &&
          _envVarsEquality.equals(envVars, other.envVars);

  @override
  int get hashCode => Object.hash(type, secret, repository, expiry, _envVarsEquality.hash(envVars));

  @override
  String toString() =>
      'CredentialEntry(type: ${type.name}, secret: ${secret.isEmpty ? "<empty>" : "***"}'
      '${repository == null ? "" : ", repository: $repository"}'
      '${expiry == null ? "" : ", expiry: $expiry"}'
      '${envVars.isEmpty ? "" : ", envVars: $envVars"})';
}

/// Multi-credential configuration.
class CredentialsConfig {
  /// Credential entries keyed by credential name.
  final Map<String, CredentialEntry> entries;

  /// const CredentialsConfig({this.entries = const {}});.
  const new({this.entries = const {}});

  /// Creates a [CredentialsConfig.defaults] value.
  const new defaults() : this();

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
