import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import '../memory/memory_index_projection.dart';

/// FTS5-based personal-memory search backend.
///
/// This is the default backend. FTS5 triggers handle indexing automatically,
/// so [indexAfterWrite] is a no-op.
class Fts5SearchBackend implements SearchBackend {
  final FullTextIndex _index;

  /// Creates an FTS5 backend that delegates lookups to [index].
  new({required FullTextIndex index}) : _index = index;

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
    final raw = await _index.search(query, limit: limit, userId: userId);
    return MemorySearchOutcome(results: raw.map(MemoryIndexProjection.toSearchResult).toList(growable: false));
  }

  @override
  Future<MemorySearchResult?> resolve(String locator, {String userId = 'owner'}) async => null;

  @override
  Future<void> indexAfterWrite() async {
    // No-op — FTS5 triggers handle indexing automatically
  }
}
