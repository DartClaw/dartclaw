import '../models/models.dart';

/// Abstract interface for memory search backends.
///
/// Implementations: [Fts5SearchBackend] (built-in default), [QmdSearchBackend]
/// (opt-in via config).
abstract class SearchBackend {
  /// Search memory chunks matching [query].
  Future<List<MemorySearchResult>> search(
    String query, {
    int limit = 10,
    String userId = 'owner',
  });

  /// Trigger incremental indexing after a memory write.
  /// FTS5: no-op (triggers handle it). QMD: runs `qmd update && qmd embed`.
  Future<void> indexAfterWrite();
}
