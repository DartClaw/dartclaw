import 'package:dartclaw_search/dartclaw_search.dart';
import 'package:test/test.dart';

import 'search_test_support.dart';

const alphaHash = '8ed3f6ad685b959ead7022518e1af76cd816f8e8ec7ccdda1ed4018e8f2223f8';
const betaHash = 'f44e64e75f3948e9f73f8dfa94721c4ce8cbb4f265c4790c702b2d41cfbf2753';
const gammaHash = 'be9d587defa1f0c09ef49eb17e206983a5f8f8289e4281860bd0ee5a19592c67';

void main() {
  test('equal fused scores prefer keyword rank before vector rank and identity', () async {
    final keywordIds = List.generate(20, (index) => 'keyword-$index');
    final vectorIds = List.generate(20, (index) => 'vector-$index');
    keywordIds[5] = vectorIds[5] = 'z-keyword-priority';
    keywordIds[16] = vectorIds[2] = 'a-vector-priority';
    final lexical = FakeFullTextIndex(
      documents: [
        for (final id in {...keywordIds, ...vectorIds}) document(id, ['alpha']),
      ],
      searchResults: [for (final id in keywordIds) lexicalResult(id, 'alpha', 0, 0)],
    );
    final search = HybridSearch(
      lexicalIndex: lexical,
      vectorIndex: FakeVectorIndex(
        matches: [
          for (final id in vectorIds) VectorMatch(documentId: id, chunkIndex: 0, contentHash: alphaHash, score: 1),
        ],
      ),
      embeddingProvider: FakeEmbeddingProvider(),
      relevanceFilter: allRelevantFilter(),
      sourceLayer: 'memory',
    );
    SearchDiagnostics? diagnostics;

    final results = await search.search('query', userId: 'owner', diagnostics: (value) => diagnostics = value);

    expect(results.take(2).map((result) => result.id), ['z-keyword-priority', 'a-vector-priority']);
    final tied = diagnostics!.candidates.take(2).toList();
    expect(tied.map((item) => (item.keywordRank, item.vectorRank)), [(6, 6), (17, 3)]);
    expect(tied[0].fusedScore, tied[1].fusedScore);
  });

  test('search authentication and diagnostics forward the requested owner and current model', () async {
    final lexical = FakeFullTextIndex(
      documents: [
        document('a', ['alpha']),
      ],
      searchResults: [lexicalResult('a', 'alpha', 0, 0)],
    );
    final vectors = FakeVectorIndex(
      records: [record('a', 0, alphaHash, fingerprint: 'model-conversation')],
      matches: [VectorMatch(documentId: 'a', chunkIndex: 0, contentHash: alphaHash, score: 1)],
    );
    final search = HybridSearch(
      lexicalIndex: lexical,
      vectorIndex: vectors,
      embeddingProvider: FakeEmbeddingProvider(modelFingerprint: 'model-conversation'),
      relevanceFilter: allRelevantFilter(),
      sourceLayer: 'conversation',
    );
    SearchDiagnostics? diagnostics;

    expect(
      await search.search('query', userId: 'conversation-owner', diagnostics: (value) => diagnostics = value),
      hasLength(1),
    );
    expect(await search.missingCount(userId: 'conversation-owner'), 0);
    expect(diagnostics!.unembeddedCount, 0);
    expect(lexical.owners.keys, unorderedEquals(['search', 'fetch', 'count', 'list']));
    expect(vectors.owners.keys, unorderedEquals(['search', 'list']));
    for (final owners in [...lexical.owners.values, ...vectors.owners.values]) {
      expect(owners, isNotEmpty);
      expect(owners, everyElement('conversation-owner'));
    }
    expect(vectors.searchFingerprints, ['model-conversation']);
  });

  test('fuses authenticated lexical and vector candidates with fixed weighted RRF', () async {
    final lexical = FakeFullTextIndex(
      documents: [
        document('a', ['alpha'], metadata: const {'source': 'A'}),
        document('b', ['beta'], metadata: const {'source': 'B'}),
        document('c', ['gamma'], metadata: const {'source': 'C'}),
      ],
      searchResults: [
        lexicalResult('b', 'beta', 0, 4, metadata: const {'source': 'B'}),
        lexicalResult('a', 'alpha', 0, 5, metadata: const {'source': 'A'}),
      ],
    );
    final vectors = FakeVectorIndex(
      records: [record('a', 0, alphaHash), record('c', 0, gammaHash)],
      matches: [
        VectorMatch(documentId: 'a', chunkIndex: 0, contentHash: alphaHash, score: 0.9),
        VectorMatch(documentId: 'c', chunkIndex: 0, contentHash: gammaHash, score: 0.20),
        VectorMatch(documentId: 'b', chunkIndex: 0, contentHash: betaHash, score: 0.19),
      ],
    );
    final search = HybridSearch(
      lexicalIndex: lexical,
      vectorIndex: vectors,
      embeddingProvider: FakeEmbeddingProvider(),
      relevanceFilter: allRelevantFilter(),
      sourceLayer: 'memory',
    );
    SearchDiagnostics? diagnostics;

    final results = await search.search('query', userId: 'owner', diagnostics: (value) => diagnostics = value);

    expect(results.map((result) => result.id), ['a', 'c', 'b']);
    expect(results.map((result) => result.chunk), ['alpha', 'gamma', 'beta']);
    expect(results.map((result) => result.metadata['source']), ['A', 'C', 'B']);
    expect(results[0].score, closeTo(-(0.25 / 62 + 0.75 / 61), 1e-12));
    expect(results[1].score, closeTo(-(0.75 / 62), 1e-12));
    expect(results[2].score, closeTo(-(0.25 / 61), 1e-12));
    expect(diagnostics!.candidates.map((item) => (item.documentId, item.keywordRank, item.vectorRank)), [
      ('a', 2, 1),
      ('c', null, 2),
      ('b', 1, null),
    ]);
    expect(diagnostics!.candidates.every((item) => item.fusedScore > 0), isTrue);
    expect(diagnostics!.unembeddedCount, 1);
    expect(diagnostics!.degradations, isEmpty);
    expect((lexical.lastSearchLimit, vectors.lastSearchLimit), (20, 20));
    expect(() => results.add(results.first), throwsUnsupportedError);
  });

  test('filters all fused candidates before applying the requested result limit', () async {
    final lexical = FakeFullTextIndex(
      documents: [
        document('nearby', ['related but does not answer']),
        document('answer', ['contains the requested fact']),
      ],
      searchResults: [
        lexicalResult('nearby', 'related but does not answer', 0, 0),
        lexicalResult('answer', 'contains the requested fact', 0, 0),
      ],
    );
    final search = HybridSearch(
      lexicalIndex: lexical,
      vectorIndex: FakeVectorIndex(),
      embeddingProvider: FakeEmbeddingProvider(),
      relevanceFilter: SearchRelevanceFilter(judge: (_, _) async => {'0': false, '1': true}),
      sourceLayer: 'memory',
    );
    SearchDiagnostics? diagnostics;

    final results = await search.search(
      'requested fact',
      userId: 'owner',
      limit: 1,
      diagnostics: (value) {
        diagnostics = value;
      },
    );

    expect(results.single.id, 'answer');
    expect(diagnostics!.candidates.single.documentId, 'answer');
    expect(diagnostics!.candidates.single.keywordRank, 2);
  });

  test('authenticates merged candidates before invoking relevance judgment', () async {
    final lexical = FakeFullTextIndex(
      documents: [
        document('changed', ['current text']),
      ],
      searchResults: [lexicalResult('changed', 'stale text', 0, 0)],
    );
    var judgeCalls = 0;
    final search = HybridSearch(
      lexicalIndex: lexical,
      vectorIndex: FakeVectorIndex(),
      embeddingProvider: FakeEmbeddingProvider(),
      relevanceFilter: SearchRelevanceFilter(
        judge: (_, _) async {
          judgeCalls++;
          return const {};
        },
      ),
      sourceLayer: 'memory',
    );
    SearchDiagnostics? diagnostics;

    expect(await search.search('query', userId: 'owner', diagnostics: (value) => diagnostics = value), isEmpty);
    expect(judgeCalls, 0);
    expect(diagnostics!.candidates, isEmpty);
    expect(diagnostics!.degradations, isEmpty);
  });

  test('re-authenticates judged survivors and publishes fresh metadata only for unchanged text', () async {
    final lexical = FakeFullTextIndex(
      documents: [
        document('deleted', ['delete me']),
        document('edited', ['edit me']),
        document('current', ['keep me'], metadata: const {'revision': 'before'}),
      ],
      searchResults: [
        lexicalResult('deleted', 'delete me', 0, 0),
        lexicalResult('edited', 'edit me', 0, 0),
        lexicalResult('current', 'keep me', 0, 0, metadata: const {'revision': 'before'}),
      ],
    );
    final search = HybridSearch(
      lexicalIndex: lexical,
      vectorIndex: FakeVectorIndex(),
      embeddingProvider: FakeEmbeddingProvider(),
      relevanceFilter: SearchRelevanceFilter(
        judge: (_, _) async {
          lexical.documents.remove('deleted');
          lexical.documents['edited'] = document('edited', ['changed after judgment began']);
          lexical.documents['current'] = document('current', ['keep me'], metadata: const {'revision': 'after'});
          return {'0': true, '1': true, '2': true};
        },
      ),
      sourceLayer: 'conversation',
    );
    SearchDiagnostics? diagnostics;

    final results = await search.search('query', userId: 'owner', diagnostics: (value) => diagnostics = value);

    expect(results.map((result) => result.id), ['current']);
    expect(results.single.metadata, {'revision': 'after'});
    expect(diagnostics!.candidates.map((candidate) => candidate.documentId), ['current']);
  });

  test('refreshes the lexical fallback after relevance failure', () async {
    final lexical = FakeFullTextIndex(
      documents: [
        document('deleted', ['delete me']),
        document('edited', ['edit me']),
        document('first', ['keep first'], metadata: const {'revision': 'before'}),
        document('second', ['keep second'], metadata: const {'revision': 'before'}),
      ],
      searchResults: [
        lexicalResult('deleted', 'delete me', 0, 10),
        lexicalResult('edited', 'edit me', 0, 9),
        lexicalResult('first', 'keep first', 0, 8, metadata: const {'revision': 'before'}),
        lexicalResult('second', 'keep second', 0, 7, metadata: const {'revision': 'before'}),
      ],
    );
    final search = HybridSearch(
      lexicalIndex: lexical,
      vectorIndex: FakeVectorIndex(),
      embeddingProvider: FakeEmbeddingProvider(),
      relevanceFilter: SearchRelevanceFilter(
        judge: (_, _) async {
          lexical.documents.remove('deleted');
          lexical.documents['edited'] = document('edited', ['changed after judgment began']);
          lexical.documents['first'] = document('first', ['keep first'], metadata: const {'revision': 'after'});
          lexical.documents['second'] = document('second', ['keep second'], metadata: const {'revision': 'after'});
          throw StateError('judge failed');
        },
      ),
      sourceLayer: 'memory',
    );
    SearchDiagnostics? diagnostics;

    final results = await search.search('query', userId: 'owner', diagnostics: (value) => diagnostics = value);

    expect(results.map((result) => (result.id, result.score, result.metadata['revision'])), [
      ('first', 8, 'after'),
      ('second', 7, 'after'),
    ]);
    expect(diagnostics!.degradations.single.reason, 'relevanceFailure');
    expect(diagnostics!.candidates.map((candidate) => (candidate.documentId, candidate.keywordRank)), [
      ('first', 3),
      ('second', 4),
    ]);
  });

  test('fails closed when the relevance fallback cannot be refreshed', () async {
    final lexical = FakeFullTextIndex(
      documents: [
        document('a', ['alpha']),
      ],
      searchResults: [lexicalResult('a', 'alpha', 0, 7)],
    );
    final search = HybridSearch(
      lexicalIndex: lexical,
      vectorIndex: FakeVectorIndex(),
      embeddingProvider: FakeEmbeddingProvider(),
      relevanceFilter: SearchRelevanceFilter(
        judge: (_, _) async {
          lexical.failFetch = true;
          throw StateError('judge failed');
        },
      ),
      sourceLayer: 'memory',
    );
    SearchDiagnostics? diagnostics;

    expect(await search.search('query', userId: 'owner', diagnostics: (value) => diagnostics = value), isEmpty);
    expect(diagnostics!.candidates, isEmpty);
    expect(diagnostics!.degradations.map((degradation) => degradation.reason), [
      'relevanceFailure',
      'vectorAuthenticationFailure',
    ]);
  });

  test('reports an empty relevance selection as healthy', () async {
    final lexical = FakeFullTextIndex(
      documents: [
        document('a', ['alpha']),
      ],
      searchResults: [lexicalResult('a', 'alpha', 0, 7)],
    );
    final search = HybridSearch(
      lexicalIndex: lexical,
      vectorIndex: FakeVectorIndex(),
      embeddingProvider: FakeEmbeddingProvider(),
      relevanceFilter: SearchRelevanceFilter(judge: (_, _) async => {'0': false}),
      sourceLayer: 'memory',
    );
    SearchDiagnostics? diagnostics;

    expect(await search.search('query', userId: 'owner', diagnostics: (value) => diagnostics = value), isEmpty);
    expect(diagnostics!.candidates, isEmpty);
    expect(diagnostics!.degradations, isEmpty);
  });

  test('semantic failure preserves lexical scores and order and reports typed degradation', () async {
    final lexical = FakeFullTextIndex(
      documents: [
        document('a', ['alpha']),
        document('b', ['beta']),
      ],
      searchResults: [lexicalResult('b', 'beta', 0, -4), lexicalResult('a', 'alpha', 0, -2)],
    );
    final vectors = FakeVectorIndex(records: [record('a', 0, alphaHash), record('b', 0, betaHash)]);
    final provider = FakeEmbeddingProvider()..failQuery = true;
    final search = HybridSearch(
      lexicalIndex: lexical,
      vectorIndex: vectors,
      embeddingProvider: provider,
      relevanceFilter: allRelevantFilter(),
      sourceLayer: 'conversation',
    );
    SearchDiagnostics? diagnostics;

    final results = await search.search(
      'query',
      userId: 'owner',
      limit: 1,
      diagnostics: (value) => diagnostics = value,
    );

    expect(results.map((result) => (result.id, result.score)), [('b', -4)]);
    expect(vectors.searchCalls, 0);
    expect(diagnostics!.candidates.single.vectorRank, isNull);
    expect(diagnostics!.candidates.single.keywordRank, 1);
    expect(diagnostics!.degradations.single.toJson(), {
      'layer': 'conversation',
      'reason': 'embeddingFailure',
      'omittedCount': 0,
    });
  });

  test('empty query does no constituent, embedding, inventory, or vector work', () async {
    final lexical = FakeFullTextIndex(
      documents: [
        document('a', ['alpha']),
      ],
    );
    final vectors = FakeVectorIndex();
    final provider = FakeEmbeddingProvider();
    final search = HybridSearch(
      lexicalIndex: lexical,
      vectorIndex: vectors,
      embeddingProvider: provider,
      relevanceFilter: allRelevantFilter(),
      sourceLayer: 'memory',
    );
    SearchDiagnostics? diagnostics;

    expect(await search.search('  ', userId: 'owner', diagnostics: (value) => diagnostics = value), isEmpty);
    expect((lexical.searchCalls, lexical.fetchCalls, lexical.countCalls, lexical.listCalls), (0, 0, 0, 0));
    expect((provider.queryCalls, provider.documentCalls, vectors.searchCalls, vectors.listCalls), (0, 0, 0, 0));
    expect(diagnostics!.candidates, isEmpty);
  });

  test('omits stale vector candidates after current lexical authentication', () async {
    final lexical = FakeFullTextIndex(
      documents: [
        document('a', ['changed']),
      ],
      searchResults: [lexicalResult('a', 'changed', 0, 3)],
    );
    final vectors = FakeVectorIndex(
      matches: [VectorMatch(documentId: 'a', chunkIndex: 0, contentHash: alphaHash, score: 1)],
    );
    final search = HybridSearch(
      lexicalIndex: lexical,
      vectorIndex: vectors,
      embeddingProvider: FakeEmbeddingProvider(),
      relevanceFilter: allRelevantFilter(),
      sourceLayer: 'memory',
    );
    SearchDiagnostics? diagnostics;

    final results = await search.search('query', userId: 'owner', diagnostics: (value) => diagnostics = value);

    expect(results.single.id, 'a');
    expect(diagnostics!.candidates.single.vectorRank, isNull);
    expect(diagnostics!.degradations.single.reason, 'staleVector');
    expect(diagnostics!.degradations.single.omittedCount, 1);
  });

  test('authentication failure fails closed when lexical fallback refresh also fails', () async {
    final lexical = FakeFullTextIndex(
      documents: [
        document('a', ['alpha']),
      ],
      searchResults: [lexicalResult('a', 'alpha', 0, 7)],
    )..failFetch = true;
    final vectors = FakeVectorIndex(
      matches: [VectorMatch(documentId: 'a', chunkIndex: 0, contentHash: alphaHash, score: 1)],
    );
    final search = HybridSearch(
      lexicalIndex: lexical,
      vectorIndex: vectors,
      embeddingProvider: FakeEmbeddingProvider(),
      relevanceFilter: allRelevantFilter(),
      sourceLayer: 'memory',
    );
    SearchDiagnostics? diagnostics;

    expect(await search.search('query', userId: 'owner', diagnostics: (value) => diagnostics = value), isEmpty);
    expect(diagnostics!.candidates, isEmpty);
    expect(diagnostics!.degradations.single.reason, 'vectorAuthenticationFailure');
    expect(diagnostics!.unembeddedCount, 1);
  });

  test('vector search failure falls back and lexical failure still propagates', () async {
    final lexical = FakeFullTextIndex(
      documents: [
        document('a', ['alpha']),
      ],
      searchResults: [lexicalResult('a', 'alpha', 0, 9)],
    );
    final vectors = FakeVectorIndex()..failSearch = true;
    final provider = FakeEmbeddingProvider();
    final search = HybridSearch(
      lexicalIndex: lexical,
      vectorIndex: vectors,
      embeddingProvider: provider,
      relevanceFilter: allRelevantFilter(),
      sourceLayer: 'memory',
    );
    SearchDiagnostics? diagnostics;

    expect(
      (await search.search('query', userId: 'owner', diagnostics: (value) => diagnostics = value)).single.score,
      9,
    );
    expect(diagnostics!.degradations.single.reason, 'vectorSearchFailure');

    lexical.failSearch = true;
    await expectLater(search.search('query', userId: 'owner'), throwsStateError);
    expect(provider.queryCalls, 1);
  });

  test('invalid non-finite query vectors degrade before vector search', () async {
    final lexical = FakeFullTextIndex(
      documents: [
        document('a', ['alpha']),
      ],
      searchResults: [lexicalResult('a', 'alpha', 0, 2)],
    );
    final vectors = FakeVectorIndex();
    final search = HybridSearch(
      lexicalIndex: lexical,
      vectorIndex: vectors,
      embeddingProvider: FakeEmbeddingProvider(queryVector: [double.nan]),
      relevanceFilter: allRelevantFilter(),
      sourceLayer: 'memory',
    );
    SearchDiagnostics? diagnostics;

    expect(
      (await search.search('query', userId: 'owner', diagnostics: (value) => diagnostics = value)).single.score,
      2,
    );
    expect(vectors.searchCalls, 0);
    expect(diagnostics!.degradations.single.reason, 'embeddingFailure');
  });

  test('adapter applies memory selection, maps once, and preserves fallback scores and degradation', () async {
    final lexical = FakeFullTextIndex(
      documents: [
        document('a', ['alpha']),
      ],
      searchResults: [lexicalResult('a', 'alpha', 0, -6)],
    );
    final provider = FakeEmbeddingProvider()..failQuery = true;
    final hybrid = HybridSearch(
      lexicalIndex: lexical,
      vectorIndex: FakeVectorIndex(records: [record('a', 0, alphaHash)]),
      embeddingProvider: provider,
      relevanceFilter: allRelevantFilter(),
      sourceLayer: 'memory',
    );
    var mappingCalls = 0;
    final backend = HybridSearchBackend(
      search: hybrid,
      toMemoryResult: (result) {
        mappingCalls++;
        return MemorySearchResult(text: result.chunk, source: result.id, score: result.score);
      },
    );

    expect(await backend.search('query', layers: {SearchResultLayer.wiki}), isEmpty);
    final outcome = await backend.search('query', userId: 'owner');

    expect(mappingCalls, 1);
    expect(outcome.single.score, -6);
    expect(outcome.degradedLayers, ['memory']);
    expect(outcome.degradations.single.reason, 'embeddingFailure');
    expect(await backend.resolve('a'), isNull);
    await backend.indexAfterWrite();
  });

  test('validates layer, owner, and result limit at the public boundary', () async {
    expect(
      () => HybridSearch(
        lexicalIndex: FakeFullTextIndex(),
        vectorIndex: FakeVectorIndex(),
        embeddingProvider: FakeEmbeddingProvider(),
        relevanceFilter: allRelevantFilter(),
        sourceLayer: 'wiki',
      ),
      throwsArgumentError,
    );
    final search = HybridSearch(
      lexicalIndex: FakeFullTextIndex(),
      vectorIndex: FakeVectorIndex(),
      embeddingProvider: FakeEmbeddingProvider(),
      relevanceFilter: allRelevantFilter(),
      sourceLayer: 'memory',
    );
    await expectLater(search.search('query', userId: ''), throwsArgumentError);
    await expectLater(search.search('query', userId: 'owner', limit: 0), throwsArgumentError);
  });
}
