/// Configuration for a single search provider (e.g. Brave, Tavily).
class SearchProviderEntry {
  final bool enabled;
  final String apiKey;

  const SearchProviderEntry({required this.enabled, required this.apiKey});
}

/// Configuration for the search subsystem.
class SearchConfig {
  final String backend;
  final String qmdHost;
  final int qmdPort;
  final String defaultDepth;
  final Map<String, SearchProviderEntry> providers;

  const SearchConfig({
    this.backend = 'fts5',
    this.qmdHost = '127.0.0.1',
    this.qmdPort = 8181,
    this.defaultDepth = 'standard',
    this.providers = const {},
  });

  /// Default configuration.
  const SearchConfig.defaults() : this();
}
