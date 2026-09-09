import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';

part 'current_corpus_inventory.dart';
part 'vector_synchronizer.dart';

const _rrfK = 60;
const _keywordWeight = 0.25;
const _vectorWeight = 0.75;
const _vectorCutoff = 0.20;
const _candidateLimit = 20;

/// Combines owner-scoped lexical and authenticated semantic candidates.
final class HybridSearch {
  /// Creates a search instance for one `memory` or `conversation` corpus.
  new({
    required FullTextIndex lexicalIndex,
    required VectorIndex vectorIndex,
    required EmbeddingProvider embeddingProvider,
    required String sourceLayer,
  }) : _lexicalIndex = lexicalIndex,
       _vectorIndex = vectorIndex,
       _embeddingProvider = embeddingProvider,
       _sourceLayer = _validateSourceLayer(sourceLayer),
       _inventory = _CurrentCorpusInventory(lexicalIndex: lexicalIndex, vectorIndex: vectorIndex);

  final FullTextIndex _lexicalIndex;
  final VectorIndex _vectorIndex;
  final EmbeddingProvider _embeddingProvider;
  final String _sourceLayer;
  final _CurrentCorpusInventory _inventory;

  /// Searches one owner while retaining lexical results when semantic retrieval is unavailable.
  Future<List<SearchResult>> search(
    String query, {
    required String userId,
    int limit = 20,
    SearchDiagnosticsSink? diagnostics,
  }) async {
    _validateUserId(userId);
    if (limit <= 0) throw ArgumentError.value(limit, 'limit', 'must be positive');
    if (query.trim().isEmpty) {
      diagnostics?.call(SearchDiagnostics(candidates: const []));
      return const [];
    }

    final lexical = _deduplicate(await _lexicalIndex.search(query, userId: userId, limit: _candidateLimit));
    List<double> queryVector;
    try {
      queryVector = await _embeddingProvider.embedQuery(query);
      if (!_validVector(queryVector)) throw const FormatException('invalid query vector');
    } on Object {
      await _reportFallback(lexical, userId, limit, diagnostics, reason: 'embeddingFailure');
      return List.unmodifiable(lexical.take(limit));
    }

    List<VectorMatch> matches;
    try {
      matches = await _vectorIndex.search(
        queryVector,
        userId: userId,
        modelFingerprint: _embeddingProvider.modelFingerprint,
        limit: _candidateLimit,
      );
    } on Object {
      await _reportFallback(lexical, userId, limit, diagnostics, reason: 'vectorSearchFailure');
      return List.unmodifiable(lexical.take(limit));
    }

    final eligibleMatches = <VectorMatch>[];
    final seenMatches = <VectorIdentity>{};
    for (final match in matches.take(_candidateLimit)) {
      final identity = VectorIdentity(documentId: match.documentId, chunkIndex: match.chunkIndex);
      if (match.score >= _vectorCutoff && seenMatches.add(identity)) eligibleMatches.add(match);
    }

    _CorpusSnapshot authenticated;
    try {
      authenticated = await _inventory.selected(eligibleMatches.map((match) => match.documentId), userId: userId);
    } on Object {
      await _reportFallback(lexical, userId, limit, diagnostics, reason: 'vectorAuthenticationFailure');
      return List.unmodifiable(lexical.take(limit));
    }

    final currentByIdentity = {for (final chunk in authenticated.chunks) chunk.identity: chunk};
    final vectors = <_RankedVector>[];
    var staleCount = 0;
    for (final match in eligibleMatches) {
      final identity = VectorIdentity(documentId: match.documentId, chunkIndex: match.chunkIndex);
      final chunk = currentByIdentity[identity];
      if (chunk == null || chunk.contentHash != match.contentHash) {
        staleCount++;
      } else {
        vectors.add(_RankedVector(chunk: chunk, rank: vectors.length + 1));
      }
    }

    final candidates = <VectorIdentity, _FusedCandidate>{};
    for (var index = 0; index < lexical.length; index++) {
      final result = lexical[index];
      final identity = VectorIdentity(documentId: result.id, chunkIndex: result.chunkIndex);
      candidates[identity] = _FusedCandidate(result: result, keywordRank: index + 1);
    }
    for (final vector in vectors) {
      final existing = candidates[vector.chunk.identity];
      if (existing == null) {
        candidates[vector.chunk.identity] = _FusedCandidate(result: vector.chunk.result(0), vectorRank: vector.rank);
      } else {
        existing.vectorRank = vector.rank;
      }
    }

    final ranked = candidates.values.toList(growable: false)..sort(_compareCandidates);
    final selected = ranked.take(limit).toList(growable: false);
    if (diagnostics != null) {
      final degradations = <MemorySearchDegradation>[
        if (staleCount > 0)
          MemorySearchDegradation(layer: _sourceLayer, reason: 'staleVector', omittedCount: staleCount),
      ];
      diagnostics(
        SearchDiagnostics(
          candidates: selected.map((candidate) => candidate.evidence(_sourceLayer)),
          unembeddedCount: await _diagnosticMissingCount(userId),
          degradations: degradations,
        ),
      );
    }
    return List.unmodifiable(selected.map((candidate) => candidate.scoredResult));
  }

  /// Counts current chunks without an exact content and model match.
  Future<int> missingCount({required String userId}) {
    _validateUserId(userId);
    return _inventory.missingCount(userId: userId, modelFingerprint: _embeddingProvider.modelFingerprint);
  }

  Future<void> _reportFallback(
    List<SearchResult> lexical,
    String userId,
    int limit,
    SearchDiagnosticsSink? diagnostics, {
    required String reason,
  }) async {
    if (diagnostics == null) return;
    final selected = lexical.take(limit).toList(growable: false);
    diagnostics(
      SearchDiagnostics(
        candidates: [
          for (var index = 0; index < selected.length; index++)
            _FusedCandidate(result: selected[index], keywordRank: index + 1).evidence(_sourceLayer),
        ],
        unembeddedCount: await _diagnosticMissingCount(userId),
        degradations: [MemorySearchDegradation(layer: _sourceLayer, reason: reason)],
      ),
    );
  }

  static List<SearchResult> _deduplicate(List<SearchResult> results) {
    final seen = <VectorIdentity>{};
    return [
      for (final result in results.take(_candidateLimit))
        if (seen.add(VectorIdentity(documentId: result.id, chunkIndex: result.chunkIndex))) result,
    ];
  }

  Future<int> _diagnosticMissingCount(String userId) =>
      _inventory.diagnosticMissingCount(userId: userId, modelFingerprint: _embeddingProvider.modelFingerprint);
}

final class _RankedVector {
  const new({required this.chunk, required this.rank});

  final _CorpusChunk chunk;
  final int rank;
}

final class _FusedCandidate {
  new({required this.result, this.keywordRank, this.vectorRank});

  final SearchResult result;
  final int? keywordRank;
  int? vectorRank;

  double get keywordContribution => keywordRank == null ? 0 : _keywordWeight / (_rrfK + keywordRank!);
  double get vectorContribution => vectorRank == null ? 0 : _vectorWeight / (_rrfK + vectorRank!);
  double get fusedScore => keywordContribution + vectorContribution;

  SearchResult get scoredResult => SearchResult(
    id: result.id,
    chunk: result.chunk,
    chunkIndex: result.chunkIndex,
    metadata: result.metadata,
    timestamp: result.timestamp,
    score: -fusedScore,
  );

  SearchRankEvidence evidence(String sourceLayer) => SearchRankEvidence(
    documentId: result.id,
    chunkIndex: result.chunkIndex,
    keywordRank: keywordRank,
    vectorRank: vectorRank,
    keywordContribution: keywordContribution,
    vectorContribution: vectorContribution,
    fusedScore: fusedScore,
    sourceLayer: sourceLayer,
  );
}

int _compareCandidates(_FusedCandidate left, _FusedCandidate right) {
  final byScore = right.fusedScore.compareTo(left.fusedScore);
  if (byScore != 0) return byScore;
  final byKeywordRank = _compareRank(left.keywordRank, right.keywordRank);
  if (byKeywordRank != 0) return byKeywordRank;
  final byVectorRank = _compareRank(left.vectorRank, right.vectorRank);
  if (byVectorRank != 0) return byVectorRank;
  final byDocument = left.result.id.compareTo(right.result.id);
  return byDocument != 0 ? byDocument : left.result.chunkIndex.compareTo(right.result.chunkIndex);
}

int _compareRank(int? left, int? right) {
  if (left == null && right != null) return 1;
  if (left != null && right == null) return -1;
  return (left ?? 0).compareTo(right ?? 0);
}

bool _validVector(List<double> vector) => vector.isNotEmpty && vector.every((value) => value.isFinite);

String _validateSourceLayer(String sourceLayer) {
  if (!const {'memory', 'conversation'}.contains(sourceLayer)) {
    throw ArgumentError.value(sourceLayer, 'sourceLayer', 'must be memory or conversation');
  }
  return sourceLayer;
}

void _validateUserId(String userId) {
  if (userId.isEmpty) throw ArgumentError.value(userId, 'userId', 'must not be empty');
}
