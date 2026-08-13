/// Normalized search result across providers.
class SearchResult {
  final String title;
  final String url;
  final String snippet;

  const new({required this.title, required this.url, required this.snippet});

  Map<String, dynamic> toJson() => {'title': title, 'url': url, 'snippet': snippet};
}

List<SearchResult> decodeSearchResults(List<dynamic> results, {required String snippetField}) {
  return results.map((result) {
    final item = result as Map<String, dynamic>;
    return SearchResult(
      title: item['title'] as String? ?? '',
      url: item['url'] as String? ?? '',
      snippet: item[snippetField] as String? ?? '',
    );
  }).toList();
}

/// Provider-agnostic search interface.
abstract interface class SearchProvider {
  /// Execute a search query. Returns up to [count] results.
  /// Throws on HTTP/parse errors.
  Future<List<SearchResult>> search(String query, {int count = 5});
}
