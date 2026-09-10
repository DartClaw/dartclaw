import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

const evaluationBackends = ['sqlite', 'postgresql'];
const evaluationModes = ['keyword', 'vector', 'hybrid'];
const evaluationCorpora = ['memory', 'conversation'];
const evaluationLanguages = ['en', 'sv'];
const evaluationFamilies = [
  'exact-keyword',
  'vocabulary-mismatch',
  'named-entity',
  'temporal',
  'relational',
  'answer-absent',
];
const positiveComparisonFamilies = ['exact-keyword', 'named-entity', 'temporal', 'relational'];

const historicalHeldoutSha256 = '2635bb02da1f8dddd67e9b9f22795cc32dbee34588d642b573bdf00b8ec7b9a3';
const retrievalV2Sha256 = '3136f0d76532ebaffefa729173e2cb2c6d4b96e348fcf661a59840a4e28a8d42';
const selectedSettingsSha256 = '32bf711292532f51313404072d61ff6443660a5c578cd0095574de94a8303a1a';
const calibrationNegativesSha256 = '2df62c960c83ffe5485f81ae22ec63acd0ddf6f54292e52837f1531edd08bb46';
const calibrationSummarySha256 = '2c360ad1802a116e54ed4c3b020344bc179615fe71952d48dfb4c3eefb5ff97a';
const calibrationFixtureSha256 = '79cb7e157df009a74096c853cd70ededcecbefc5ac0a89ac928ad2923d3d8148';

final class EvaluationDocument {
  const new({required this.id, required this.tenant, required this.corpus, required this.language, required this.text});

  final String id;
  final String tenant;
  final String corpus;
  final String language;
  final String text;
}

final class EvaluationQuery {
  const new({
    required this.id,
    required this.tenant,
    required this.corpus,
    required this.language,
    required this.family,
    required this.text,
    required this.relevantDocumentIds,
    required this.expectEmpty,
  });

  final String id;
  final String tenant;
  final String corpus;
  final String language;
  final String family;
  final String text;
  final Set<String> relevantDocumentIds;
  final bool expectEmpty;
}

final class RetrievalFixture {
  const new({required this.documents, required this.queries, required this.settings});

  final List<EvaluationDocument> documents;
  final List<EvaluationQuery> queries;
  final Map<String, Object?> settings;
}

final class RankingObservation {
  new({
    required this.backend,
    required this.mode,
    required this.query,
    required Iterable<String> documentIds,
    required this.warmMicros,
    this.foreignOwnerCount = 0,
    this.wrongCorpusCount = 0,
  }) : documentIds = List.unmodifiable(normalizeDocumentRanking(documentIds)) {
    if (!evaluationBackends.contains(backend)) throw ArgumentError.value(backend, 'backend');
    if (!evaluationModes.contains(mode)) throw ArgumentError.value(mode, 'mode');
    if (warmMicros < 0) throw ArgumentError.value(warmMicros, 'warmMicros');
    if (foreignOwnerCount < 0) throw ArgumentError.value(foreignOwnerCount, 'foreignOwnerCount');
    if (wrongCorpusCount < 0) throw ArgumentError.value(wrongCorpusCount, 'wrongCorpusCount');
  }

  final String backend;
  final String mode;
  final EvaluationQuery query;
  final List<String> documentIds;
  final int warmMicros;
  final int foreignOwnerCount;
  final int wrongCorpusCount;
}

List<String> normalizeDocumentRanking(Iterable<String> documentIds) {
  final seen = <String>{};
  return [
    for (final id in documentIds)
      if (seen.add(id)) id,
  ];
}

final class QueryMetrics {
  const new({required this.hitAt1, required this.recallAt5, required this.precisionAt5, required this.mrrAt5});

  final double hitAt1;
  final double recallAt5;
  final double precisionAt5;
  final double mrrAt5;
}

QueryMetrics calculatePositiveMetrics(EvaluationQuery query, Iterable<String> suppliedRanking) {
  if (query.relevantDocumentIds.isEmpty) {
    throw ArgumentError.value(query.id, 'query', 'positive metrics require at least one relevant document');
  }
  final ranking = normalizeDocumentRanking(suppliedRanking).take(5).toList(growable: false);
  final relevant = ranking.where(query.relevantDocumentIds.contains).length;
  final first = ranking.indexWhere(query.relevantDocumentIds.contains);
  return QueryMetrics(
    hitAt1: ranking.isNotEmpty && query.relevantDocumentIds.contains(ranking.first) ? 1 : 0,
    recallAt5: relevant / query.relevantDocumentIds.length,
    precisionAt5: relevant / 5,
    mrrAt5: first < 0 ? 0 : 1 / (first + 1),
  );
}

double nearestRankP95(Iterable<int> samplesMicros) {
  final samples = samplesMicros.toList(growable: false)..sort();
  if (samples.isEmpty) throw ArgumentError.value(samplesMicros, 'samplesMicros', 'must not be empty');
  final index = math.max(0, (samples.length * 0.95).ceil() - 1);
  return samples[index] / 1000;
}

final class SliceRow {
  const new({
    required this.backend,
    required this.mode,
    required this.corpus,
    required this.language,
    required this.family,
    required this.queryCount,
    required this.positiveQueryCount,
    required this.expectedEmptyQueryCount,
    required this.hitAt1,
    required this.recallAt5,
    required this.precisionAt5,
    required this.mrrAt5,
    required this.correctEmptyRate,
    required this.emptyResultRate,
    required this.warmP95Ms,
  });

  final String backend;
  final String mode;
  final String corpus;
  final String language;
  final String family;
  final int queryCount;
  final int positiveQueryCount;
  final int expectedEmptyQueryCount;
  final double? hitAt1;
  final double? recallAt5;
  final double? precisionAt5;
  final double? mrrAt5;
  final double? correctEmptyRate;
  final double emptyResultRate;
  final double warmP95Ms;

  Map<String, Object?> toJson() => {
    'backend': backend,
    'mode': mode,
    'corpus': corpus,
    'language': language,
    'family': family,
    'queryCount': queryCount,
    'positiveQueryCount': positiveQueryCount,
    'expectedEmptyQueryCount': expectedEmptyQueryCount,
    'hitAt1': _rounded(hitAt1),
    'recallAt5': _rounded(recallAt5),
    'precisionAt5': _rounded(precisionAt5),
    'mrrAt5': _rounded(mrrAt5),
    'correctEmptyRate': _rounded(correctEmptyRate),
    'emptyResultRate': _rounded(emptyResultRate),
    'warmP95Ms': _rounded(warmP95Ms),
  };
}

List<SliceRow> buildSliceRows(List<EvaluationQuery> queries, List<RankingObservation> observations) {
  _validateObservationMatrix(queries, observations);
  final rows = <SliceRow>[];
  for (final backend in evaluationBackends) {
    for (final mode in evaluationModes) {
      for (final corpus in evaluationCorpora) {
        for (final language in evaluationLanguages) {
          for (final family in evaluationFamilies) {
            final selected = observations
                .where(
                  (item) =>
                      item.backend == backend &&
                      item.mode == mode &&
                      item.query.corpus == corpus &&
                      item.query.language == language &&
                      item.query.family == family,
                )
                .toList(growable: false);
            if (selected.isEmpty) {
              throw StateError('evaluation slice is incomplete: $backend/$mode/$corpus/$language/$family');
            }
            final positives = selected
                .where((item) => item.query.relevantDocumentIds.isNotEmpty)
                .toList(growable: false);
            final expectedEmpty = selected.where((item) => item.query.expectEmpty).toList(growable: false);
            final metrics = positives
                .map((item) => calculatePositiveMetrics(item.query, item.documentIds))
                .toList(growable: false);
            rows.add(
              SliceRow(
                backend: backend,
                mode: mode,
                corpus: corpus,
                language: language,
                family: family,
                queryCount: selected.length,
                positiveQueryCount: positives.length,
                expectedEmptyQueryCount: expectedEmpty.length,
                hitAt1: metrics.isEmpty ? null : _mean(metrics.map((item) => item.hitAt1)),
                recallAt5: metrics.isEmpty ? null : _mean(metrics.map((item) => item.recallAt5)),
                precisionAt5: metrics.isEmpty ? null : _mean(metrics.map((item) => item.precisionAt5)),
                mrrAt5: metrics.isEmpty ? null : _mean(metrics.map((item) => item.mrrAt5)),
                correctEmptyRate: expectedEmpty.isEmpty
                    ? null
                    : _mean(expectedEmpty.map((item) => item.documentIds.isEmpty ? 1 : 0)),
                emptyResultRate: _mean(selected.map((item) => item.documentIds.isEmpty ? 1 : 0)),
                warmP95Ms: nearestRankP95(selected.map((item) => item.warmMicros)),
              ),
            );
          }
        }
      }
    }
  }
  if (rows.length != 144) throw StateError('evaluation slice matrix must contain 144 rows');
  return List.unmodifiable(rows);
}

final class GateRow {
  const new({
    required this.id,
    required this.backend,
    this.mode,
    this.corpus,
    this.family,
    this.metric,
    required this.observed,
    required this.threshold,
    required this.comparison,
    required this.passed,
    this.hybridValue,
    this.referenceValue,
  });

  final String id;
  final String backend;
  final String? mode;
  final String? corpus;
  final String? family;
  final String? metric;
  final double observed;
  final double threshold;
  final String comparison;
  final bool passed;
  final double? hybridValue;
  final double? referenceValue;

  Map<String, Object?> toJson() => {
    'id': id,
    'backend': backend,
    if (mode != null) 'mode': mode,
    if (corpus != null) 'corpus': corpus,
    if (family != null) 'family': family,
    if (metric != null) 'metric': metric,
    'observed': _rounded(observed),
    'threshold': threshold,
    'comparison': comparison,
    'passed': passed,
    if (hybridValue != null) 'hybridValue': _rounded(hybridValue),
    if (referenceValue != null) 'referenceValue': _rounded(referenceValue),
  };
}

List<GateRow> buildGateRows(List<EvaluationQuery> queries, List<RankingObservation> observations) {
  _validateObservationMatrix(queries, observations);
  final rows = <GateRow>[];
  for (final backend in evaluationBackends) {
    for (final corpus in evaluationCorpora) {
      for (final metric in ['hitAt1', 'mrrAt5']) {
        final keyword = _aggregateMetric(
          observations,
          backend,
          'keyword',
          'vocabulary-mismatch',
          metric,
          corpus: corpus,
        );
        final hybrid = _aggregateMetric(observations, backend, 'hybrid', 'vocabulary-mismatch', metric, corpus: corpus);
        final lift = hybrid - keyword;
        rows.add(
          GateRow(
            id: 'vocabulary-lift/$backend/$corpus/$metric',
            backend: backend,
            corpus: corpus,
            family: 'vocabulary-mismatch',
            metric: metric,
            observed: lift,
            threshold: 0,
            comparison: 'greaterThan',
            passed: lift > 0,
            hybridValue: hybrid,
            referenceValue: keyword,
          ),
        );
      }
    }
    for (final family in positiveComparisonFamilies) {
      for (final metric in ['hitAt1', 'recallAt5', 'precisionAt5', 'mrrAt5']) {
        rows.add(_regressionGate(observations, backend, family, metric, tolerance: 0.10));
      }
      for (final corpus in evaluationCorpora) {
        for (final metric in ['hitAt1', 'recallAt5', 'precisionAt5', 'mrrAt5']) {
          rows.add(_regressionGate(observations, backend, family, metric, corpus: corpus, tolerance: 0.20));
        }
      }
    }
    for (final mode in evaluationModes) {
      final noMatches = observations
          .where((item) => item.backend == backend && item.mode == mode && item.query.expectEmpty)
          .toList(growable: false);
      final emptyCount = noMatches.where((item) => item.documentIds.isEmpty).length;
      rows.add(
        GateRow(
          id: 'no-match/$backend/$mode',
          backend: backend,
          mode: mode,
          family: 'answer-absent',
          observed: emptyCount.toDouble(),
          threshold: noMatches.length.toDouble(),
          comparison: 'equalTo',
          passed: emptyCount == noMatches.length,
        ),
      );
      final modeRows = observations.where((item) => item.backend == backend && item.mode == mode);
      final foreignOwners = modeRows.fold<int>(0, (total, item) => total + item.foreignOwnerCount);
      final wrongCorpora = modeRows.fold<int>(0, (total, item) => total + item.wrongCorpusCount);
      rows.add(
        GateRow(
          id: 'owner-isolation/$backend/$mode',
          backend: backend,
          mode: mode,
          observed: foreignOwners.toDouble(),
          threshold: 0,
          comparison: 'equalTo',
          passed: foreignOwners == 0,
        ),
      );
      rows.add(
        GateRow(
          id: 'corpus-isolation/$backend/$mode',
          backend: backend,
          mode: mode,
          observed: wrongCorpora.toDouble(),
          threshold: 0,
          comparison: 'equalTo',
          passed: wrongCorpora == 0,
        ),
      );
    }
  }
  if (rows.length != 122) throw StateError('evaluation gate matrix must contain 122 rows');
  return List.unmodifiable(rows);
}

GateRow _regressionGate(
  List<RankingObservation> observations,
  String backend,
  String family,
  String metric, {
  String? corpus,
  required double tolerance,
}) {
  final keyword = _aggregateMetric(observations, backend, 'keyword', family, metric, corpus: corpus);
  final vector = _aggregateMetric(observations, backend, 'vector', family, metric, corpus: corpus);
  final hybrid = _aggregateMetric(observations, backend, 'hybrid', family, metric, corpus: corpus);
  final lag = math.max(keyword, vector) - hybrid;
  final scope = corpus == null ? 'family' : 'corpus-family';
  return GateRow(
    id: '$scope-regression/$backend/${corpus ?? 'all'}/$family/$metric',
    backend: backend,
    corpus: corpus,
    family: family,
    metric: metric,
    observed: lag,
    threshold: tolerance,
    comparison: 'lessThanOrEqualTo',
    passed: lag <= tolerance + 1e-12,
    hybridValue: hybrid,
    referenceValue: math.max(keyword, vector),
  );
}

double _aggregateMetric(
  List<RankingObservation> observations,
  String backend,
  String mode,
  String family,
  String metric, {
  String? corpus,
}) {
  final selected = observations.where(
    (item) =>
        item.backend == backend &&
        item.mode == mode &&
        item.query.family == family &&
        (corpus == null || item.query.corpus == corpus),
  );
  final values = selected
      .map((item) {
        final value = calculatePositiveMetrics(item.query, item.documentIds);
        return switch (metric) {
          'hitAt1' => value.hitAt1,
          'recallAt5' => value.recallAt5,
          'precisionAt5' => value.precisionAt5,
          'mrrAt5' => value.mrrAt5,
          _ => throw ArgumentError.value(metric, 'metric'),
        };
      })
      .toList(growable: false);
  if (values.isEmpty) throw StateError('quality gate input is incomplete');
  return _mean(values);
}

void _validateObservationMatrix(List<EvaluationQuery> queries, List<RankingObservation> observations) {
  final queriesById = {for (final query in queries) query.id: query};
  if (queriesById.length != queries.length) throw StateError('evaluation query IDs must be unique');
  if (!queries.any((query) => query.expectEmpty)) throw StateError('evaluation requires at least one no-match query');
  final keys = <String>{};
  for (final item in observations) {
    final expectedQuery = queriesById[item.query.id];
    if (expectedQuery == null) throw StateError('observation references an unknown query');
    if (item.query.tenant != expectedQuery.tenant ||
        item.query.corpus != expectedQuery.corpus ||
        item.query.language != expectedQuery.language ||
        item.query.family != expectedQuery.family ||
        item.query.text != expectedQuery.text ||
        item.query.expectEmpty != expectedQuery.expectEmpty ||
        !_sameSet(item.query.relevantDocumentIds, expectedQuery.relevantDocumentIds)) {
      throw StateError('observation query dimensions do not match the fixture: ${item.query.id}');
    }
    final key = '${item.backend}/${item.mode}/${item.query.id}';
    if (!keys.add(key)) throw StateError('duplicate evaluation observation: $key');
  }
  final expected = evaluationBackends.length * evaluationModes.length * queries.length;
  if (observations.length != expected) {
    throw StateError('evaluation observation matrix is incomplete: ${observations.length} of $expected');
  }
}

final class RetrievalAssetBundle {
  const new(this.directory);

  final String directory;

  RetrievalFixture verifyAndLoad({String? fixturePath, String? fixtureSha256}) {
    if ((fixturePath == null) != (fixtureSha256 == null)) {
      throw const FormatException('External retrieval fixture path and hash are required together');
    }
    final expected = <String, String>{
      'calibration-fixture.dart.txt': calibrationFixtureSha256,
      'calibration-negatives.json': calibrationNegativesSha256,
      'calibration-summary.md': calibrationSummarySha256,
      'selected-settings.json': selectedSettingsSha256,
      'heldout.json': historicalHeldoutSha256,
      'retrieval-v2.json': retrievalV2Sha256,
    };
    for (final entry in expected.entries) {
      final file = File(p.join(directory, entry.key));
      if (FileSystemEntity.typeSync(file.path, followLinks: false) != FileSystemEntityType.file) {
        throw FormatException('Retrieval evaluation asset is missing: ${entry.key}');
      }
      final actual = sha256.convert(file.readAsBytesSync()).toString();
      if (actual != entry.value) throw FormatException('Retrieval evaluation asset hash mismatch: ${entry.key}');
    }

    final historical = File(p.join(directory, 'calibration-fixture.dart.txt')).readAsStringSync();
    if (RegExp(r"\bDoc\('d\d\d'").allMatches(historical).length != 24 ||
        RegExp(r"\bQuery\('q\d\d'").allMatches(historical).length != 16) {
      throw const FormatException('Historical calibration fixture shape is invalid');
    }
    final negatives = jsonDecode(File(p.join(directory, 'calibration-negatives.json')).readAsStringSync());
    if (negatives is! List ||
        negatives.length != 10 ||
        negatives.any((item) => item is! Map || item['expected'] is! List || (item['expected'] as List).isNotEmpty)) {
      throw const FormatException('Calibration negative fixture shape is invalid');
    }
    final settings = _jsonObject(File(p.join(directory, 'selected-settings.json')));
    _expectSetting(settings, 'rrfK', 60);
    _expectSetting(settings, 'keywordWeight', 0.25);
    _expectSetting(settings, 'vectorWeight', 0.75);
    _expectSetting(settings, 'minimumCosine', 0.2);
    _expectSetting(settings, 'candidateLimit', 20);
    _expectSetting(settings, 'evaluationTopK', 5);
    _expectSetting(settings, 'heldOutSha256', historicalHeldoutSha256);
    _expectSetting(settings, 'calibrationNegativesSha256', calibrationNegativesSha256);

    final String fixtureJson;
    if (fixturePath != null) {
      final fixtureFile = File(fixturePath);
      if (FileSystemEntity.typeSync(fixtureFile.path, followLinks: false) != FileSystemEntityType.file) {
        throw const FormatException('External retrieval fixture is missing');
      }
      final bytes = fixtureFile.readAsBytesSync();
      final actual = sha256.convert(bytes).toString();
      if (actual != fixtureSha256) throw const FormatException('External retrieval fixture hash mismatch');
      fixtureJson = utf8.decode(bytes);
    } else {
      fixtureJson = File(p.join(directory, 'retrieval-v2.json')).readAsStringSync();
    }
    final fixture = parseRetrievalFixture(jsonDecode(fixtureJson));
    return RetrievalFixture(
      documents: fixture.documents,
      queries: fixture.queries,
      settings: Map.unmodifiable(settings),
    );
  }
}

RetrievalFixture parseRetrievalFixture(Object? value) {
  if (value is! Map<String, dynamic> || value['protocolVersion'] != 2) {
    throw const FormatException('Retrieval fixture protocol version is invalid');
  }
  final rawDocuments = value['documents'];
  final rawQueries = value['queries'];
  if (rawDocuments is! List || rawDocuments.length != 32 || rawQueries is! List || rawQueries.length != 60) {
    throw const FormatException('Retrieval fixture count is invalid');
  }
  final documents = rawDocuments.map(_parseDocument).toList(growable: false);
  final queries = rawQueries.map(_parseQuery).toList(growable: false);
  _validateFixtureShape(documents, queries);
  return RetrievalFixture(
    documents: List.unmodifiable(documents),
    queries: List.unmodifiable(queries),
    settings: const {},
  );
}

Map<String, Object?> _jsonObject(File file) {
  final value = jsonDecode(file.readAsStringSync());
  if (value is! Map<String, dynamic>) throw FormatException('Invalid JSON object: ${p.basename(file.path)}');
  return Map<String, Object?>.from(value);
}

EvaluationDocument _parseDocument(Object? value) {
  if (value is! Map<String, dynamic>) throw const FormatException('Retrieval document shape is invalid');
  return EvaluationDocument(
    id: _requiredString(value, 'id'),
    tenant: _requiredString(value, 'tenant'),
    corpus: _requiredString(value, 'corpus'),
    language: _requiredString(value, 'language'),
    text: _requiredString(value, 'text'),
  );
}

EvaluationQuery _parseQuery(Object? value) {
  if (value is! Map<String, dynamic>) throw const FormatException('Retrieval query shape is invalid');
  final relevant = value['relevantDocumentIds'];
  final expectEmpty = value['expectEmpty'];
  if (relevant is! List || relevant.any((item) => item is! String || item.isEmpty)) {
    throw const FormatException('Retrieval relevance shape is invalid');
  }
  if (expectEmpty is! bool) throw const FormatException('Retrieval expectEmpty is invalid');
  return EvaluationQuery(
    id: _requiredString(value, 'id'),
    tenant: _requiredString(value, 'tenant'),
    corpus: _requiredString(value, 'corpus'),
    language: _requiredString(value, 'language'),
    family: _requiredString(value, 'family'),
    text: _requiredString(value, 'query'),
    relevantDocumentIds: Set.unmodifiable(relevant.cast<String>()),
    expectEmpty: expectEmpty,
  );
}

String _requiredString(Map<String, dynamic> value, String key) {
  final selected = value[key];
  if (selected is! String || selected.isEmpty) throw FormatException('Retrieval $key is invalid');
  return selected;
}

void _validateFixtureShape(List<EvaluationDocument> documents, List<EvaluationQuery> queries) {
  final documentIds = documents.map((item) => item.id).toSet();
  final queryIds = queries.map((item) => item.id).toSet();
  if (documentIds.length != 32 || queryIds.length != 60) {
    throw const FormatException('Retrieval identities are invalid');
  }
  if (documents.any(
        (item) =>
            !evaluationCorpora.contains(item.corpus) ||
            !evaluationLanguages.contains(item.language) ||
            !const {'fixture-owner', 'other-owner'}.contains(item.tenant),
      ) ||
      queries.any(
        (item) =>
            !evaluationCorpora.contains(item.corpus) ||
            !evaluationLanguages.contains(item.language) ||
            !evaluationFamilies.contains(item.family) ||
            item.tenant != 'fixture-owner',
      )) {
    throw const FormatException('Retrieval dimensions are invalid');
  }
  if (documents.where((item) => item.tenant == 'fixture-owner').length != 30 ||
      documents.where((item) => item.tenant == 'other-owner').length != 2) {
    throw const FormatException('Retrieval owner fixtures are invalid');
  }
  for (final family in evaluationFamilies) {
    if (queries.where((item) => item.family == family).length != 10) {
      throw const FormatException('Retrieval family counts are invalid');
    }
  }
  for (final corpus in evaluationCorpora) {
    for (final language in evaluationLanguages) {
      for (final family in evaluationFamilies) {
        if (!queries.any((item) => item.corpus == corpus && item.language == language && item.family == family)) {
          throw const FormatException('Retrieval slice matrix is incomplete');
        }
      }
    }
  }
  final documentsById = {for (final item in documents) item.id: item};
  if (!queries.any((query) => query.expectEmpty)) {
    throw const FormatException('Retrieval fixture requires at least one expected-empty query');
  }
  for (final query in queries) {
    if (query.relevantDocumentIds.isEmpty && query.family != 'answer-absent') {
      throw const FormatException('Retrieval relevance families are invalid');
    }
    if (query.expectEmpty && query.relevantDocumentIds.isNotEmpty) {
      throw const FormatException('Expected-empty query cannot have relevant documents');
    }
    for (final id in query.relevantDocumentIds) {
      final document = documentsById[id];
      if (document == null || document.tenant != query.tenant || document.corpus != query.corpus) {
        throw const FormatException('Retrieval relevance identity is invalid');
      }
    }
  }
}

bool _sameSet(Set<String> left, Set<String> right) => left.length == right.length && left.containsAll(right);

void _expectSetting(Map<String, Object?> settings, String key, Object expected) {
  if (settings[key] != expected) throw FormatException('Frozen retrieval setting is invalid: $key');
}

double _mean(Iterable<num> values) {
  final materialized = values.toList(growable: false);
  if (materialized.isEmpty) throw ArgumentError.value(values, 'values', 'must not be empty');
  return materialized.fold<double>(0, (total, value) => total + value) / materialized.length;
}

double? _rounded(double? value) => value == null ? null : (value * 10000).round() / 10000;
