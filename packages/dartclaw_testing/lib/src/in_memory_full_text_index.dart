import 'package:dartclaw_kernel/dartclaw_kernel.dart';

/// Scoped in-memory full-text index for tests that do not exercise SQL.
final class InMemoryFullTextIndex implements ScopedFullTextIndex {
  new({this.beforeSearch});

  final Future<void> Function()? beforeSearch;
  final Map<String, Map<String, SearchDocument>> _documents = {};

  @override
  Future<List<SearchResult>> search(String naturalLanguageQuery, {required String userId, int limit = 20}) =>
      _search(naturalLanguageQuery, userId: userId, limit: limit);

  @override
  Future<List<SearchResult>> searchScoped(
    String naturalLanguageQuery, {
    required String userId,
    required FullTextSearchScope scope,
    int limit = 20,
  }) => _search(naturalLanguageQuery, userId: userId, scope: scope, limit: limit);

  Future<List<SearchResult>> _search(
    String naturalLanguageQuery, {
    required String userId,
    FullTextSearchScope? scope,
    required int limit,
  }) async {
    await beforeSearch?.call();
    final terms = naturalLanguageQuery
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .split(RegExp(r'\s+'))
        .where((term) => term.isNotEmpty && term != 'and' && term != 'or' && term != 'not')
        .toList();
    if (terms.isEmpty) return const [];
    final results = <SearchResult>[];
    for (final document in _documents[userId]?.values ?? const <SearchDocument>[]) {
      if (scope != null && !_allows(document.metadata, scope)) continue;
      for (var index = 0; index < document.chunks.length; index++) {
        final chunk = document.chunks[index];
        final matches = terms.where(chunk.toLowerCase().contains).length;
        if (terms.isNotEmpty && matches != terms.length) continue;
        results.add(
          SearchResult(
            id: document.id,
            chunk: chunk,
            chunkIndex: index,
            metadata: document.metadata,
            timestamp: document.timestamp,
            score: terms.isEmpty ? 0 : -(matches / terms.length),
          ),
        );
      }
    }
    results.sort((left, right) {
      final byScore = left.score.compareTo(right.score);
      if (byScore != 0) return byScore;
      final byId = left.id.compareTo(right.id);
      return byId != 0 ? byId : left.chunkIndex.compareTo(right.chunkIndex);
    });
    return results.take(limit).toList(growable: false);
  }

  @override
  Future<List<SearchResult>> listRecent({required String userId, int limit = 20}) async {
    final results = <SearchResult>[];
    for (final document in _documents[userId]?.values ?? const <SearchDocument>[]) {
      for (var index = 0; index < document.chunks.length; index++) {
        results.add(
          SearchResult(
            id: document.id,
            chunk: document.chunks[index],
            chunkIndex: index,
            metadata: document.metadata,
            timestamp: document.timestamp,
            score: 0,
          ),
        );
      }
    }
    results.sort((left, right) => right.timestamp.compareTo(left.timestamp));
    return results.take(limit).toList(growable: false);
  }

  @override
  Future<List<SearchDocument>> fetch(Iterable<String> ids, {required String userId}) async => [
    for (final id in ids) ?_documents[userId]?[id],
  ];

  @override
  Future<List<SearchDocument>> fetchScoped(
    Iterable<String> ids, {
    required String userId,
    required FullTextSearchScope scope,
  }) async => [
    for (final id in ids)
      if (_documents[userId]?[id] case final document? when _allows(document.metadata, scope)) document,
  ];

  @override
  Future<int> count({required String userId, Map<String, String> metadata = const {}}) async =>
      (_documents[userId]?.values ?? const <SearchDocument>[])
          .where((document) => metadata.entries.every((entry) => document.metadata[entry.key] == entry.value))
          .fold<int>(0, (total, document) => total + document.chunks.length);

  @override
  Future<int> countMatches(String naturalLanguageQuery, {required String userId, FullTextSearchScope? scope}) async =>
      (await _search(naturalLanguageQuery, userId: userId, scope: scope, limit: 1 << 30)).length;

  @override
  Future<void> upsert(
    Iterable<SearchDocument> documents, {
    required String userId,
    Set<String> retire = const {},
  }) async {
    final byId = _documents.putIfAbsent(userId, () => {});
    for (final id in retire) {
      byId.remove(id);
    }
    for (final document in documents) {
      byId[document.id] = document;
    }
  }

  @override
  Future<void> delete(Iterable<String> ids, {required String userId}) async {
    for (final id in ids) {
      _documents[userId]?.remove(id);
    }
  }

  @override
  Future<void> replaceAll(Iterable<SearchDocument> documents, {required String userId}) async {
    _documents[userId] = {for (final document in documents) document.id: document};
  }

  @override
  Future<void> verifyIntegrity() async {}

  static bool _allows(Map<String, String> metadata, FullTextSearchScope scope) {
    if (scope.acceptedValues.isEmpty) return true;
    final value = metadata[scope.metadataKey];
    return value != null && scope.acceptedValues.contains(value);
  }
}
