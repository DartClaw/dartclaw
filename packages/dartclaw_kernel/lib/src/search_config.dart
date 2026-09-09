import 'package:collection/collection.dart';

import 'network_guard.dart';

/// Configuration for a single search provider (e.g. Brave, Tavily).
class SearchProviderEntry {
  /// enabled.
  final bool enabled;

  /// apiKey.
  final String apiKey;

  /// const SearchProviderEntry({required this.enabled, required t.
  const new({required this.enabled, required this.apiKey});

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is SearchProviderEntry && enabled == other.enabled && apiKey == other.apiKey;

  @override
  int get hashCode => Object.hash(enabled, apiKey);
}

/// Embedding implementation selected for native hybrid search.
enum EmbeddingProviderKind {
  /// The bundled in-process provider using the managed verified model.
  local,

  /// An explicitly configured OpenAI-compatible HTTP endpoint.
  http,
}

/// Whether [endpoint] is safe to retain as an explicit HTTP embedding endpoint.
bool isValidEmbeddingEndpoint(Uri? endpoint) =>
    endpoint != null &&
    endpoint.hasScheme &&
    (endpoint.scheme == 'http' || endpoint.scheme == 'https') &&
    endpoint.host.isNotEmpty &&
    endpoint.userInfo.isEmpty &&
    !endpoint.hasQuery &&
    !endpoint.hasFragment;

/// Whether [endpoint] may carry the named [credential] without exposing it over public HTTP.
bool isValidEmbeddingCredentialEndpoint(Uri? endpoint, String? credential) =>
    isValidEmbeddingEndpoint(endpoint) &&
    (credential == null || endpoint!.scheme == 'https' || isLoopbackHost(endpoint.host));

/// Embedding settings for native hybrid search.
final class EmbeddingConfig {
  /// Selected embedding implementation.
  final EmbeddingProviderKind provider;

  /// Provider model name or supported local artifact selector.
  final String model;

  /// HTTP embedding endpoint, present only for [EmbeddingProviderKind.http].
  final Uri? endpoint;

  /// Name of the generic API-key credential presented to the HTTP endpoint.
  final String? credential;

  /// Creates an [EmbeddingConfig] value.
  const new({
    this.provider = EmbeddingProviderKind.local,
    this.model = 'embeddinggemma-300M-Q8_0.gguf',
    this.endpoint,
    this.credential,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EmbeddingConfig &&
          provider == other.provider &&
          model == other.model &&
          endpoint == other.endpoint &&
          credential == other.credential;

  @override
  int get hashCode => Object.hash(provider, model, endpoint, credential);
}

/// Configuration for the search subsystem.
class SearchConfig {
  /// backend.
  final String backend;

  /// qmdHost.
  final String qmdHost;

  /// qmdPort.
  final int qmdPort;

  /// defaultDepth.
  final String defaultDepth;

  /// providers.
  final Map<String, SearchProviderEntry> providers;

  /// Embedding provider settings used when [backend] is `hybrid`.
  final EmbeddingConfig embedding;

  /// Creates a [SearchConfig] value.
  const new({
    this.backend = 'fts5',
    this.qmdHost = '127.0.0.1',
    this.qmdPort = 8181,
    this.defaultDepth = 'standard',
    this.providers = const {},
    this.embedding = const EmbeddingConfig(),
  });

  /// Default configuration.
  const new defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SearchConfig &&
          backend == other.backend &&
          qmdHost == other.qmdHost &&
          qmdPort == other.qmdPort &&
          defaultDepth == other.defaultDepth &&
          const MapEquality<String, SearchProviderEntry>().equals(providers, other.providers) &&
          embedding == other.embedding;

  @override
  int get hashCode => Object.hash(
    backend,
    qmdHost,
    qmdPort,
    defaultDepth,
    const MapEquality<String, SearchProviderEntry>().hash(providers),
    embedding,
  );
}
