import 'package:collection/collection.dart';

import 'provider_identity.dart';

const _providerEntriesEquality = MapEquality<String, ProviderEntry>();
const _optionsEquality = DeepCollectionEquality();

/// Configuration for a single agent provider.
class ProviderEntry {
  /// Path to the provider binary.
  final String executable;

  /// Hard ceiling on concurrent worker executions for this provider. 0 = use default.
  final int poolSize;

  /// Provider-specific options for forward compatibility.
  final Map<String, dynamic> options;

  /// const ProviderEntry({required this.executable, this.poolSize.
  const new({required this.executable, this.poolSize = 0, this.options = const {}});

  /// Effective worker capacity after applying the unset default.
  int get effectivePoolSize => poolSize > 0 ? poolSize : 1;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProviderEntry &&
          executable == other.executable &&
          poolSize == other.poolSize &&
          _optionsEquality.equals(options, other.options);

  @override
  int get hashCode => Object.hash(executable, poolSize, _optionsEquality.hash(options));

  @override
  String toString() => 'ProviderEntry(executable: $executable, poolSize: $poolSize, options: $options)';
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
