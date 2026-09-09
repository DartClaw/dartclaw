/// One immutable document stored in a [FullTextIndex].
final class SearchDocument {
  /// Stable document identity within one user scope.
  final String id;

  /// Ordered text chunks stored and searched independently.
  final List<String> chunks;

  /// Opaque flat metadata persisted and returned verbatim.
  final Map<String, String> metadata;

  /// Source timestamp used for recency ordering.
  final DateTime timestamp;

  /// Creates a validated search document.
  new({
    required this.id,
    required Iterable<String> chunks,
    Map<String, String> metadata = const {},
    required this.timestamp,
  }) : chunks = List.unmodifiable(chunks),
       metadata = Map.unmodifiable(metadata) {
    if (id.isEmpty) throw ArgumentError.value(id, 'id', 'must not be empty');
    if (this.chunks.isEmpty) throw ArgumentError.value(chunks, 'chunks', 'must not be empty');
  }
}

/// One matching chunk returned by a [FullTextIndex].
final class SearchResult {
  /// Stable identity of the matched document.
  final String id;

  /// Matching document chunk.
  final String chunk;

  /// Zero-based position of [chunk] within its document.
  final int chunkIndex;

  /// Opaque document metadata.
  final Map<String, String> metadata;

  /// Source timestamp of the matched document.
  final DateTime timestamp;

  /// Backend-native relevance score.
  final double score;

  /// Creates an immutable search result.
  new({
    required this.id,
    required this.chunk,
    required this.chunkIndex,
    Map<String, String> metadata = const {},
    required this.timestamp,
    required this.score,
  }) : metadata = Map.unmodifiable(metadata) {
    if (id.isEmpty) throw ArgumentError.value(id, 'id', 'must not be empty');
    if (chunkIndex < 0) throw ArgumentError.value(chunkIndex, 'chunkIndex', 'must not be negative');
  }
}

/// Corpus-agnostic full-text document index.
///
/// `(userId, document.id)` identifies one document. Mutations are atomic per
/// call, and each operation is isolated to its required user scope.
abstract interface class FullTextIndex {
  /// Searches matching chunks in best-first backend-native score order.
  Future<List<SearchResult>> search(String naturalLanguageQuery, {required String userId, int limit = 20});

  /// Lists chunks by newest source timestamp, then newest stored row.
  Future<List<SearchResult>> listRecent({required String userId, int limit = 20});

  /// Fetches existing documents by identity with chunks in stored order.
  Future<List<SearchDocument>> fetch(Iterable<String> ids, {required String userId});

  /// Counts stored chunks whose document metadata matches every supplied pair.
  Future<int> count({required String userId, Map<String, String> metadata = const {}});

  /// Replaces supplied documents and retires selected identities atomically.
  ///
  /// The last occurrence wins when [documents] repeats an identity.
  /// Implementations backed by a fixed table may reject unsupported, missing,
  /// or non-canonical metadata values with [ArgumentError].
  Future<void> upsert(Iterable<SearchDocument> documents, {required String userId, Set<String> retire = const {}});

  /// Deletes selected document identities for one user.
  Future<void> delete(Iterable<String> ids, {required String userId});

  /// Atomically replaces one user's complete corpus.
  ///
  /// Implementations backed by a fixed table may reject unsupported, missing,
  /// or non-canonical metadata values with [ArgumentError].
  Future<void> replaceAll(Iterable<SearchDocument> documents, {required String userId});

  /// Throws when the backend's internal consistency check fails.
  Future<void> verifyIntegrity();
}
