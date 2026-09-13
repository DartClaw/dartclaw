import 'package:dartclaw_search/dartclaw_search.dart';
import 'package:test/test.dart';

void main() {
  test('barrel exposes search contracts, providers and model acquisition', () {
    final identity = VectorIdentity(documentId: 'document', chunkIndex: 0);
    final record = VectorRecord(
      documentId: identity.documentId,
      chunkIndex: identity.chunkIndex,
      contentHash: 'hash',
      modelFingerprint: 'model',
      vector: const [1],
    );
    final match = VectorMatch(
      documentId: identity.documentId,
      chunkIndex: identity.chunkIndex,
      contentHash: record.contentHash,
      score: 1,
    );
    final diagnostics = SearchDiagnostics(
      candidates: [
        SearchRankEvidence(
          documentId: match.documentId,
          chunkIndex: match.chunkIndex,
          keywordRank: 1,
          vectorRank: 1,
          keywordContribution: 0.25,
          vectorContribution: 0.5,
          fusedScore: 0.75,
          sourceLayer: 'memory',
        ),
      ],
    );

    expect(diagnostics.candidates.single.documentId, identity.documentId);
    expect(VectorIndex, isNotNull);
    expect(EmbeddingProvider, isNotNull);
    expect(SearchDiagnosticsSink, isNotNull);
    expect(
      NativeEmbeddingProvider(
        modelPath: '/not-read-during-construction',
        expectedSha256: List.filled(64, 'a').join(),
      ).modelFingerprint,
      hasLength(64),
    );
    expect(
      HttpEmbeddingProvider(
        endpoint: Uri.parse('https://example.com/embeddings'),
        model: 'model',
        checkNetworkAccess: (_) async {},
      ).modelFingerprint,
      hasLength(64),
    );
    expect(HybridSearch, isNotNull);
    expect(HybridSearchBackend, isNotNull);
    expect(VectorSynchronizer, isNotNull);
    expect(VectorSynchronizationResult, isNotNull);
    expect(DefaultEmbeddingModel.filename, isNotEmpty);
    expect(DefaultEmbeddingModelAcquirer, isNotNull);
    expect(ModelAcquisitionResult, isNotNull);
    expect(ModelAcquisitionStatus.values, hasLength(2));
  });
}
