import 'package:dartclaw_search/dartclaw_search.dart';
import 'package:test/test.dart';

void main() {
  test('barrel exposes the kernel-owned contracts composed by this package', () {
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
  });
}
