import 'package:dartclaw_search/dartclaw_search.dart';

final class FakeFullTextIndex implements FullTextIndex {
  new({Iterable<SearchDocument> documents = const [], Iterable<SearchResult> searchResults = const []})
    : documents = {for (final document in documents) document.id: document},
      searchResults = List.of(searchResults);

  Map<String, SearchDocument> documents;
  List<SearchResult> searchResults;
  int searchCalls = 0;
  int fetchCalls = 0;
  int listCalls = 0;
  int countCalls = 0;
  int? lastSearchLimit;
  final owners = <String, List<String>>{};
  bool failSearch = false;
  bool failFetch = false;
  bool failCount = false;

  @override
  Future<List<SearchResult>> search(String naturalLanguageQuery, {required String userId, int limit = 20}) async {
    (owners['search'] ??= []).add(userId);
    searchCalls++;
    lastSearchLimit = limit;
    if (failSearch) throw StateError('lexical failed');
    return searchResults.take(limit).toList(growable: false);
  }

  @override
  Future<List<SearchResult>> listRecent({required String userId, int limit = 20}) async {
    (owners['list'] ??= []).add(userId);
    listCalls++;
    return [
      for (final document in documents.values)
        for (var index = 0; index < document.chunks.length; index++)
          SearchResult(
            id: document.id,
            chunk: document.chunks[index],
            chunkIndex: index,
            metadata: document.metadata,
            timestamp: document.timestamp,
            score: 0,
          ),
    ].take(limit).toList(growable: false);
  }

  @override
  Future<List<SearchDocument>> fetch(Iterable<String> ids, {required String userId}) async {
    (owners['fetch'] ??= []).add(userId);
    fetchCalls++;
    if (failFetch) throw StateError('fetch failed');
    return [for (final id in ids) ?documents[id]];
  }

  @override
  Future<int> count({required String userId, Map<String, String> metadata = const {}}) async {
    (owners['count'] ??= []).add(userId);
    countCalls++;
    if (failCount) throw StateError('count failed');
    return documents.values.fold<int>(0, (total, document) => total + document.chunks.length);
  }

  @override
  Future<void> upsert(Iterable<SearchDocument> next, {required String userId, Set<String> retire = const {}}) async {
    for (final id in retire) {
      documents.remove(id);
    }
    for (final document in next) {
      documents[document.id] = document;
    }
  }

  @override
  Future<void> delete(Iterable<String> ids, {required String userId}) async {
    for (final id in ids) {
      documents.remove(id);
    }
  }

  @override
  Future<void> replaceAll(Iterable<SearchDocument> next, {required String userId}) async {
    documents = {for (final document in next) document.id: document};
  }

  @override
  Future<void> verifyIntegrity() async {}
}

final class VectorMutation {
  new({required Iterable<VectorRecord> records, required Set<VectorIdentity> retire})
    : records = List.unmodifiable(records),
      retire = Set.unmodifiable(retire);

  final List<VectorRecord> records;
  final Set<VectorIdentity> retire;
}

final class FakeVectorIndex implements VectorIndex {
  new({Iterable<VectorRecord> records = const [], Iterable<VectorMatch> matches = const []})
    : records = List.of(records),
      matches = List.of(matches);

  List<VectorRecord> records;
  List<VectorMatch> matches;
  final searchFingerprints = <String>[];
  final List<VectorMutation> upserts = [];
  final List<List<VectorRecord>> replacements = [];
  int searchCalls = 0;
  int listCalls = 0;
  int? lastSearchLimit;
  final owners = <String, List<String>>{};
  bool failSearch = false;
  bool failList = false;

  @override
  Future<List<VectorMatch>> search(
    List<double> queryVector, {
    required String userId,
    required String modelFingerprint,
    int limit = 20,
  }) async {
    (owners['search'] ??= []).add(userId);
    searchCalls++;
    lastSearchLimit = limit;
    searchFingerprints.add(modelFingerprint);
    if (failSearch) throw StateError('vector search failed');
    return matches.take(limit).toList(growable: false);
  }

  @override
  Future<List<VectorRecord>> list({required String userId}) async {
    (owners['list'] ??= []).add(userId);
    listCalls++;
    if (failList) throw StateError('vector list failed');
    return List.of(records);
  }

  @override
  Future<void> upsert(
    Iterable<VectorRecord> next, {
    required String userId,
    Set<VectorIdentity> retire = const {},
  }) async {
    (owners['upsert'] ??= []).add(userId);
    final mutation = VectorMutation(records: next, retire: retire);
    upserts.add(mutation);
    final retired = mutation.retire;
    records.removeWhere((record) => retired.contains(_identity(record)));
    for (final record in mutation.records) {
      records.removeWhere((existing) => _identity(existing) == _identity(record));
      records.add(record);
    }
  }

  @override
  Future<void> delete(Iterable<VectorIdentity> identities, {required String userId}) async {
    final removed = identities.toSet();
    records.removeWhere((record) => removed.contains(_identity(record)));
  }

  @override
  Future<void> replaceAll(Iterable<VectorRecord> next, {required String userId}) async {
    (owners['replaceAll'] ??= []).add(userId);
    records = List.of(next);
    replacements.add(List.unmodifiable(records));
  }

  static VectorIdentity _identity(VectorRecord record) =>
      VectorIdentity(documentId: record.documentId, chunkIndex: record.chunkIndex);
}

final class FakeEmbeddingProvider implements EmbeddingProvider {
  new({this.modelFingerprint = 'model-v1', this.queryVector = const [1], this.documentVectors, this.beforeQueryResult});

  @override
  final String modelFingerprint;

  List<double> queryVector;
  List<List<double>>? documentVectors;
  final List<String> embeddedDocuments = [];
  int queryCalls = 0;
  int documentCalls = 0;
  bool failQuery = false;
  bool failDocuments = false;
  Future<void> Function()? beforeQueryResult;
  void Function()? afterDocumentEmbedding;

  @override
  Future<List<double>> embedQuery(String query) async {
    queryCalls++;
    await beforeQueryResult?.call();
    if (failQuery) throw StateError('query embedding failed');
    return queryVector;
  }

  @override
  Future<List<List<double>>> embedDocuments(List<String> documents) async {
    documentCalls++;
    embeddedDocuments.addAll(documents);
    if (failDocuments) throw StateError('document embedding failed');
    final output =
        documentVectors ??
        [
          for (var index = 0; index < documents.length; index++) [index + 1.0],
        ];
    afterDocumentEmbedding?.call();
    return output;
  }

  @override
  Future<void> dispose() async {}
}

SearchDocument document(String id, List<String> chunks, {Map<String, String> metadata = const {}}) =>
    SearchDocument(id: id, chunks: chunks, metadata: metadata, timestamp: DateTime.utc(2026, 1, 2));

SearchResult lexicalResult(
  String id,
  String chunk,
  int chunkIndex,
  double score, {
  Map<String, String> metadata = const {},
}) => SearchResult(
  id: id,
  chunk: chunk,
  chunkIndex: chunkIndex,
  metadata: metadata,
  timestamp: DateTime.utc(2026, 1, 2),
  score: score,
);

VectorRecord record(String id, int chunkIndex, String hash, {String fingerprint = 'model-v1', double value = 1}) =>
    VectorRecord(
      documentId: id,
      chunkIndex: chunkIndex,
      contentHash: hash,
      modelFingerprint: fingerprint,
      vector: [value],
    );
