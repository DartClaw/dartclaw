import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

void main() {
  group('vector values', () {
    test('identity and records have validated value semantics', () {
      final vector = [1.0, -2.0];
      final record = VectorRecord(
        documentId: 'document',
        chunkIndex: 2,
        contentHash: 'hash',
        modelFingerprint: 'model',
        vector: vector,
      );
      vector[0] = 9;

      expect(record.vector, [1.0, -2.0]);
      expect(() => record.vector[0] = 3, throwsUnsupportedError);
      expect(
        record,
        VectorRecord(
          documentId: 'document',
          chunkIndex: 2,
          contentHash: 'hash',
          modelFingerprint: 'model',
          vector: const [1.0, -2.0],
        ),
      );
      expect({
        VectorIdentity(documentId: 'document', chunkIndex: 2),
      }, contains(VectorIdentity(documentId: 'document', chunkIndex: 2)));
      expect(
        VectorMatch(documentId: 'document', chunkIndex: 2, contentHash: 'hash', score: -0.5),
        VectorMatch(documentId: 'document', chunkIndex: 2, contentHash: 'hash', score: -0.5),
      );
    });

    test('rejects incomplete identities, records, and matches', () {
      expect(() => VectorIdentity(documentId: '', chunkIndex: 0), throwsArgumentError);
      expect(() => VectorIdentity(documentId: 'document', chunkIndex: -1), throwsArgumentError);
      for (final invalid in <List<double>>[
        const [],
        const [double.nan],
        const [double.infinity],
        const [double.negativeInfinity],
      ]) {
        expect(
          () => VectorRecord(
            documentId: 'document',
            chunkIndex: 0,
            contentHash: 'hash',
            modelFingerprint: 'model',
            vector: invalid,
          ),
          throwsArgumentError,
        );
      }
      for (final invalid in [
        () => VectorRecord(
          documentId: '',
          chunkIndex: 0,
          contentHash: 'hash',
          modelFingerprint: 'model',
          vector: const [1],
        ),
        () => VectorRecord(
          documentId: 'document',
          chunkIndex: -1,
          contentHash: 'hash',
          modelFingerprint: 'model',
          vector: const [1],
        ),
        () => VectorRecord(
          documentId: 'document',
          chunkIndex: 0,
          contentHash: '',
          modelFingerprint: 'model',
          vector: const [1],
        ),
        () => VectorRecord(
          documentId: 'document',
          chunkIndex: 0,
          contentHash: 'hash',
          modelFingerprint: '',
          vector: const [1],
        ),
      ]) {
        expect(invalid, throwsArgumentError);
      }
      expect(
        () => VectorMatch(documentId: 'document', chunkIndex: 0, contentHash: 'hash', score: double.nan),
        throwsArgumentError,
      );
    });
  });

  group('search diagnostics', () {
    test('retains immutable content-free evidence and structured degradations', () {
      final candidates = [_evidence()];
      final degradations = [const MemorySearchDegradation(layer: 'vector', reason: 'unavailable')];
      final diagnostics = SearchDiagnostics(candidates: candidates, unembeddedCount: 3, degradations: degradations);
      candidates.clear();
      degradations.clear();

      expect(diagnostics.candidates, hasLength(1));
      expect(diagnostics.unembeddedCount, 3);
      expect(diagnostics.degradations.single.reason, 'unavailable');
      expect(() => diagnostics.candidates.clear(), throwsUnsupportedError);
      expect(() => diagnostics.degradations.clear(), throwsUnsupportedError);
    });

    test('rejects invalid ranks, contributions, totals, layers, and counts', () {
      final invalid = <SearchRankEvidence Function()>[
        () => _evidence(documentId: ''),
        () => _evidence(chunkIndex: -1),
        () => _evidence(keywordRank: 0),
        () => _evidence(keywordRank: null, vectorRank: null),
        () => _evidence(keywordRank: null, vectorContribution: 0.5, fusedScore: 0.5),
        () => _evidence(vectorRank: null, keywordContribution: 0, vectorContribution: 0.5, fusedScore: 0.5),
        () => _evidence(keywordContribution: -0.1, fusedScore: 0.4),
        () => _evidence(vectorContribution: double.nan, fusedScore: double.nan),
        () => _evidence(fusedScore: 9),
        () => _evidence(sourceLayer: ''),
      ];
      for (final create in invalid) {
        expect(create, throwsArgumentError);
      }
      expect(() => SearchDiagnostics(candidates: const [], unembeddedCount: -1), throwsArgumentError);
    });
  });

  test('vector and embedding port signatures support owner-scoped implementations', () async {
    final index = _VectorIndex();
    final provider = _EmbeddingProvider();
    final identity = VectorIdentity(documentId: 'document', chunkIndex: 0);
    final record = VectorRecord(
      documentId: 'document',
      chunkIndex: 0,
      contentHash: 'hash',
      modelFingerprint: provider.modelFingerprint,
      vector: const [1],
    );

    await index.search(const [1], userId: 'owner', modelFingerprint: provider.modelFingerprint, limit: 1);
    await index.list(userId: 'owner');
    await index.upsert([record], userId: 'owner', retire: {identity});
    await index.delete([identity], userId: 'owner');
    await index.replaceAll([record], userId: 'owner');
    expect(await provider.embedQuery('query'), [1]);
    expect(await provider.embedDocuments(const ['first', 'second']), [
      [1],
      [1],
    ]);
    await provider.dispose();
  });
}

SearchRankEvidence _evidence({
  String documentId = 'document',
  int chunkIndex = 0,
  int? keywordRank = 1,
  int? vectorRank = 2,
  double keywordContribution = 0.25,
  double vectorContribution = 0.5,
  double fusedScore = 0.75,
  String sourceLayer = 'memory',
}) => SearchRankEvidence(
  documentId: documentId,
  chunkIndex: chunkIndex,
  keywordRank: keywordRank,
  vectorRank: vectorRank,
  keywordContribution: keywordContribution,
  vectorContribution: vectorContribution,
  fusedScore: fusedScore,
  sourceLayer: sourceLayer,
);

final class _VectorIndex implements VectorIndex {
  @override
  Future<List<VectorMatch>> search(
    List<double> queryVector, {
    required String userId,
    required String modelFingerprint,
    int limit = 20,
  }) async => const [];

  @override
  Future<List<VectorRecord>> list({required String userId}) async => const [];

  @override
  Future<void> upsert(
    Iterable<VectorRecord> records, {
    required String userId,
    Set<VectorIdentity> retire = const {},
  }) async {}

  @override
  Future<void> delete(Iterable<VectorIdentity> identities, {required String userId}) async {}

  @override
  Future<void> replaceAll(Iterable<VectorRecord> records, {required String userId}) async {}
}

final class _EmbeddingProvider implements EmbeddingProvider {
  @override
  String get modelFingerprint => 'model';

  @override
  Future<List<double>> embedQuery(String query) async => const [1];

  @override
  Future<List<List<double>>> embedDocuments(List<String> documents) async => [
    for (final _ in documents) const [1],
  ];

  @override
  Future<void> dispose() async {}
}
