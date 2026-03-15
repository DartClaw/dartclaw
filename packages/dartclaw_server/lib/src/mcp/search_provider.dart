/// Normalized search result across providers.
class SearchResult {
  final String title;
  final String url;
  final String snippet;

  const SearchResult({required this.title, required this.url, required this.snippet});

  Map<String, dynamic> toJson() => {'title': title, 'url': url, 'snippet': snippet};
}

/// Provider-agnostic search interface.
abstract interface class SearchProvider {
  /// Execute a search query. Returns up to [count] results.
  /// Throws on HTTP/parse errors.
  Future<List<SearchResult>> search(String query, {int count = 5});
}
