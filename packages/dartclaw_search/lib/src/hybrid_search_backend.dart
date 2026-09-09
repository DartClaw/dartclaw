import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'hybrid_search.dart';

/// Adapts hybrid memory retrieval to the existing memory search boundary.
final class HybridSearchBackend implements SearchBackend {
  /// Creates an adapter using the corpus owner's canonical result mapper.
  new({required HybridSearch search, required MemorySearchResult Function(SearchResult result) toMemoryResult})
    : _search = search,
      _toMemoryResult = toMemoryResult;

  final HybridSearch _search;
  final MemorySearchResult Function(SearchResult result) _toMemoryResult;

  @override
  Future<MemorySearchOutcome> search(
    String query, {
    int limit = 10,
    String userId = 'owner',
    Set<SearchResultLayer>? layers,
  }) async {
    if (layers != null && !layers.contains(SearchResultLayer.memory)) {
      return const MemorySearchOutcome(results: []);
    }
    SearchDiagnostics? diagnostics;
    final results = await _search.search(
      query,
      userId: userId,
      limit: limit,
      diagnostics: (value) => diagnostics = value,
    );
    final degradations = diagnostics?.degradations ?? const <MemorySearchDegradation>[];
    return MemorySearchOutcome(
      results: results.map(_toMemoryResult).toList(growable: false),
      degradedLayers: degradations.map((item) => item.layer).toSet().toList(growable: false),
      degradations: degradations,
    );
  }

  @override
  Future<MemorySearchResult?> resolve(String locator, {String userId = 'owner'}) async => null;

  @override
  Future<void> indexAfterWrite() async {}
}
