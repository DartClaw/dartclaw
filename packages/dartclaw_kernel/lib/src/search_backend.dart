import 'models.dart';

/// User-facing retrieval layer used to constrain ranking before output top-K.
enum SearchResultLayer {
  /// Personal canonical and unmatched native memory results.
  memory,

  /// Native wiki results.
  wiki,
}

/// Abstract interface for memory search backends.
abstract class SearchBackend {
  /// Searches memory chunks matching [query].
  ///
  /// [limit] caps the number of returned matches. [userId] scopes the search
  /// to a logical owner or tenant when the backend supports multi-user data.
  /// [layers] constrains constituent retrieval and ranking before that cap.
  Future<MemorySearchOutcome> search(
    String query, {
    int limit = 10,
    String userId = 'owner',
    Set<SearchResultLayer>? layers,
  });

  /// Resolves a native locator previously returned by [search].
  Future<MemorySearchResult?> resolve(String locator, {String userId = 'owner'});

  /// Triggers any incremental work needed after a memory write.
  Future<void> indexAfterWrite();
}
