import 'package:test/test.dart';

import '../../tool/retrieval_evaluation.dart';

void main() {
  test('positive metrics use unique documents, a fixed precision denominator, and supplied order', () {
    final query = _query('q', relevant: {'a', 'b'});

    final metrics = calculatePositiveMetrics(query, ['x', 'a', 'a', 'b']);

    expect(metrics.hitAt1, 0);
    expect(metrics.recallAt5, 1);
    expect(metrics.precisionAt5, 0.4);
    expect(metrics.mrrAt5, 0.5);
    expect(normalizeDocumentRanking(['z', 'a', 'z', 'b']), ['z', 'a', 'b']);
  });

  test('nearest-rank p95 selects from raw microseconds without interpolation', () {
    expect(nearestRankP95([for (var value = 1; value <= 20; value++) value * 1000]), 19);
    expect(nearestRankP95([1001, 1002]), 1.002);
  });

  test('slice matrix is complete and no-result metrics remain null', () {
    final queries = _queries();
    final observations = _observations(queries);

    final rows = buildSliceRows(queries, observations);

    expect(rows, hasLength(144));
    final noResult = rows.firstWhere(
      (row) =>
          row.backend == 'sqlite' &&
          row.mode == 'keyword' &&
          row.corpus == 'memory' &&
          row.language == 'en' &&
          row.family == 'no-result',
    );
    expect(noResult.hitAt1, isNull);
    expect(noResult.recallAt5, isNull);
    expect(noResult.precisionAt5, isNull);
    expect(noResult.mrrAt5, isNull);
    expect(noResult.correctEmptyRate, 1);
  });

  test('strict lift and exact family and corpus tolerance boundaries pass', () {
    final queries = _queries();
    final gates = buildGateRows(queries, _observations(queries));

    expect(gates, hasLength(122));
    expect(gates.where((row) => !row.passed), isEmpty);
    expect(
      gates.singleWhere((row) => row.id == 'family-regression/sqlite/all/exact-keyword/hitAt1').observed,
      closeTo(0.10, 1e-12),
    );
    expect(
      gates.singleWhere((row) => row.id == 'corpus-family-regression/sqlite/memory/exact-keyword/hitAt1').observed,
      closeTo(0.20, 1e-12),
    );
  });

  test('equality lift, beyond-tolerance loss, no-result hit, and leaks fail independently', () {
    final queries = _queries();
    final observations = _observations(
      queries,
      vocabularyLift: false,
      exactHybridMisses: 2,
      noResultFailure: true,
      foreignOwnerCount: 1,
      wrongCorpusCount: 1,
    );

    final failures = {for (final row in buildGateRows(queries, observations).where((row) => !row.passed)) row.id};

    expect(failures, contains('vocabulary-lift/sqlite/memory/hitAt1'));
    expect(failures, contains('family-regression/sqlite/all/exact-keyword/hitAt1'));
    expect(failures, contains('corpus-family-regression/sqlite/memory/exact-keyword/hitAt1'));
    expect(failures, contains('no-result/sqlite/keyword'));
    expect(failures, contains('owner-isolation/sqlite/keyword'));
    expect(failures, contains('corpus-isolation/sqlite/keyword'));
  });
}

List<EvaluationQuery> _queries() => [
  for (final family in evaluationFamilies)
    for (var index = 0; index < 10; index++)
      EvaluationQuery(
        id: '$family-$index',
        tenant: 'literal-owner',
        corpus: index < 5 ? 'memory' : 'conversation',
        language: index.isEven ? 'en' : 'sv',
        family: family,
        text: 'literal query $index',
        relevantDocumentIds: family == 'no-result'
            ? const {}
            : {for (var relevant = 0; relevant < 5; relevant++) '$family-$index-result-$relevant'},
      ),
];

List<RankingObservation> _observations(
  List<EvaluationQuery> queries, {
  bool vocabularyLift = true,
  int exactHybridMisses = 1,
  bool noResultFailure = false,
  int foreignOwnerCount = 0,
  int wrongCorpusCount = 0,
}) => [
  for (final backend in evaluationBackends)
    for (final mode in evaluationModes)
      for (final query in queries)
        RankingObservation(
          backend: backend,
          mode: mode,
          query: query,
          documentIds: _ranking(
            query,
            mode,
            vocabularyLift: vocabularyLift,
            exactHybridMisses: exactHybridMisses,
            noResultFailure: noResultFailure && backend == 'sqlite' && mode == 'keyword',
          ),
          warmMicros: 1000 + query.id.length,
          foreignOwnerCount: backend == 'sqlite' && mode == 'keyword' && query.id == 'exact-keyword-0'
              ? foreignOwnerCount
              : 0,
          wrongCorpusCount: backend == 'sqlite' && mode == 'keyword' && query.id == 'exact-keyword-0'
              ? wrongCorpusCount
              : 0,
        ),
];

Iterable<String> _ranking(
  EvaluationQuery query,
  String mode, {
  required bool vocabularyLift,
  required int exactHybridMisses,
  required bool noResultFailure,
}) {
  if (query.family == 'no-result') return noResultFailure && query.id.endsWith('-0') ? ['unexpected'] : const [];
  if (query.family == 'vocabulary-mismatch') {
    if (mode == 'keyword' || (mode == 'hybrid' && !vocabularyLift)) return const [];
    return query.relevantDocumentIds;
  }
  if (query.family == 'exact-keyword' && mode == 'hybrid') {
    final index = int.parse(query.id.split('-').last);
    if (index < exactHybridMisses) return const [];
  }
  return query.relevantDocumentIds;
}

EvaluationQuery _query(String id, {required Set<String> relevant}) => EvaluationQuery(
  id: id,
  tenant: 'literal-owner',
  corpus: 'memory',
  language: 'en',
  family: 'exact-keyword',
  text: 'literal',
  relevantDocumentIds: relevant,
);
