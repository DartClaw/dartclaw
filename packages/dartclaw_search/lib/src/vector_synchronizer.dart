part of 'hybrid_search.dart';

/// Counts one authenticated vector reconciliation.
final class VectorSynchronizationResult {
  /// Creates an immutable synchronization result.
  new({
    required this.embeddedCount,
    required this.reusedCount,
    required this.retiredCount,
    required this.unembeddedCount,
    Iterable<MemorySearchDegradation> degradations = const [],
  }) : degradations = List.unmodifiable(degradations) {
    for (final (name, value) in <(String, int)>[
      ('embeddedCount', embeddedCount),
      ('reusedCount', reusedCount),
      ('retiredCount', retiredCount),
      ('unembeddedCount', unembeddedCount),
    ]) {
      if (value < 0) throw ArgumentError.value(value, name, 'must not be negative');
    }
  }

  /// Newly embedded current chunks.
  final int embeddedCount;

  /// Current chunks retaining an exact vector.
  final int reusedCount;

  /// Obsolete vector records removed by the atomic mutation.
  final int retiredCount;

  /// Current chunks without an exact vector after the operation.
  final int unembeddedCount;

  /// Structured failures that left source data intact.
  final List<MemorySearchDegradation> degradations;
}

/// Reconciles a derived vector projection with its current lexical source.
final class VectorSynchronizer {
  /// Creates a synchronizer for one `memory` or `conversation` corpus.
  new({
    required FullTextIndex lexicalIndex,
    required VectorIndex vectorIndex,
    required EmbeddingProvider embeddingProvider,
    required String sourceLayer,
  }) : _vectorIndex = vectorIndex,
       _embeddingProvider = embeddingProvider,
       _sourceLayer = _validateSourceLayer(sourceLayer),
       _inventory = _CurrentCorpusInventory(lexicalIndex: lexicalIndex, vectorIndex: vectorIndex);

  final VectorIndex _vectorIndex;
  final EmbeddingProvider _embeddingProvider;
  final String _sourceLayer;
  final _CurrentCorpusInventory _inventory;

  /// Reconciles the current source state for the supplied document identities.
  Future<VectorSynchronizationResult> synchronize(Iterable<String> documentIds, {required String userId}) async {
    _validateUserId(userId);
    final ids = documentIds.toSet().toList(growable: false);
    if (ids.any((id) => id.isEmpty)) {
      throw ArgumentError.value(documentIds, 'documentIds', 'must not contain empty IDs');
    }
    final before = await _inventory.selected(ids, userId: userId);
    final existing = await _inventory.records(userId: userId);
    final currentByIdentity = {for (final chunk in before.chunks) chunk.identity: chunk};
    final reusable = <VectorIdentity, VectorRecord>{};
    final retire = <VectorIdentity>{};
    for (final record in existing.where((record) => ids.contains(record.documentId))) {
      final identity = VectorIdentity(documentId: record.documentId, chunkIndex: record.chunkIndex);
      final current = currentByIdentity[identity];
      if (current != null && current.matches(record, _embeddingProvider.modelFingerprint)) {
        reusable[identity] = record;
      } else {
        retire.add(identity);
      }
    }
    final missing = before.chunks.where((chunk) => !reusable.containsKey(chunk.identity)).toList(growable: false);

    List<List<double>> vectors;
    MemorySearchDegradation? embeddingFailure;
    try {
      vectors = missing.isEmpty
          ? const []
          : await _embeddingProvider.embedDocuments([for (final chunk in missing) chunk.text]);
      if (!_validVectors(vectors, missing.length)) throw const FormatException('invalid document vectors');
    } on Object {
      vectors = const [];
      embeddingFailure = MemorySearchDegradation(layer: _sourceLayer, reason: 'embeddingFailure');
    }

    final after = await _inventory.selected(ids, userId: userId);
    if (!before.sameContent(after)) {
      return _result(
        embeddedCount: 0,
        reusedCount: 0,
        retiredCount: 0,
        userId: userId,
        degradations: [
          ?embeddingFailure,
          MemorySearchDegradation(layer: _sourceLayer, reason: 'sourceChanged'),
        ],
      );
    }

    if (embeddingFailure != null) {
      await _vectorIndex.upsert(const [], userId: userId, retire: retire);
      return _result(
        embeddedCount: 0,
        reusedCount: reusable.length,
        retiredCount: retire.length,
        userId: userId,
        degradations: [embeddingFailure],
      );
    }

    final records = <VectorRecord>[
      for (var index = 0; index < missing.length; index++)
        VectorRecord(
          documentId: missing[index].identity.documentId,
          chunkIndex: missing[index].identity.chunkIndex,
          contentHash: missing[index].contentHash,
          modelFingerprint: _embeddingProvider.modelFingerprint,
          vector: vectors[index],
        ),
    ];
    if (records.isNotEmpty || retire.isNotEmpty) {
      await _vectorIndex.upsert(records, userId: userId, retire: retire);
    }
    return _result(
      embeddedCount: records.length,
      reusedCount: reusable.length,
      retiredCount: retire.length,
      userId: userId,
    );
  }

  /// Reconciles and atomically replaces the complete owner-scoped vector corpus.
  Future<VectorSynchronizationResult> rebuild({required String userId}) async {
    _validateUserId(userId);
    final before = await _inventory.complete(userId: userId);
    final existing = await _inventory.records(userId: userId);
    if (!before.isComplete) return _sourceChanged(userId);
    final existingByIdentity = {
      for (final record in existing)
        VectorIdentity(documentId: record.documentId, chunkIndex: record.chunkIndex): record,
    };
    final reusable = <VectorIdentity, VectorRecord>{};
    final missing = <_CorpusChunk>[];
    for (final chunk in before.chunks) {
      final record = existingByIdentity[chunk.identity];
      if (chunk.matches(record, _embeddingProvider.modelFingerprint)) {
        reusable[chunk.identity] = record!;
      } else {
        missing.add(chunk);
      }
    }

    List<List<double>> vectors;
    try {
      vectors = missing.isEmpty
          ? const []
          : await _embeddingProvider.embedDocuments([for (final chunk in missing) chunk.text]);
      if (!_validVectors(vectors, missing.length)) throw const FormatException('invalid document vectors');
    } on Object {
      return _result(
        embeddedCount: 0,
        reusedCount: reusable.length,
        retiredCount: 0,
        userId: userId,
        degradations: [MemorySearchDegradation(layer: _sourceLayer, reason: 'embeddingFailure')],
      );
    }

    final after = await _inventory.complete(userId: userId);
    if (!before.sameContent(after)) return _sourceChanged(userId);
    final embedded = <VectorIdentity, VectorRecord>{
      for (var index = 0; index < missing.length; index++)
        missing[index].identity: VectorRecord(
          documentId: missing[index].identity.documentId,
          chunkIndex: missing[index].identity.chunkIndex,
          contentHash: missing[index].contentHash,
          modelFingerprint: _embeddingProvider.modelFingerprint,
          vector: vectors[index],
        ),
    };
    final replacement = [for (final chunk in after.chunks) reusable[chunk.identity] ?? embedded[chunk.identity]!];
    await _vectorIndex.replaceAll(replacement, userId: userId);
    return _result(
      embeddedCount: embedded.length,
      reusedCount: reusable.length,
      retiredCount: existing.length - reusable.length,
      userId: userId,
    );
  }

  /// Counts current chunks without an exact content and model match.
  Future<int> missingCount({required String userId}) {
    _validateUserId(userId);
    return _inventory.missingCount(userId: userId, modelFingerprint: _embeddingProvider.modelFingerprint);
  }

  Future<VectorSynchronizationResult> _sourceChanged(String userId) => _result(
    embeddedCount: 0,
    reusedCount: 0,
    retiredCount: 0,
    userId: userId,
    degradations: [MemorySearchDegradation(layer: _sourceLayer, reason: 'sourceChanged')],
  );

  Future<VectorSynchronizationResult> _result({
    required int embeddedCount,
    required int reusedCount,
    required int retiredCount,
    required String userId,
    Iterable<MemorySearchDegradation> degradations = const [],
  }) async => VectorSynchronizationResult(
    embeddedCount: embeddedCount,
    reusedCount: reusedCount,
    retiredCount: retiredCount,
    unembeddedCount: await missingCount(userId: userId),
    degradations: degradations,
  );
}

bool _validVectors(List<List<double>> vectors, int expectedCount) {
  if (vectors.length != expectedCount) return false;
  int? dimension;
  for (final vector in vectors) {
    if (vector.isEmpty || vector.any((value) => !value.isFinite)) return false;
    dimension ??= vector.length;
    if (vector.length != dimension) return false;
  }
  return true;
}
