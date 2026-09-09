import 'package:dartclaw_search/dartclaw_search.dart';
import 'package:test/test.dart';

import 'search_test_support.dart';

const alphaHash = '8ed3f6ad685b959ead7022518e1af76cd816f8e8ec7ccdda1ed4018e8f2223f8';
const betaHash = 'f44e64e75f3948e9f73f8dfa94721c4ce8cbb4f265c4790c702b2d41cfbf2753';
const gammaHash = 'be9d587defa1f0c09ef49eb17e206983a5f8f8289e4281860bd0ee5a19592c67';

void main() {
  test('synchronization rebuild and counts retain the requested owner and model', () async {
    final lexical = FakeFullTextIndex(
      documents: [
        document('a', ['alpha']),
      ],
    );
    final vectors = FakeVectorIndex();
    final synchronizer = VectorSynchronizer(
      lexicalIndex: lexical,
      vectorIndex: vectors,
      embeddingProvider: FakeEmbeddingProvider(modelFingerprint: 'model-memory'),
      sourceLayer: 'memory',
    );

    expect((await synchronizer.synchronize(['a'], userId: 'memory-owner')).embeddedCount, 1);
    expect(await synchronizer.missingCount(userId: 'memory-owner'), 0);
    expect((await synchronizer.rebuild(userId: 'memory-owner')).reusedCount, 1);
    expect(vectors.records.single.modelFingerprint, 'model-memory');
    expect(lexical.owners.keys, unorderedEquals(['fetch', 'count', 'list']));
    expect(vectors.owners.keys, unorderedEquals(['list', 'upsert', 'replaceAll']));
    for (final owners in [...lexical.owners.values, ...vectors.owners.values]) {
      expect(owners, isNotEmpty);
      expect(owners, everyElement('memory-owner'));
    }
  });

  test('incremental synchronization reuses, embeds in source order, and retires atomically', () async {
    final lexical = FakeFullTextIndex(
      documents: [
        document('d1', ['alpha', 'beta']),
      ],
    );
    final vectors = FakeVectorIndex(
      records: [
        record('d1', 0, alphaHash),
        record('d1', 1, 'old-hash'),
        record('d1', 2, gammaHash),
        record('deleted', 0, gammaHash),
      ],
    );
    final provider = FakeEmbeddingProvider(
      documentVectors: const [
        [2],
      ],
    );
    final synchronizer = VectorSynchronizer(
      lexicalIndex: lexical,
      vectorIndex: vectors,
      embeddingProvider: provider,
      sourceLayer: 'memory',
    );

    final result = await synchronizer.synchronize(['d1', 'deleted'], userId: 'owner');

    expect(provider.embeddedDocuments, ['beta']);
    expect(vectors.upserts, hasLength(1));
    expect(vectors.upserts.single.records.single.contentHash, betaHash);
    expect(vectors.upserts.single.retire, {
      VectorIdentity(documentId: 'd1', chunkIndex: 1),
      VectorIdentity(documentId: 'd1', chunkIndex: 2),
      VectorIdentity(documentId: 'deleted', chunkIndex: 0),
    });
    expect((result.embeddedCount, result.reusedCount, result.retiredCount, result.unembeddedCount), (1, 1, 3, 0));
    expect(result.degradations, isEmpty);
  });

  test('a new model fingerprint replaces every current identity', () async {
    final lexical = FakeFullTextIndex(
      documents: [
        document('d1', ['alpha', 'beta']),
      ],
    );
    final vectors = FakeVectorIndex(records: [record('d1', 0, alphaHash), record('d1', 1, betaHash)]);
    final synchronizer = VectorSynchronizer(
      lexicalIndex: lexical,
      vectorIndex: vectors,
      embeddingProvider: FakeEmbeddingProvider(modelFingerprint: 'model-v2'),
      sourceLayer: 'conversation',
    );

    final result = await synchronizer.synchronize(['d1'], userId: 'owner');

    expect(result.embeddedCount, 2);
    expect(result.reusedCount, 0);
    expect(result.retiredCount, 2);
    expect(vectors.records.every((item) => item.modelFingerprint == 'model-v2'), isTrue);
  });

  test('unchanged current chunks make no document embedding call', () async {
    final lexical = FakeFullTextIndex(
      documents: [
        document('d1', ['alpha']),
      ],
    );
    final vectors = FakeVectorIndex(records: [record('d1', 0, alphaHash)]);
    final provider = FakeEmbeddingProvider();
    final synchronizer = VectorSynchronizer(
      lexicalIndex: lexical,
      vectorIndex: vectors,
      embeddingProvider: provider,
      sourceLayer: 'memory',
    );

    final result = await synchronizer.synchronize(['d1'], userId: 'owner');

    expect(provider.documentCalls, 0);
    expect(vectors.upserts, isEmpty);
    expect((result.embeddedCount, result.reusedCount, result.retiredCount, result.unembeddedCount), (0, 1, 0, 0));
  });

  test('provider failure still retires authenticated stale identities', () async {
    final lexical = FakeFullTextIndex(
      documents: [
        document('d1', ['alpha']),
      ],
    );
    final vectors = FakeVectorIndex(records: [record('d1', 0, 'old-hash'), record('d1', 1, betaHash)]);
    final provider = FakeEmbeddingProvider()..failDocuments = true;
    final synchronizer = VectorSynchronizer(
      lexicalIndex: lexical,
      vectorIndex: vectors,
      embeddingProvider: provider,
      sourceLayer: 'memory',
    );

    final result = await synchronizer.synchronize(['d1'], userId: 'owner');

    expect(vectors.upserts.single.records, isEmpty);
    expect(vectors.upserts.single.retire, {
      VectorIdentity(documentId: 'd1', chunkIndex: 0),
      VectorIdentity(documentId: 'd1', chunkIndex: 1),
    });
    expect((result.embeddedCount, result.retiredCount, result.unembeddedCount), (0, 2, 1));
    expect(result.degradations.single.reason, 'embeddingFailure');
  });

  test('delayed incremental embedding never publishes superseded source content', () async {
    final lexical = FakeFullTextIndex(
      documents: [
        document('d1', ['alpha']),
      ],
    );
    final vectors = FakeVectorIndex();
    final provider = FakeEmbeddingProvider()
      ..afterDocumentEmbedding = () => lexical.documents['d1'] = document('d1', ['changed']);
    final synchronizer = VectorSynchronizer(
      lexicalIndex: lexical,
      vectorIndex: vectors,
      embeddingProvider: provider,
      sourceLayer: 'memory',
    );

    final result = await synchronizer.synchronize(['d1'], userId: 'owner');

    expect(vectors.upserts, isEmpty);
    expect(result.embeddedCount, 0);
    expect(result.degradations.single.reason, 'sourceChanged');
    expect(result.unembeddedCount, 1);
  });

  test('rebuild retains exact vectors and atomically replaces stale and obsolete records', () async {
    final lexical = FakeFullTextIndex(
      documents: [
        document('d1', ['alpha']),
        document('d2', ['beta']),
      ],
    );
    final retained = record('d1', 0, alphaHash, value: 7);
    final vectors = FakeVectorIndex(records: [retained, record('d2', 0, 'old-hash'), record('deleted', 0, gammaHash)]);
    final provider = FakeEmbeddingProvider(
      documentVectors: const [
        [8],
      ],
    );
    final synchronizer = VectorSynchronizer(
      lexicalIndex: lexical,
      vectorIndex: vectors,
      embeddingProvider: provider,
      sourceLayer: 'conversation',
    );

    final result = await synchronizer.rebuild(userId: 'owner');

    expect(provider.embeddedDocuments, ['beta']);
    expect(vectors.replacements, hasLength(1));
    expect(vectors.replacements.single.map((item) => (item.documentId, item.contentHash, item.vector.single)), [
      ('d1', alphaHash, 7),
      ('d2', betaHash, 8),
    ]);
    expect((result.embeddedCount, result.reusedCount, result.retiredCount, result.unembeddedCount), (1, 1, 2, 0));
  });

  test('empty rebuild clears the retained vector corpus', () async {
    final vectors = FakeVectorIndex(records: [record('deleted', 0, alphaHash)]);
    final synchronizer = VectorSynchronizer(
      lexicalIndex: FakeFullTextIndex(),
      vectorIndex: vectors,
      embeddingProvider: FakeEmbeddingProvider(),
      sourceLayer: 'memory',
    );

    final result = await synchronizer.rebuild(userId: 'owner');

    expect(vectors.replacements, [isEmpty]);
    expect((result.embeddedCount, result.reusedCount, result.retiredCount, result.unembeddedCount), (0, 0, 1, 0));
  });

  test('changed complete source inventory refuses a delayed rebuild publication', () async {
    final lexical = FakeFullTextIndex(
      documents: [
        document('d1', ['alpha']),
      ],
    );
    final vectors = FakeVectorIndex();
    final provider = FakeEmbeddingProvider()
      ..afterDocumentEmbedding = () => lexical.documents['d1'] = document('d1', ['changed']);
    final synchronizer = VectorSynchronizer(
      lexicalIndex: lexical,
      vectorIndex: vectors,
      embeddingProvider: provider,
      sourceLayer: 'memory',
    );

    final result = await synchronizer.rebuild(userId: 'owner');

    expect(vectors.replacements, isEmpty);
    expect(result.degradations.single.reason, 'sourceChanged');
  });

  test('rebuild provider failure publishes nothing and reports current missing count', () async {
    final lexical = FakeFullTextIndex(
      documents: [
        document('d1', ['alpha']),
        document('d2', ['beta']),
      ],
    );
    final retained = record('d1', 0, alphaHash);
    final vectors = FakeVectorIndex(records: [retained, record('deleted', 0, gammaHash)]);
    final provider = FakeEmbeddingProvider()..failDocuments = true;
    final synchronizer = VectorSynchronizer(
      lexicalIndex: lexical,
      vectorIndex: vectors,
      embeddingProvider: provider,
      sourceLayer: 'memory',
    );

    final result = await synchronizer.rebuild(userId: 'owner');

    expect(vectors.replacements, isEmpty);
    expect((result.embeddedCount, result.reusedCount, result.retiredCount, result.unembeddedCount), (0, 1, 0, 1));
    expect(result.degradations.single.reason, 'embeddingFailure');
  });

  test('missing count treats an unavailable vector enumeration as all chunks missing', () async {
    final vectors = FakeVectorIndex()..failList = true;
    final synchronizer = VectorSynchronizer(
      lexicalIndex: FakeFullTextIndex(
        documents: [
          document('d1', ['alpha', 'beta']),
        ],
      ),
      vectorIndex: vectors,
      embeddingProvider: FakeEmbeddingProvider(),
      sourceLayer: 'memory',
    );

    expect(await synchronizer.missingCount(userId: 'owner'), 2);
  });

  test('result collections are immutable and counts and source layer are validated', () {
    final degradation = const MemorySearchDegradation(layer: 'memory', reason: 'embeddingFailure');
    final result = VectorSynchronizationResult(
      embeddedCount: 0,
      reusedCount: 0,
      retiredCount: 0,
      unembeddedCount: 1,
      degradations: [degradation],
    );
    expect(() => result.degradations.add(degradation), throwsUnsupportedError);
    expect(
      () => VectorSynchronizationResult(embeddedCount: -1, reusedCount: 0, retiredCount: 0, unembeddedCount: 0),
      throwsArgumentError,
    );
    expect(
      () => VectorSynchronizer(
        lexicalIndex: FakeFullTextIndex(),
        vectorIndex: FakeVectorIndex(),
        embeddingProvider: FakeEmbeddingProvider(),
        sourceLayer: 'wiki',
      ),
      throwsArgumentError,
    );
  });
}
