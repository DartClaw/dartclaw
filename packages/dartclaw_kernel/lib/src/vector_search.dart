import 'models.dart';

/// Stable identity of one document chunk in an owner-scoped vector index.
final class VectorIdentity {
  /// Creates a validated vector identity.
  new({required this.documentId, required this.chunkIndex}) {
    _requireNonEmpty(documentId, 'documentId');
    _requireNonNegative(chunkIndex, 'chunkIndex');
  }

  /// Stable document identity within one owner scope.
  final String documentId;

  /// Zero-based chunk position within the document.
  final int chunkIndex;

  @override
  bool operator ==(Object other) =>
      other is VectorIdentity && other.documentId == documentId && other.chunkIndex == chunkIndex;

  @override
  int get hashCode => Object.hash(documentId, chunkIndex);
}

/// One embedded document chunk stored in a [VectorIndex].
final class VectorRecord {
  /// Creates a validated immutable vector record.
  new({
    required this.documentId,
    required this.chunkIndex,
    required this.contentHash,
    required this.modelFingerprint,
    required List<double> vector,
  }) : vector = List.unmodifiable(vector) {
    _requireNonEmpty(documentId, 'documentId');
    _requireNonNegative(chunkIndex, 'chunkIndex');
    _requireNonEmpty(contentHash, 'contentHash');
    _requireNonEmpty(modelFingerprint, 'modelFingerprint');
    _requireVector(this.vector, 'vector');
  }

  /// Stable document identity within one owner scope.
  final String documentId;

  /// Zero-based chunk position within the document.
  final int chunkIndex;

  /// Hash of the exact source chunk represented by [vector].
  final String contentHash;

  /// Provider-defined model identity used to produce [vector].
  final String modelFingerprint;

  /// Finite, non-empty embedding values.
  final List<double> vector;

  @override
  bool operator ==(Object other) =>
      other is VectorRecord &&
      other.documentId == documentId &&
      other.chunkIndex == chunkIndex &&
      other.contentHash == contentHash &&
      other.modelFingerprint == modelFingerprint &&
      _sameVector(other.vector, vector);

  @override
  int get hashCode => Object.hash(documentId, chunkIndex, contentHash, modelFingerprint, Object.hashAll(vector));
}

/// One backend-ranked chunk returned by a [VectorIndex].
final class VectorMatch {
  /// Creates a validated vector match.
  new({required this.documentId, required this.chunkIndex, required this.contentHash, required this.score}) {
    _requireNonEmpty(documentId, 'documentId');
    _requireNonNegative(chunkIndex, 'chunkIndex');
    _requireNonEmpty(contentHash, 'contentHash');
    _requireFinite(score, 'score');
  }

  /// Stable document identity within one owner scope.
  final String documentId;

  /// Zero-based chunk position within the document.
  final int chunkIndex;

  /// Hash of the exact source chunk represented by this match.
  final String contentHash;

  /// Finite backend-native relevance score.
  final double score;

  @override
  bool operator ==(Object other) =>
      other is VectorMatch &&
      other.documentId == documentId &&
      other.chunkIndex == chunkIndex &&
      other.contentHash == contentHash &&
      other.score == score;

  @override
  int get hashCode => Object.hash(documentId, chunkIndex, contentHash, score);
}

/// Owner-scoped vector projection used beside a canonical lexical corpus.
abstract interface class VectorIndex {
  /// Searches records for the exact model fingerprint.
  ///
  /// Implementations reject an empty or non-finite [queryVector], an empty
  /// [modelFingerprint], or a non-positive [limit]. Stored candidates with a
  /// different vector dimension are excluded from ranking.
  Future<List<VectorMatch>> search(
    List<double> queryVector, {
    required String userId,
    required String modelFingerprint,
    int limit = 20,
  });

  /// Lists all records by document identity and then chunk position.
  Future<List<VectorRecord>> list({required String userId});

  /// Atomically stores records and retires exact identities for one owner.
  ///
  /// The last record wins when [records] repeats an identity.
  Future<void> upsert(Iterable<VectorRecord> records, {required String userId, Set<VectorIdentity> retire = const {}});

  /// Deletes exact chunk identities for one owner.
  Future<void> delete(Iterable<VectorIdentity> identities, {required String userId});

  /// Atomically replaces one owner's complete vector corpus.
  Future<void> replaceAll(Iterable<VectorRecord> records, {required String userId});
}

/// Produces query and ordered batch embeddings under one model identity.
abstract interface class EmbeddingProvider {
  /// Provider-defined identity shared by every returned embedding dimension.
  String get modelFingerprint;

  /// Embeds one query as a finite, non-empty vector.
  Future<List<double>> embedQuery(String query);

  /// Embeds documents while preserving input count and order.
  ///
  /// An empty input returns an empty list. Every returned vector is finite,
  /// non-empty and has the dimension identified by [modelFingerprint].
  Future<List<List<double>>> embedDocuments(List<String> documents);

  /// Releases provider-owned resources.
  Future<void> dispose();
}

/// Content-free constituent rank and score evidence for one fused candidate.
final class SearchRankEvidence {
  /// Creates validated rank evidence.
  new({
    required this.documentId,
    required this.chunkIndex,
    required this.keywordRank,
    required this.vectorRank,
    required this.keywordContribution,
    required this.vectorContribution,
    required this.fusedScore,
    required this.sourceLayer,
  }) {
    _requireNonEmpty(documentId, 'documentId');
    _requireNonNegative(chunkIndex, 'chunkIndex');
    _requireRank(keywordRank, 'keywordRank');
    _requireRank(vectorRank, 'vectorRank');
    if (keywordRank == null && vectorRank == null) {
      throw ArgumentError('keywordRank or vectorRank must be present');
    }
    _requireNonNegativeFinite(keywordContribution, 'keywordContribution');
    _requireNonNegativeFinite(vectorContribution, 'vectorContribution');
    _requireNonNegativeFinite(fusedScore, 'fusedScore');
    if (keywordRank == null && keywordContribution != 0) {
      throw ArgumentError.value(keywordContribution, 'keywordContribution', 'must be zero without keywordRank');
    }
    if (vectorRank == null && vectorContribution != 0) {
      throw ArgumentError.value(vectorContribution, 'vectorContribution', 'must be zero without vectorRank');
    }
    if (fusedScore != keywordContribution + vectorContribution) {
      throw ArgumentError.value(fusedScore, 'fusedScore', 'must equal both contributions');
    }
    _requireNonEmpty(sourceLayer, 'sourceLayer');
  }

  /// Stable document identity within the owning corpus.
  final String documentId;

  /// Zero-based chunk position within the document.
  final int chunkIndex;

  /// One-based keyword rank, or `null` when absent.
  final int? keywordRank;

  /// One-based vector rank, or `null` when absent.
  final int? vectorRank;

  /// Weighted keyword contribution, zero when [keywordRank] is absent.
  final double keywordContribution;

  /// Weighted vector contribution, zero when [vectorRank] is absent.
  final double vectorContribution;

  /// Sum of [keywordContribution] and [vectorContribution].
  final double fusedScore;

  /// Owning corpus layer such as `memory` or `conversation`.
  final String sourceLayer;
}

/// Optional content-free evidence from one hybrid search.
final class SearchDiagnostics {
  /// Creates immutable search diagnostics.
  new({
    required Iterable<SearchRankEvidence> candidates,
    this.unembeddedCount = 0,
    Iterable<MemorySearchDegradation> degradations = const [],
  }) : candidates = List.unmodifiable(candidates),
       degradations = List.unmodifiable(degradations) {
    _requireNonNegative(unembeddedCount, 'unembeddedCount');
  }

  /// Ranked candidate evidence in result order.
  final List<SearchRankEvidence> candidates;

  /// Number of current lexical chunks without usable embeddings.
  final int unembeddedCount;

  /// Structured failure causes retained from the retrieval layers.
  final List<MemorySearchDegradation> degradations;
}

/// Receives diagnostics when a caller explicitly opts in.
typedef SearchDiagnosticsSink = void Function(SearchDiagnostics diagnostics);

void _requireNonEmpty(String value, String name) {
  if (value.isEmpty) throw ArgumentError.value(value, name, 'must not be empty');
}

void _requireNonNegative(int value, String name) {
  if (value < 0) throw ArgumentError.value(value, name, 'must not be negative');
}

void _requireFinite(double value, String name) {
  if (!value.isFinite) throw ArgumentError.value(value, name, 'must be finite');
}

void _requireNonNegativeFinite(double value, String name) {
  _requireFinite(value, name);
  if (value < 0) throw ArgumentError.value(value, name, 'must not be negative');
}

void _requireVector(List<double> vector, String name) {
  if (vector.isEmpty) throw ArgumentError.value(vector, name, 'must not be empty');
  for (final value in vector) {
    _requireFinite(value, name);
  }
}

void _requireRank(int? rank, String name) {
  if (rank != null && rank < 1) throw ArgumentError.value(rank, name, 'must be positive');
}

bool _sameVector(List<double> left, List<double> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
