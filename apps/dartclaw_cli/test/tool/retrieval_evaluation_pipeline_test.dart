import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_search/dartclaw_search.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../tool/retrieval_evaluation.dart';

void main() {
  test('measurement refuses an unconfigured relevance provider', () {
    expect(
      () => RetrievalEvaluationArguments.parse(['--model-path', 'model.gguf', '--output-dir', 'out']),
      throwsA(isA<RetrievalEvaluationUsage>()),
    );
  });

  test('argument contract has only asset-check and fixed full-run modes', () {
    expect(RetrievalEvaluationArguments.parse(['--check-assets']).checkAssets, isTrue);
    final full = RetrievalEvaluationArguments.parse([
      '--output-dir',
      'out',
      '--model-path',
      'model.gguf',
      '--runtime-config',
      'runtime.yaml',
    ]);
    expect(
      (full.checkAssets, full.modelPath, full.outputDirectory, full.runtimeConfigPath),
      (false, 'model.gguf', 'out', 'runtime.yaml'),
    );
    expect(
      () => RetrievalEvaluationArguments.parse(['--model-path', 'model.gguf', '--top-k', '7']),
      throwsA(isA<RetrievalEvaluationUsage>()),
    );
  });

  test('real SQLite projections, synchronizers, vector index, FTS, and hybrid preserve identities', () async {
    final root = Directory.systemTemp.createTempSync('retrieval_evaluation_pipeline_');
    final provider = _LiteralEmbeddingProvider();
    final pipeline = await EvaluationBackendPipeline.openSqlite(
      directory: '${root.path}/stores',
      embeddingProvider: provider,
      relevanceFilter: SearchRelevanceFilter(judge: (_, schema) async => _decisions(schema, true)),
    );
    addTearDown(() async {
      await pipeline.close();
      await provider.dispose();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    final counts = await pipeline.prepareLanguage('en', const [
      EvaluationDocument(
        id: 'memory-lexical',
        tenant: 'fixture-owner',
        corpus: 'memory',
        language: 'en',
        text: 'literal lexical marker',
      ),
      EvaluationDocument(
        id: 'memory-semantic',
        tenant: 'fixture-owner',
        corpus: 'memory',
        language: 'en',
        text: 'literal semantic marker',
      ),
      EvaluationDocument(
        id: 'conversation-lexical',
        tenant: 'fixture-owner',
        corpus: 'conversation',
        language: 'en',
        text: 'dialogue lexical marker',
      ),
      EvaluationDocument(
        id: 'conversation-semantic',
        tenant: 'fixture-owner',
        corpus: 'conversation',
        language: 'en',
        text: 'dialogue semantic marker',
      ),
      EvaluationDocument(
        id: 'other-memory',
        tenant: 'other-owner',
        corpus: 'memory',
        language: 'en',
        text: 'literal lexical marker',
      ),
      EvaluationDocument(
        id: 'other-conversation',
        tenant: 'other-owner',
        corpus: 'conversation',
        language: 'en',
        text: 'dialogue lexical marker',
      ),
    ]);

    final memoryKeyword = await pipeline.search('memory', 'keyword', 'lexical');
    final conversationKeyword = await pipeline.search('conversation', 'keyword', 'lexical');
    final memoryVector = await pipeline.search('memory', 'vector', 'semantic');
    final conversationHybrid = await pipeline.search('conversation', 'hybrid', 'semantic');

    expect((counts.memoryDocuments, counts.conversationDocuments), (3, 3));
    expect(counts.embedded, 6);
    expect(memoryKeyword.single.id, 'memory-lexical');
    expect(memoryKeyword.single.metadata, containsPair('entry_id', 'memory-lexical'));
    expect(conversationKeyword.single.id, 'conversation-lexical');
    expect(conversationKeyword.single.metadata['session_id'], matches(RegExp(r'^[0-9a-f-]{36}$')));
    expect(memoryVector.first.id, 'memory-semantic');
    expect(conversationHybrid.first.id, 'conversation-semantic');
    expect(provider.documentCalls, 4);
  });

  test('hybrid evaluation refuses an embedding degradation after a healthy projection', () async {
    final root = Directory.systemTemp.createTempSync('retrieval_embedding_failure_');
    final provider = _LiteralEmbeddingProvider();
    final pipeline = await EvaluationBackendPipeline.openSqlite(
      directory: '${root.path}/stores',
      embeddingProvider: provider,
      relevanceFilter: SearchRelevanceFilter(judge: (_, schema) async => _decisions(schema, true)),
    );
    addTearDown(() async {
      await pipeline.close();
      await provider.dispose();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    await pipeline.prepareLanguage('en', const [
      EvaluationDocument(
        id: 'memory-semantic',
        tenant: 'fixture-owner',
        corpus: 'memory',
        language: 'en',
        text: 'literal semantic marker',
      ),
    ]);
    provider.failQueries = true;

    expect(await pipeline.search('memory', 'keyword', 'semantic'), hasLength(1));
    await expectLater(pipeline.search('memory', 'hybrid', 'semantic'), throwsA(isA<FormatException>()));
  });

  test('vector and hybrid distinguish a rejected passage from a failed judge in both corpora', () async {
    final root = Directory.systemTemp.createTempSync('retrieval_relevance_pipeline_');
    var fail = false;
    var calls = 0;
    final pipeline = await EvaluationBackendPipeline.openSqlite(
      directory: '${root.path}/stores',
      embeddingProvider: _LiteralEmbeddingProvider(),
      relevanceFilter: SearchRelevanceFilter(
        judge: (_, schema) async {
          calls++;
          if (fail) throw const FormatException('literal judge failure');
          return _decisions(schema, false);
        },
      ),
    );
    addTearDown(() async {
      await pipeline.close();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    await pipeline.prepareLanguage('en', [
      for (final corpus in ['memory', 'conversation'])
        EvaluationDocument(
          id: '$corpus-document',
          tenant: 'fixture-owner',
          corpus: corpus,
          language: 'en',
          text: 'semantic marker',
        ),
    ]);
    for (final corpus in ['memory', 'conversation']) {
      for (final mode in ['vector', 'hybrid']) {
        expect(await pipeline.search(corpus, mode, 'semantic'), isEmpty);
      }
    }
    expect(calls, 4);
    fail = true;
    for (final corpus in ['memory', 'conversation']) {
      for (final mode in ['vector', 'hybrid']) {
        await expectLater(pipeline.search(corpus, mode, 'semantic'), throwsA(isA<FormatException>()));
      }
      expect(await pipeline.search(corpus, 'keyword', 'semantic'), hasLength(1));
    }
    expect(calls, 8);
  });

  test('evaluation config redirects all derived stores away from an existing instance', () {
    final root = Directory.systemTemp.createTempSync('retrieval_runtime_config_');
    addTearDown(() => root.deleteSync(recursive: true));
    final existing = Directory('${root.path}/existing')..createSync();
    final sentinel = File('${existing.path}/sentinel')..writeAsStringSync('unchanged');
    final source = File('${root.path}/runtime.yaml')
      ..writeAsStringSync(
        'data_dir: ${existing.path}\nagent:\n  provider: codex\n  model: literal-model\n'
        'providers:\n  codex:\n    executable: codex\n    auth: subscription\n',
      );
    final fresh = '${root.path}/evaluation';
    final config = loadEvaluationRuntimeConfig(source.path, fresh);
    expect(config.server.dataDir, fresh);
    expect(config.sessionsDir, startsWith('$fresh/'));
    expect(config.dartclawDbPath, startsWith('$fresh/'));
    expect(config.agent.model, 'literal-model');
    expect(existing.listSync().map((item) => item.path), [sentinel.path]);
    expect(sentinel.readAsStringSync(), 'unchanged');
  });

  test('evaluation cannot attach the relevance runtime to a configured PostgreSQL instance', () {
    final root = Directory.systemTemp.createTempSync('retrieval_runtime_database_');
    addTearDown(() => root.deleteSync(recursive: true));
    final source = File('${root.path}/runtime.yaml')
      ..writeAsStringSync('database:\n  backend: postgres\n  url: postgresql://localhost/live\n');
    expect(
      () => loadEvaluationRuntimeConfig(source.path, '${root.path}/evaluation'),
      throwsA(isA<FormatException>().having((error) => error.message, 'message', contains('fresh local SQLite'))),
    );
  });

  test('evaluation requires explicit authentication selection before any vendor login probe', () {
    final root = Directory.systemTemp.createTempSync('retrieval_runtime_auth_');
    addTearDown(() => root.deleteSync(recursive: true));
    final source = File('${root.path}/runtime.yaml');
    for (final auth in ['', '    auth: auto\n']) {
      source.writeAsStringSync(
        'agent:\n  provider: codex\n  model: literal-model\n'
        'providers:\n  codex:\n    executable: codex\n$auth',
      );
      expect(
        () => loadEvaluationRuntimeConfig(source.path, '${root.path}/evaluation'),
        throwsA(isA<FormatException>().having((error) => error.message, 'message', contains('explicit auth'))),
      );
    }
  });

  test('evaluation requires a pinned model before provider setup', () {
    final root = Directory.systemTemp.createTempSync('retrieval_runtime_model_');
    addTearDown(() => root.deleteSync(recursive: true));
    final source = File('${root.path}/runtime.yaml')
      ..writeAsStringSync(
        'agent:\n  provider: codex\nproviders:\n  codex:\n    executable: codex\n    auth: subscription\n',
      );
    expect(
      () => loadEvaluationRuntimeConfig(source.path, '${root.path}/evaluation'),
      throwsA(isA<FormatException>().having((error) => error.message, 'message', contains('explicit model'))),
    );
  });

  test('evaluation refuses prior runtime state before provider setup', () async {
    final root = Directory.systemTemp.createTempSync('retrieval_runtime_prior_');
    addTearDown(() => root.deleteSync(recursive: true));
    final sentinel = File('${root.path}/dartclaw.db')..writeAsStringSync('existing state');
    await expectLater(
      EvaluationRelevanceRuntime.open(configPath: '${root.path}/missing.yaml', directory: root.path),
      throwsA(isA<FileSystemException>().having((error) => error.message, 'message', contains('no prior state'))),
    );
    expect(sentinel.readAsStringSync(), 'existing state');
  });

  test('evaluation evidence binds real turn outcomes and accounting without counting empty candidates', () async {
    final root = Directory.systemTemp.createTempSync('retrieval_relevance_evidence_');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    final workers = <FakeAgentHarness>[];
    final factory = HarnessFactory()
      ..register('claude', (config) {
        final reportsCost = config.cwd != '/' && workers.isEmpty;
        final harness = FakeAgentHarness(
          supportsCostReporting: reportsCost,
          supportsCachedTokens: true,
          supportsStructuredOutput: true,
          supportsNoWorkTools: true,
        );
        if (config.cwd != '/') workers.add(harness);
        return harness;
      });
    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude', model: 'fixture-model', effort: 'high'),
      providers: const ProvidersConfig(entries: {'claude': ProviderEntry(executable: 'claude', poolSize: 1)}),
      server: ServerConfig(dataDir: root.path),
    );
    final staging = await DartclawRuntime.stageHeadless(
      config,
      dataDir: root.path,
      runtimeCwd: root.path,
      harnessFactory: factory,
      searchBackendFactory: (_) async => SqliteBackend.openInMemory(),
      taskBackendFactory: (_) async => SqliteBackend.openInMemory(),
      stderrLine: (_) {},
      exitFn: (code) => throw StateError('unexpected runtime exit $code'),
      runWorkflowSkillsBootstrap: false,
    );
    final runtime = await staging.completeForExecution({'claude'});
    final evaluation = EvaluationRelevanceRuntime.capture(runtime, const {
      'provider': 'claude',
      'model': 'fixture-model',
      'effort': 'high',
      'configSha256': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    });
    final candidate = SearchResult(
      id: 'doc',
      chunk: 'requested fact',
      chunkIndex: 0,
      score: 1,
      timestamp: DateTime.utc(2026),
    );

    final completed = evaluation.filter.filter('requested fact', [candidate]);
    await _waitFor(() => workers.isNotEmpty && workers.last.hasPendingTurn);
    await expectLater(evaluation.filter.filter('requested fact', [candidate]), throwsA(isA<BusyTurnException>()));
    workers.last.completeSuccess(
      const TurnResult(
        structuredOutput: {'0': true},
        inputTokens: 7,
        outputTokens: 3,
        cacheReadTokens: 2,
        cacheWriteTokens: 1,
        costUsd: 0.04,
      ),
    );
    expect(await completed, [candidate]);
    await _waitFor(() => runtime.requireExecutions.snapshot.availableWorkers == 1);

    final failed = evaluation.filter.filter('requested fact', [candidate]);
    await _waitFor(() => workers.length == 2 && workers.last.hasPendingTurn);
    workers.last.completeSuccess(
      const TurnResult(
        stopReason: 'error',
        error: 'credential and prompt content must stay private',
        inputTokens: 5,
        outputTokens: 1,
        costUsd: 0.02,
      ),
    );
    await expectLater(failed, throwsA(isA<StateError>()));
    expect(await evaluation.filter.filter('requested fact', const []), isEmpty);

    final provenance = await evaluation.close();
    final accounting = provenance['outcomeAccounting']! as Map<String, Object?>;
    expect(accounting['judgeAttempts'], 3);
    expect(accounting['judgeReturns'], 1);
    expect(accounting['judgeFailures'], 2);
    expect(accounting['terminalOutcomeCount'], 2);
    expect(accounting['attemptsWithoutTerminalOutcome'], 1);
    expect(accounting['accountingComplete'], isTrue);
    expect(accounting['statusCounts'], {'completed': 1, 'failed': 1});
    expect(accounting['totals'], {
      'inputTokens': 12,
      'outputTokens': 4,
      'cacheReadTokens': 2,
      'cacheWriteTokens': 1,
      'reportedEstimatedCostUsd': 0.04,
    });
    final outcomes = accounting['outcomes']! as List<Object?>;
    expect(outcomes, hasLength(2));
    expect(
      outcomes.first,
      allOf([
        containsPair('provider', 'claude'),
        containsPair('configuredModel', 'fixture-model'),
        containsPair('status', 'completed'),
        containsPair('inputTokens', 7),
        containsPair('outputTokens', 3),
        containsPair('cacheReadTokens', 2),
        containsPair('cacheWriteTokens', 1),
        containsPair('estimatedCostUsd', 0.04),
        containsPair('costReportingSupported', isTrue),
        containsPair('terminalResponseSha256', matches(RegExp(r'^[0-9a-f]{64}$'))),
      ]),
    );
    expect(
      outcomes.last,
      allOf([
        containsPair('status', 'failed'),
        containsPair('costReportingSupported', isFalse),
        containsPair('estimatedCostUsd', isNull),
        containsPair('terminalResponseSha256', isNull),
      ]),
    );
    final encoded = jsonEncode(provenance);
    expect(encoded, isNot(contains('credential and prompt content')));
    expect(encoded, isNot(contains('requested fact')));

    final evidence = Directory(p.join(root.path, 'evidence'));
    await writeEvaluationArtifacts(evidence, {'status': 'incomplete', 'relevance': provenance});
    final report = File(p.join(evidence.path, 'report.json'));
    final reportSha256 = (await sha256.bind(report.openRead()).first).toString();
    final manifest = File(p.join(evidence.path, 'artifact-sha256.txt')).readAsStringSync();
    expect(manifest, '$reportSha256  report.json\n');
  });

  test('evaluation cost accounting distinguishes missing, zero, positive, and unsupported reports', () async {
    for (final testCase in [
      (name: 'missing', supportsCostReporting: true, reportedCost: null, expectedCost: null, complete: false),
      (name: 'zero', supportsCostReporting: true, reportedCost: 0.0, expectedCost: 0.0, complete: true),
      (name: 'positive', supportsCostReporting: true, reportedCost: 0.25, expectedCost: 0.25, complete: true),
      (name: 'unsupported', supportsCostReporting: false, reportedCost: 9.99, expectedCost: null, complete: true),
    ]) {
      final provenance = await _captureCostEvidence(
        supportsCostReporting: testCase.supportsCostReporting,
        reportedCost: testCase.reportedCost,
      );
      final accounting = provenance['outcomeAccounting']! as Map<String, Object?>;
      final outcomes = accounting['outcomes']! as List<Object?>;
      final outcome = outcomes.single as Map<String, Object?>;
      expect(accounting['accountingComplete'], testCase.complete, reason: testCase.name);
      expect(outcome['costReportingSupported'], testCase.supportsCostReporting, reason: testCase.name);
      expect(outcome['estimatedCostUsd'], testCase.expectedCost, reason: testCase.name);
      if (testCase.complete) {
        expect(
          () => requireCompleteEvaluationRelevanceAccounting(provenance),
          returnsNormally,
          reason: '${testCase.name}: $accounting',
        );
      } else {
        expect(
          () => requireCompleteEvaluationRelevanceAccounting(provenance),
          throwsA(isA<FormatException>()),
          reason: testCase.name,
        );
      }
    }
  });

  test('report and checksum publish from operation-unique temporary siblings', () async {
    final root = Directory.systemTemp.createTempSync('retrieval_evaluation_artifacts_');
    addTearDown(() => root.deleteSync(recursive: true));
    const report = <String, Object?>{
      'schemaVersion': '1',
      'status': 'incomplete',
      'protocol': <String, Object?>{},
      'environment': <String, Object?>{},
      'backendRuns': <Object?>[],
      'sliceRows': <Object?>[],
      'gateRows': <Object?>[],
      'violations': ['literal-failure'],
    };

    const inputHashes = {
      'dev/testing/retrieval/literal.json': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'model/literal.gguf': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    };
    await writeEvaluationArtifacts(root, report, artifactHashes: inputHashes);

    final reportBytes = File('${root.path}/report.json').readAsBytesSync();
    final manifest = File('${root.path}/artifact-sha256.txt').readAsStringSync();
    expect(
      manifest,
      startsWith(
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  '
        'dev/testing/retrieval/literal.json\n'
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  model/literal.gguf\n',
      ),
    );
    expect(manifest, matches(RegExp(r'[0-9a-f]{64}  report\.json\n$')));
    expect(root.listSync().where((entity) => entity.path.contains('.tmp-')), isEmpty);
    final decoded = jsonDecode(utf8.decode(reportBytes)) as Map<String, dynamic>;
    expect(decoded['violations'], ['literal-failure']);
  });
}

Future<void> _waitFor(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) throw StateError('test condition timed out');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<Map<String, Object?>> _captureCostEvidence({
  required bool supportsCostReporting,
  required double? reportedCost,
}) async {
  final root = Directory.systemTemp.createTempSync('retrieval_relevance_cost_');
  final workers = <FakeAgentHarness>[];
  EvaluationRelevanceRuntime? evaluation;
  try {
    final factory = HarnessFactory()
      ..register('claude', (config) {
        final harness = FakeAgentHarness(
          supportsCostReporting: config.cwd != '/' && supportsCostReporting,
          supportsStructuredOutput: true,
          supportsNoWorkTools: true,
        );
        if (config.cwd != '/') workers.add(harness);
        return harness;
      });
    final config = DartclawConfig(
      agent: const AgentConfig(provider: 'claude', model: 'fixture-model'),
      providers: const ProvidersConfig(entries: {'claude': ProviderEntry(executable: 'claude', poolSize: 1)}),
      server: ServerConfig(dataDir: root.path),
    );
    final staging = await DartclawRuntime.stageHeadless(
      config,
      dataDir: root.path,
      runtimeCwd: root.path,
      harnessFactory: factory,
      searchBackendFactory: (_) async => SqliteBackend.openInMemory(),
      taskBackendFactory: (_) async => SqliteBackend.openInMemory(),
      stderrLine: (_) {},
      exitFn: (code) => throw StateError('unexpected runtime exit $code'),
      runWorkflowSkillsBootstrap: false,
    );
    final runtime = await staging.completeForExecution({'claude'});
    evaluation = EvaluationRelevanceRuntime.capture(runtime, const {
      'provider': 'claude',
      'model': 'fixture-model',
      'configSha256': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    });
    final filtered = evaluation.filter.filter('fact', [
      SearchResult(id: 'doc', chunk: 'fact', chunkIndex: 0, score: 1, timestamp: DateTime.utc(2026)),
    ]);
    await _waitFor(() => workers.isNotEmpty && workers.single.hasPendingTurn);
    workers.single.completeSuccess(TurnResult(structuredOutput: const {'0': true}, costUsd: reportedCost));
    expect(await filtered, hasLength(1));
    return await evaluation.close();
  } finally {
    await evaluation?.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

Map<String, dynamic> _decisions(Map<String, dynamic> schema, bool keep) => {
  for (final key in (schema['properties'] as Map<String, dynamic>).keys) key: keep,
};

final class _LiteralEmbeddingProvider implements EmbeddingProvider {
  var documentCalls = 0;
  var failQueries = false;

  @override
  String get modelFingerprint => 'literal-model';

  @override
  Future<List<double>> embedQuery(String query) async {
    if (failQueries) throw StateError('literal query embedding failure');
    return _vector(query);
  }

  @override
  Future<List<List<double>>> embedDocuments(List<String> documents) async {
    documentCalls++;
    return [for (final document in documents) _vector(document)];
  }

  List<double> _vector(String value) => value.contains('semantic') ? const [0, 1] : const [1, 0];

  @override
  Future<void> dispose() async {}
}
