import 'package:dartclaw_core/dartclaw_core.dart'
    show MemorySearchResult, SearchBackend;

import '../storage/memory_service.dart';

/// FTS5-based search backend — wraps the existing [MemoryService].
///
/// This is the default backend. FTS5 triggers handle indexing automatically,
/// so [indexAfterWrite] is a no-op.
class Fts5SearchBackend implements SearchBackend {
  final MemoryService _memoryService;

  Fts5SearchBackend({required MemoryService memoryService})
      : _memoryService = memoryService;

  @override
  Future<List<MemorySearchResult>> search(
    String query, {
    int limit = 10,
    String userId = 'owner',
  }) async {
    return _memoryService.search(query, limit: limit, userId: userId);
  }

  @override
  Future<void> indexAfterWrite() async {
    // No-op — FTS5 triggers handle indexing automatically
  }
}
