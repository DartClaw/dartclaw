import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../tool/retrieval_evaluation.dart';
import 'retrieval_evaluation_test_support.dart';

void main() {
  late String repositoryRoot;

  setUpAll(() async {
    repositoryRoot = await resolveRetrievalEvaluationRepositoryRoot();
  });

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

  test('mixed slices expose positive and expected-empty denominators independently', () {
    final queries = _queries();
    final observations = _observations(queries);

    final rows = buildSliceRows(queries, observations);

    expect(rows, hasLength(144));
    final mixed = rows.firstWhere(
      (row) =>
          row.backend == 'sqlite' &&
          row.mode == 'keyword' &&
          row.corpus == 'memory' &&
          row.language == 'en' &&
          row.family == 'answer-absent',
    );
    expect((mixed.queryCount, mixed.positiveQueryCount, mixed.expectedEmptyQueryCount), (3, 2, 1));
    expect((mixed.hitAt1, mixed.recallAt5, mixed.precisionAt5, mixed.mrrAt5), (1.0, 1.0, 1.0, 1.0));
    expect(mixed.correctEmptyRate, 1);
    expect(mixed.emptyResultRate, closeTo(1 / 3, 1e-12));

    final diagnosticOnly = rows.firstWhere(
      (row) =>
          row.backend == 'sqlite' &&
          row.mode == 'keyword' &&
          row.corpus == 'conversation' &&
          row.language == 'en' &&
          row.family == 'answer-absent',
    );
    expect((diagnosticOnly.positiveQueryCount, diagnosticOnly.expectedEmptyQueryCount), (0, 0));
    expect(diagnosticOnly.hitAt1, isNull);
    expect(diagnosticOnly.recallAt5, isNull);
    expect(diagnosticOnly.precisionAt5, isNull);
    expect(diagnosticOnly.mrrAt5, isNull);
    expect(diagnosticOnly.correctEmptyRate, isNull);
    expect(diagnosticOnly.emptyResultRate, 1);
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
    final noMatch = gates.singleWhere((row) => row.id == 'no-match/sqlite/keyword');
    expect((noMatch.observed, noMatch.threshold, noMatch.passed), (1, 1, true));
  });

  test('answer absence does not force empty while an explicit no-match hit fails', () {
    final queries = _queries();
    final allowed = buildGateRows(queries, _observations(queries, unlabeledReturn: true));
    expect(allowed.where((row) => !row.passed), isEmpty);

    final failures = {
      for (final row in buildGateRows(
        queries,
        _observations(queries, noMatchFailure: true),
      ).where((row) => !row.passed))
        row.id,
    };
    expect(failures, contains('no-match/sqlite/keyword'));
  });

  test('equality lift, beyond-tolerance loss, and leaks fail independently', () {
    final queries = _queries();
    final observations = _observations(
      queries,
      vocabularyLift: false,
      exactHybridMisses: 2,
      foreignOwnerCount: 1,
      wrongCorpusCount: 1,
    );

    final failures = {for (final row in buildGateRows(queries, observations).where((row) => !row.passed)) row.id};

    expect(failures, contains('vocabulary-lift/sqlite/memory/hitAt1'));
    expect(failures, contains('family-regression/sqlite/all/exact-keyword/hitAt1'));
    expect(failures, contains('corpus-family-regression/sqlite/memory/exact-keyword/hitAt1'));
    expect(failures, contains('owner-isolation/sqlite/keyword'));
    expect(failures, contains('corpus-isolation/sqlite/keyword'));
  });

  test('version 2 fixture preserves historical assets and loads explicit no-match semantics', () {
    final fixture = RetrievalAssetBundle(p.join(repositoryRoot, 'dev/testing/retrieval')).verifyAndLoad();

    expect((fixture.documents.length, fixture.queries.length), (32, 60));
    expect(fixture.queries.where((query) => query.expectEmpty).map((query) => query.id), ['q54']);
    expect(fixture.queries.singleWhere((query) => query.id == 'q51').relevantDocumentIds, {'m01'});
    expect(fixture.queries.singleWhere((query) => query.id == 'q56').relevantDocumentIds, isEmpty);
    expect(fixture.queries.singleWhere((query) => query.id == 'q56').expectEmpty, isFalse);
  });

  test('external fixture requires matching bytes and the existing schema', () {
    final root = Directory.systemTemp.createTempSync('retrieval_external_fixture_');
    addTearDown(() => root.deleteSync(recursive: true));
    final source = File(p.join(repositoryRoot, 'dev/testing/retrieval/retrieval-v2.json'));
    final fixtureFile = File(p.join(root.path, 'fixture.json'))..writeAsBytesSync(source.readAsBytesSync());
    final fixtureHash = sha256.convert(fixtureFile.readAsBytesSync()).toString();
    final assets = RetrievalAssetBundle(p.join(repositoryRoot, 'dev/testing/retrieval'));

    final fixture = assets.verifyAndLoad(fixturePath: fixtureFile.path, fixtureSha256: fixtureHash);
    expect((fixture.documents.length, fixture.queries.length), (32, 60));
    expect(fixture.settings['rrfK'], 60);

    fixtureFile.writeAsStringSync('${fixtureFile.readAsStringSync()}\n');
    expect(
      () => assets.verifyAndLoad(fixturePath: fixtureFile.path, fixtureSha256: fixtureHash),
      throwsA(isA<FormatException>()),
    );

    final invalidSchema = jsonDecode(source.readAsStringSync()) as Map<String, dynamic>;
    invalidSchema['protocolVersion'] = 3;
    fixtureFile.writeAsStringSync(jsonEncode(invalidSchema));
    final invalidSchemaHash = sha256.convert(fixtureFile.readAsBytesSync()).toString();
    expect(
      () => assets.verifyAndLoad(fixturePath: fixtureFile.path, fixtureSha256: invalidSchemaHash),
      throwsA(isA<FormatException>()),
    );
  });

  test('fixture rejects missing booleans, malformed labels, unknown IDs, and contradictory no-match labels', () {
    final source = jsonDecode(
      File(p.join(repositoryRoot, 'dev/testing/retrieval/retrieval-v2.json')).readAsStringSync(),
    );

    final missingBool = _copyFixture(source);
    (missingBool['queries']! as List<dynamic>).first.remove('expectEmpty');
    expect(() => parseRetrievalFixture(missingBool), throwsA(isA<FormatException>()));

    final malformedLabels = _copyFixture(source);
    (malformedLabels['queries']! as List<dynamic>).first['relevantDocumentIds'] = 'm01';
    expect(() => parseRetrievalFixture(malformedLabels), throwsA(isA<FormatException>()));

    final emptyPositiveLabels = _copyFixture(source);
    (emptyPositiveLabels['queries']! as List<dynamic>).first['relevantDocumentIds'] = <String>[];
    expect(() => parseRetrievalFixture(emptyPositiveLabels), throwsA(isA<FormatException>()));

    final unknownId = _copyFixture(source);
    (unknownId['queries']! as List<dynamic>).first['relevantDocumentIds'] = ['missing'];
    expect(() => parseRetrievalFixture(unknownId), throwsA(isA<FormatException>()));

    final contradictoryNoMatch = _copyFixture(source);
    final q54 = (contradictoryNoMatch['queries']! as List<dynamic>).singleWhere((query) => query['id'] == 'q54');
    q54['relevantDocumentIds'] = ['m01'];
    expect(() => parseRetrievalFixture(contradictoryNoMatch), throwsA(isA<FormatException>()));

    final noNoMatch = _copyFixture(source);
    for (final query in noNoMatch['queries']! as List<dynamic>) {
      query['expectEmpty'] = false;
    }
    expect(() => parseRetrievalFixture(noNoMatch), throwsA(isA<FormatException>()));
  });
}

Map<String, dynamic> _copyFixture(Object? source) => jsonDecode(jsonEncode(source)) as Map<String, dynamic>;

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
        relevantDocumentIds: family != 'answer-absent' || (index >= 1 && index <= 5)
            ? {for (var relevant = 0; relevant < 5; relevant++) '$family-$index-result-$relevant'}
            : const {},
        expectEmpty: family == 'answer-absent' && index == 0,
      ),
];

List<RankingObservation> _observations(
  List<EvaluationQuery> queries, {
  bool vocabularyLift = true,
  int exactHybridMisses = 1,
  bool noMatchFailure = false,
  bool unlabeledReturn = false,
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
            noMatchFailure: noMatchFailure && backend == 'sqlite' && mode == 'keyword',
            unlabeledReturn: unlabeledReturn,
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
  required bool noMatchFailure,
  required bool unlabeledReturn,
}) {
  if (query.expectEmpty) return noMatchFailure ? ['unexpected'] : const [];
  if (query.relevantDocumentIds.isEmpty) return unlabeledReturn ? ['diagnostic-context'] : const [];
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
  expectEmpty: false,
);
