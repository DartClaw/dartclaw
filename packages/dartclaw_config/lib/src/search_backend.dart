import 'package:dartclaw_models/dartclaw_models.dart';

/// Abstract interface for memory search backends.
///
/// Implementations: [Fts5SearchBackend] (built-in default), [QmdSearchBackend]
/// (opt-in via config).
abstract class SearchBackend {
  /// Searches memory chunks matching [query].
  ///
  /// [limit] caps the number of returned matches. [userId] scopes the search
  /// to a logical owner or tenant when the backend supports multi-user data.
  Future<List<MemorySearchResult>> search(String query, {int limit = 10, String userId = 'owner'});

  /// Trigger incremental indexing after a memory write.
  /// FTS5: no-op (triggers handle it). QMD: runs `qmd update && qmd embed`.
  Future<void> indexAfterWrite();
}
