import 'package:dartclaw_core/dartclaw_core.dart' show MemorySearchResult, SearchBackend;

import '../storage/memory_service.dart';
import 'wiki_search_source.dart';

/// FTS5-based search backend — wraps the existing [MemoryService].
///
/// This is the default backend. FTS5 triggers handle indexing automatically,
/// so [indexAfterWrite] is a no-op.
class Fts5SearchBackend implements SearchBackend {
  final MemoryService _memoryService;
  final WikiSearchSource? _wikiSearch;

  /// Creates an FTS5 backend that delegates lookups to [memoryService].
  Fts5SearchBackend({required MemoryService memoryService, WikiSearchSource? wikiSearch})
    : _memoryService = memoryService,
      _wikiSearch = wikiSearch;

  @override
  Future<List<MemorySearchResult>> search(String query, {int limit = 10, String userId = 'owner'}) async {
    final wiki = await _wikiSearch?.search(query, limit: limit) ?? const <MemorySearchResult>[];
    final raw = _memoryService.search(query, limit: limit, userId: userId);
    final combined = [...wiki, ...raw]..sort((a, b) => a.score.compareTo(b.score));
    return combined.take(limit).toList();
  }

  @override
  Future<void> indexAfterWrite() async {
    // No-op — FTS5 triggers handle indexing automatically
  }
}
