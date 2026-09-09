part of 'hybrid_search.dart';

final class _CurrentCorpusInventory {
  const new({required FullTextIndex lexicalIndex, required VectorIndex vectorIndex})
    : _lexicalIndex = lexicalIndex,
      _vectorIndex = vectorIndex;

  final FullTextIndex _lexicalIndex;
  final VectorIndex _vectorIndex;

  Future<_CorpusSnapshot> selected(Iterable<String> documentIds, {required String userId}) async {
    final ids = documentIds.toSet().toList(growable: false);
    if (ids.isEmpty) return const _CorpusSnapshot(chunks: [], isComplete: true, expectedCount: 0);
    final documents = await _lexicalIndex.fetch(ids, userId: userId);
    final byId = {for (final document in documents) document.id: document};
    return _CorpusSnapshot(
      chunks: [
        for (final id in ids)
          if (byId[id] case final document?) ..._chunks(document),
      ],
      isComplete: true,
      expectedCount: documents.fold(0, (total, document) => total + document.chunks.length),
    );
  }

  Future<_CorpusSnapshot> complete({required String userId}) async {
    final expectedCount = await _lexicalIndex.count(userId: userId);
    if (expectedCount == 0) {
      return const _CorpusSnapshot(chunks: [], isComplete: true, expectedCount: 0);
    }
    final recent = await _lexicalIndex.listRecent(userId: userId, limit: expectedCount);
    final ids = <String>[];
    final seenIds = <String>{};
    for (final result in recent) {
      if (seenIds.add(result.id)) ids.add(result.id);
    }
    final documents = await _lexicalIndex.fetch(ids, userId: userId);
    final chunks = documents.expand(_chunks).toList(growable: false)
      ..sort((left, right) {
        final byDocument = left.identity.documentId.compareTo(right.identity.documentId);
        return byDocument != 0 ? byDocument : left.identity.chunkIndex.compareTo(right.identity.chunkIndex);
      });
    final currentByIdentity = {for (final chunk in chunks) chunk.identity: chunk};
    final recentIsCurrent = recent.every((result) {
      final chunk = currentByIdentity[VectorIdentity(documentId: result.id, chunkIndex: result.chunkIndex)];
      return chunk != null && chunk.contentHash == hashChunk(result.chunk);
    });
    return _CorpusSnapshot(
      chunks: chunks,
      isComplete: recent.length == expectedCount && chunks.length == expectedCount && recentIsCurrent,
      expectedCount: expectedCount,
    );
  }

  Future<List<VectorRecord>> records({required String userId}) => _vectorIndex.list(userId: userId);

  Future<int> missingCount({required String userId, required String modelFingerprint}) async {
    final snapshot = await complete(userId: userId);
    if (!snapshot.isComplete) return snapshot.expectedCount;
    List<VectorRecord> records;
    try {
      records = await _vectorIndex.list(userId: userId);
    } on Object {
      return snapshot.chunks.length;
    }
    final eligible = {
      for (final record in records)
        if (record.modelFingerprint == modelFingerprint)
          VectorIdentity(documentId: record.documentId, chunkIndex: record.chunkIndex): record,
    };
    return snapshot.chunks.where((chunk) => !chunk.matches(eligible[chunk.identity], modelFingerprint)).length;
  }

  Future<int> diagnosticMissingCount({required String userId, required String modelFingerprint}) async {
    try {
      return await missingCount(userId: userId, modelFingerprint: modelFingerprint);
    } on Object {
      try {
        return await _lexicalIndex.count(userId: userId);
      } on Object {
        return 0;
      }
    }
  }

  static String hashChunk(String chunk) => sha256.convert(utf8.encode(chunk)).toString();

  static Iterable<_CorpusChunk> _chunks(SearchDocument document) sync* {
    for (var chunkIndex = 0; chunkIndex < document.chunks.length; chunkIndex++) {
      yield _CorpusChunk(document: document, chunkIndex: chunkIndex);
    }
  }
}

final class _CorpusSnapshot {
  const new({required this.chunks, required this.isComplete, required this.expectedCount});

  final List<_CorpusChunk> chunks;
  final bool isComplete;
  final int expectedCount;

  bool sameContent(_CorpusSnapshot other) {
    if (!isComplete || !other.isComplete || chunks.length != other.chunks.length) return false;
    for (var index = 0; index < chunks.length; index++) {
      final left = chunks[index];
      final right = other.chunks[index];
      if (left.identity != right.identity || left.contentHash != right.contentHash) return false;
    }
    return true;
  }
}

final class _CorpusChunk {
  new({required this.document, required this.chunkIndex})
    : identity = VectorIdentity(documentId: document.id, chunkIndex: chunkIndex),
      contentHash = _CurrentCorpusInventory.hashChunk(document.chunks[chunkIndex]);

  final SearchDocument document;
  final int chunkIndex;
  final VectorIdentity identity;
  final String contentHash;

  String get text => document.chunks[chunkIndex];

  bool matches(VectorRecord? record, String modelFingerprint) =>
      record != null && record.contentHash == contentHash && record.modelFingerprint == modelFingerprint;

  SearchResult result(double score) => SearchResult(
    id: document.id,
    chunk: text,
    chunkIndex: chunkIndex,
    metadata: document.metadata,
    timestamp: document.timestamp,
    score: score,
  );
}
