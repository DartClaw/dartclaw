import 'package:collection/collection.dart';

import 'provider_identity.dart';

const _providerEntriesEquality = MapEquality<String, ProviderEntry>();
const _optionsEquality = DeepCollectionEquality();

/// Which credential a provider presents upstream (`providers.<id>.auth`).
enum ProviderAuth {
  /// Prefer the subscription credential, fall back to the API key.
  auto('auto'),

  /// Present the subscription credential, never the API key.
  subscription('subscription'),

  /// Present the API key, never the subscription credential.
  apiKey('api_key'),

  /// The configured value was not one of the accepted settings; no credential
  /// is presented, so a typo cannot silently select a credential.
  unrecognized('');

  /// YAML value for this setting, empty for [unrecognized].
  final String yamlValue;

  new(this.yamlValue);

  /// Accepted YAML values.
  static const acceptedValues = <String>['auto', 'subscription', 'api_key'];

  /// Parses a YAML value, returning [unrecognized] for anything else so a typo
  /// presents no credential instead of silently selecting one.
  ///
  /// String values are trimmed and lowercased first, matching how provider IDs
  /// and the other typed provider keys are normalized — a capitalization
  /// variant is not a typo and must not refuse the provider.
  static ProviderAuth fromYaml(Object? value) {
    final normalized = value is String ? value.trim().toLowerCase() : value;
    for (final auth in values) {
      if (auth != unrecognized && auth.yamlValue == normalized) return auth;
    }
    return unrecognized;
  }
}

/// Configuration for a single agent provider.
class ProviderEntry {
  /// Path to the provider binary.
  final String executable;

  /// Hard ceiling on concurrent worker executions for this provider. 0 = use default.
  final int poolSize;

  /// Which credential this provider presents upstream, or `null` when the entry
  /// configures no `auth`.
  ///
  /// `null` is distinct from [ProviderAuth.auto]: an unset value is what a
  /// provider alias inherits from its resolved family, whereas an explicit
  /// `auth: auto` is the operator's own choice and overrides the family.
  final ProviderAuth? auth;

  /// Provider-specific options for forward compatibility.
  final Map<String, dynamic> options;

  /// Creates a provider entry; [auth] is `null` when unconfigured.
  const new({required this.executable, this.poolSize = 0, this.auth, this.options = const {}});

  /// Effective worker capacity after applying the unset default.
  int get effectivePoolSize => poolSize > 0 ? poolSize : 1;

  /// Returns a copy with the given fields replaced, carrying every other field
  /// verbatim.
  ///
  /// [auth] cannot be cleared through this: an omitted argument keeps the
  /// current value, so an entry that configures no `auth` still configures none
  /// afterwards and its family inheritance survives the rebuild.
  ProviderEntry copyWith({String? executable, int? poolSize, ProviderAuth? auth, Map<String, dynamic>? options}) =>
      ProviderEntry(
        executable: executable ?? this.executable,
        poolSize: poolSize ?? this.poolSize,
        auth: auth ?? this.auth,
        options: options ?? this.options,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProviderEntry &&
          executable == other.executable &&
          poolSize == other.poolSize &&
          auth == other.auth &&
          _optionsEquality.equals(options, other.options);

  @override
  int get hashCode => Object.hash(executable, poolSize, auth, _optionsEquality.hash(options));

  @override
  String toString() =>
      'ProviderEntry(executable: $executable, poolSize: $poolSize, auth: ${auth?.name}, options: $options)';
}

/// Multi-provider configuration.
class ProvidersConfig {
  /// Provider entries keyed by provider ID.
  final Map<String, ProviderEntry> entries;

  /// const ProvidersConfig({this.entries = const {}});.
  const new({this.entries = const {}});

  /// Creates a [ProvidersConfig.defaults] value.
  const new defaults() : this();

  /// Returns the entry for [providerId], or `null` if not configured.
  ProviderEntry? operator [](String providerId) {
    if (providerId.trim().isEmpty) return null;
    final normalized = ProviderIdentity.normalize(providerId);
    ProviderEntry? match;
    for (final entry in entries.entries) {
      if (entry.key.trim().isEmpty) continue;
      if (ProviderIdentity.normalize(entry.key) != normalized) continue;
      if (match != null) {
        throw StateError('Configured provider IDs collide after normalization to "$normalized"');
      }
      match = entry.value;
    }
    return match;
  }

  /// Whether any providers are explicitly configured.
  bool get isEmpty => entries.isEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is ProvidersConfig && _providerEntriesEquality.equals(entries, other.entries);

  @override
  int get hashCode => _providerEntriesEquality.hash(entries);

  @override
  String toString() => 'ProvidersConfig(entries: $entries)';
}
