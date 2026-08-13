import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:test/test.dart';

void main() {
  test('passes one unchanged natural-language query and owner to each request retriever', () async {
    final personal = _S07RecordingBackend();
    final wiki = _RecordingWiki();
    final backend = ComposedSearchBackend(personal: personal, wiki: wiki);

    await backend.search('  project "Falcon" AND status?  ', userId: 'owner');

    expect(personal.calls, [('  project "Falcon" AND status?  ', 'owner')]);
    expect(wiki.queries, ['  project "Falcon" AND status?  ']);
  });

  test('ranks every admitted wiki candidate before selecting the best 50', () async {
    final wiki = _RecordingWiki()
      ..results = [
        for (var index = 0; index < 50; index++)
          MemorySearchResult(
            text: 'ordinary $index',
            source: 'wiki/ordinary-$index.md',
            score: index.toDouble(),
            role: 'wiki',
            locator: 'wiki/ordinary-$index.md',
          ),
        const MemorySearchResult(
          text: 'late source-backed synthesis',
          source: 'wiki/zz-late.md',
          category: 'untrusted synthesized knowledge',
          score: -1001,
          role: 'wiki',
          provenance: 'llm-authored',
          locator: 'wiki/zz-late.md',
        ),
      ];
    final backend = ComposedSearchBackend(personal: _S07RecordingBackend(), wiki: wiki);

    final outcome = await backend.search('Falcon', limit: 50);

    expect(wiki.queries, ['Falcon']);
    expect(outcome, hasLength(50));
    expect(outcome.first.locator, 'wiki/zz-late.md');
    expect(outcome.first.provenance, 'llm-authored');
  });

  test('collapses a QMD wiki copy by native path but keeps unmatched QMD native identity', () async {
    final personal = _S07RecordingBackend()
      ..results = const [
        MemorySearchResult(
          text: 'duplicate',
          source: 'qmd://memory/wiki/falcon.md',
          score: -2,
          role: 'wiki',
          provenance: 'qmd',
          locator: 'qmd:/wiki/falcon.md',
        ),
        MemorySearchResult(
          text: 'uncited native result',
          source: 'qmd://memory/inbox/note.md',
          score: -1,
          role: 'knowledge-inbox',
          provenance: 'qmd',
          locator: 'qmd:/inbox/note.md',
        ),
        MemorySearchResult(
          text: 'unmatched wiki-shaped QMD result',
          source: 'qmd://memory/wiki/unmatched.md',
          score: 0,
          role: 'wiki',
          provenance: 'qmd',
          locator: 'qmd:/wiki/unmatched.md',
        ),
      ];
    final wiki = _RecordingWiki()
      ..results = const [
        MemorySearchResult(
          text: 'native wiki',
          source: 'wiki/falcon.md',
          score: -1000,
          role: 'wiki',
          provenance: 'human-authored',
          locator: 'wiki/falcon.md',
        ),
      ];

    final outcome = await ComposedSearchBackend(personal: personal, wiki: wiki).search('Falcon');

    expect(outcome.map((result) => result.locator), ['wiki/falcon.md', 'qmd:/inbox/note.md', 'qmd:/wiki/unmatched.md']);
    expect(outcome.last.entryId, isNull);
  });

  test('keeps healthy results and names each failed constituent once', () async {
    final wiki = _RecordingWiki()
      ..results = const [MemorySearchResult(text: 'wiki survives', source: 'wiki/falcon.md', score: -1, role: 'wiki')];
    final personalFailure = await ComposedSearchBackend(personal: _ThrowingBackend(), wiki: wiki).search('Falcon');
    final wikiFailure = await ComposedSearchBackend(
      personal: _S07RecordingBackend()
        ..results = const [MemorySearchResult(text: 'memory survives', source: 'id', score: 0, locator: 'id')],
      wiki: _RecordingWiki()..shouldThrow = true,
    ).search('Falcon');

    expect(personalFailure.single.text, 'wiki survives');
    expect(personalFailure.degradedLayers, ['memory']);
    expect(wikiFailure.single.text, 'memory survives');
    expect(wikiFailure.degradedLayers, ['wiki']);
  });

  test('propagates structured wiki degradation with healthy results', () async {
    final wiki = _RecordingWiki()
      ..results = const [MemorySearchResult(text: 'healthy', source: 'wiki/healthy.md', score: 0, role: 'wiki')]
      ..degradations = const [
        MemorySearchDegradation(
          layer: 'wiki',
          reason: 'sourceBytes',
          locator: 'wiki/oversized.md',
          observed: 65,
          limit: 64,
          omittedCount: 1,
        ),
      ];

    final outcome = await ComposedSearchBackend(personal: _S07RecordingBackend(), wiki: wiki).search('Falcon');

    expect(outcome.single.text, 'healthy');
    expect(outcome.degradations.single.locator, 'wiki/oversized.md');
  });

  test('applies a requested layer before output top-K', () async {
    final personal = _S07RecordingBackend()
      ..results = [
        for (var index = 0; index < 5; index++)
          MemorySearchResult(text: 'memory $index', source: 'memory-$index', score: index.toDouble()),
      ];
    final wiki = _RecordingWiki()
      ..results = [
        for (var index = 0; index < 5; index++)
          MemorySearchResult(text: 'wiki $index', source: 'wiki/$index.md', score: index - 10, role: 'wiki'),
      ];
    final backend = ComposedSearchBackend(personal: personal, wiki: wiki);

    final memoryOnly = await backend.search('Falcon', limit: 3, layers: const {SearchResultLayer.memory});
    final wikiOnly = await backend.search('Falcon', limit: 3, layers: const {SearchResultLayer.wiki});

    expect(memoryOnly, hasLength(3));
    expect(memoryOnly.every((result) => result.role != 'wiki'), isTrue);
    expect(memoryOnly.degradedLayers, isEmpty);
    expect(wikiOnly, hasLength(3));
    expect(wikiOnly.every((result) => result.role == 'wiki'), isTrue);
    expect(wiki.queries, ['Falcon']);
  });

  test('suppresses stale personal rows while retaining native wiki and canonical revision', () async {
    final personal = _S07RecordingBackend()
      ..results = const [MemorySearchResult(text: 'stale memory', source: 'memory-id', score: 0)];
    final wiki = _RecordingWiki()
      ..results = const [MemorySearchResult(text: 'wiki survives', source: 'wiki/falcon.md', score: -1, role: 'wiki')];
    final backend = ComposedSearchBackend(
      personal: personal,
      wiki: wiki,
      indexHealthProbe: () async => _health(IndexHealthState.degraded, 42, indexRevision: 41),
    );

    final outcome = await backend.search('Falcon');

    expect(personal.calls, isEmpty);
    expect(outcome.map((result) => result.text), ['wiki survives']);
    expect(outcome.canonicalRevision, 42);
    expect(outcome.degradedLayers, ['memory']);
    expect(outcome.degradations.single.reason, 'indexNotCurrent');
  });

  test('double-probe discards personal rows when canonical identity changes during query', () async {
    final personal = _S07RecordingBackend()
      ..results = const [MemorySearchResult(text: 'raced memory', source: 'memory-id', score: 0)];
    final wiki = _RecordingWiki()
      ..results = const [MemorySearchResult(text: 'wiki survives', source: 'wiki/falcon.md', score: -1, role: 'wiki')];
    final evidence = [_health(IndexHealthState.healthy, 41), _health(IndexHealthState.healthy, 42)].iterator;
    final backend = ComposedSearchBackend(
      personal: personal,
      wiki: wiki,
      indexHealthProbe: () async {
        evidence.moveNext();
        return evidence.current;
      },
    );

    final outcome = await backend.search('Falcon');

    expect(personal.calls, [('Falcon', 'owner')]);
    expect(outcome.map((result) => result.text), ['wiki survives']);
    expect(outcome.canonicalRevision, 42);
    expect(outcome.degradations.single.reason, 'indexChangedDuringSearch');
  });

  test('double-probe discards personal rows when health degrades during query', () async {
    final personal = _S07RecordingBackend()
      ..results = const [MemorySearchResult(text: 'unvalidated memory', source: 'memory-id', score: 0)];
    final wiki = _RecordingWiki()
      ..results = const [MemorySearchResult(text: 'wiki survives', source: 'wiki/falcon.md', score: -1, role: 'wiki')];
    final evidence = [_health(IndexHealthState.healthy, 41), _health(IndexHealthState.degraded, 41)].iterator;
    final backend = ComposedSearchBackend(
      personal: personal,
      wiki: wiki,
      indexHealthProbe: () async {
        evidence.moveNext();
        return evidence.current;
      },
    );

    final outcome = await backend.search('Falcon');

    expect(outcome.map((result) => result.text), ['wiki survives']);
    expect(outcome.canonicalRevision, 41);
    expect(outcome.degradations.single.reason, 'indexNotCurrent');
  });

  test('double-probe retains personal rows only across stable current evidence', () async {
    final personal = _S07RecordingBackend()
      ..results = const [MemorySearchResult(text: 'current memory', source: 'memory-id', score: 0)];
    var probes = 0;
    final backend = ComposedSearchBackend(
      personal: personal,
      wiki: _RecordingWiki(),
      indexHealthProbe: () async {
        probes++;
        return _health(IndexHealthState.healthy, 41);
      },
    );

    final outcome = await backend.search('Falcon');

    expect(probes, 2);
    expect(outcome.single.text, 'current memory');
    expect(outcome.canonicalRevision, 41);
    expect(outcome.degradedLayers, isEmpty);
  });
}

IndexHealthEvidence _health(IndexHealthState state, int revision, {int? indexRevision}) => IndexHealthEvidence(
  state: state,
  canonicalRevision: revision,
  canonicalFingerprint: 'fingerprint-$revision',
  indexRevision: indexRevision ?? revision,
  indexFingerprint: 'fingerprint-${indexRevision ?? revision}',
);

class _S07RecordingBackend implements SearchBackend {
  final calls = <(String, String)>[];
  List<MemorySearchResult> results = const [];

  @override
  Future<MemorySearchOutcome> search(
    String query, {
    int limit = 10,
    String userId = 'owner',
    Set<SearchResultLayer>? layers,
  }) async {
    calls.add((query, userId));
    return MemorySearchOutcome(results: results);
  }

  @override
  Future<MemorySearchResult?> resolve(String locator, {String userId = 'owner'}) async => null;

  @override
  Future<void> indexAfterWrite() async {}
}

final class _ThrowingBackend extends _S07RecordingBackend {
  @override
  Future<MemorySearchOutcome> search(
    String query, {
    int limit = 10,
    String userId = 'owner',
    Set<SearchResultLayer>? layers,
  }) => throw StateError('memory unavailable');
}

final class _RecordingWiki extends WikiSearchSource {
  _RecordingWiki() : super(workspaceDir: '.');

  final queries = <String>[];
  List<MemorySearchResult> results = const [];
  List<MemorySearchDegradation> degradations = const [];
  bool shouldThrow = false;

  @override
  Future<WikiSearchScan> searchScan(String query) async {
    queries.add(query);
    if (shouldThrow) throw StateError('wiki unavailable');
    return WikiSearchScan(results: results, degraded: degradations.isNotEmpty, degradations: degradations);
  }
}
