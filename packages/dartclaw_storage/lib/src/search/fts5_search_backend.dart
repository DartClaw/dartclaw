import 'package:dartclaw_core/dartclaw_core.dart'
    show MemorySearchOutcome, MemorySearchResult, SearchBackend, SearchResultLayer;

import '../storage/memory_service.dart';

/// FTS5-based search backend — wraps the existing [MemoryService].
///
/// This is the default backend. FTS5 triggers handle indexing automatically,
/// so [indexAfterWrite] is a no-op.
class Fts5SearchBackend implements SearchBackend {
  final MemoryService _memoryService;

  /// Creates an FTS5 backend that delegates lookups to [memoryService].
  Fts5SearchBackend({required MemoryService memoryService}) : _memoryService = memoryService;

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
    final encoded = MemoryService.encodeNaturalLanguageQuery(query);
    if (encoded == null) return const MemorySearchOutcome(results: []);
    final raw = _memoryService.search(encoded, limit: limit, userId: userId);
    return MemorySearchOutcome(results: raw);
  }

  @override
  Future<MemorySearchResult?> resolve(String locator, {String userId = 'owner'}) async => null;

  @override
  Future<void> indexAfterWrite() async {
    // No-op — FTS5 triggers handle indexing automatically
  }
}
