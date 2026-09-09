import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_search/dartclaw_search.dart';
import 'package:path/path.dart' as p;

import 'evaluation.dart';

final class RetrievalEvaluationUsage implements Exception {
  const new(this.message);

  final String message;
}

final class RetrievalEvaluationArguments {
  const new _({required this.checkAssets, this.modelPath, this.outputDirectory});

  final bool checkAssets;
  final String? modelPath;
  final String? outputDirectory;

  static RetrievalEvaluationArguments parse(List<String> arguments) {
    if (arguments.length == 1 && arguments.single == '--check-assets') {
      return const RetrievalEvaluationArguments._(checkAssets: true);
    }
    String? modelPath;
    String? outputDirectory;
    for (var index = 0; index < arguments.length; index++) {
      final name = arguments[index];
      if (name != '--model-path' && name != '--output-dir') throw RetrievalEvaluationUsage(_usage);
      if (++index >= arguments.length || arguments[index].isEmpty) throw RetrievalEvaluationUsage(_usage);
      if (name == '--model-path') {
        if (modelPath != null) throw RetrievalEvaluationUsage(_usage);
        modelPath = arguments[index];
      } else {
        if (outputDirectory != null) throw RetrievalEvaluationUsage(_usage);
        outputDirectory = arguments[index];
      }
    }
    if (modelPath == null || outputDirectory == null || arguments.length != 4) {
      throw RetrievalEvaluationUsage(_usage);
    }
    return RetrievalEvaluationArguments._(checkAssets: false, modelPath: modelPath, outputDirectory: outputDirectory);
  }

  static const _usage = 'Usage: retrieval_evaluation.dart --check-assets | --model-path <path> --output-dir <path>';
}

final class EvaluationProjectionCounts {
  const new({
    required this.memoryDocuments,
    required this.conversationDocuments,
    required this.embedded,
    required this.reused,
    required this.retired,
    required this.unembedded,
  });

  final int memoryDocuments;
  final int conversationDocuments;
  final int embedded;
  final int reused;
  final int retired;
  final int unembedded;

  EvaluationProjectionCounts operator +(EvaluationProjectionCounts other) => EvaluationProjectionCounts(
    memoryDocuments: math.max(memoryDocuments, other.memoryDocuments),
    conversationDocuments: math.max(conversationDocuments, other.conversationDocuments),
    embedded: embedded + other.embedded,
    reused: reused + other.reused,
    retired: retired + other.retired,
    unembedded: unembedded + other.unembedded,
  );
}

final class ObservedEmbeddingProvider implements EmbeddingProvider {
  new(this._delegate);

  final EmbeddingProvider _delegate;
  int? firstDocumentEmbeddingMicros;

  @override
  String get modelFingerprint => _delegate.modelFingerprint;

  @override
  Future<List<double>> embedQuery(String query) => _delegate.embedQuery(query);

  @override
  Future<List<List<double>>> embedDocuments(List<String> documents) async {
    if (firstDocumentEmbeddingMicros != null) return _delegate.embedDocuments(documents);
    final stopwatch = Stopwatch()..start();
    try {
      return await _delegate.embedDocuments(documents);
    } finally {
      firstDocumentEmbeddingMicros = stopwatch.elapsedMicroseconds;
    }
  }

  @override
  Future<void> dispose() => _delegate.dispose();
}

final class EvaluationBackendPipeline {
  new _({
    required this.backendName,
    required DatabaseBackend vectorBackend,
    required EmbeddingProvider embeddingProvider,
    required Future<void> Function() close,
    required FullTextIndex Function(String language, String corpus) lexicalFactory,
  }) : _vectorBackend = vectorBackend,
       _provider = embeddingProvider,
       _close = close,
       _lexicalFactory = lexicalFactory;

  final String backendName;
  final DatabaseBackend _vectorBackend;
  final EmbeddingProvider _provider;
  final Future<void> Function() _close;
  final FullTextIndex Function(String language, String corpus) _lexicalFactory;

  FullTextIndex? _memoryLexical;
  FullTextIndex? _conversationLexical;
  VectorIndex? _memoryVectors;
  VectorIndex? _conversationVectors;
  HybridSearch? _memoryHybrid;
  HybridSearch? _conversationHybrid;

  static Future<EvaluationBackendPipeline> openSqlite({
    required String directory,
    required EmbeddingProvider embeddingProvider,
  }) async {
    final root = Directory(directory)..createSync(recursive: true);
    final lexical = await SqliteBackend.open(p.join(root.path, 'search.db'));
    DatabaseBackend? vectors;
    try {
      await SqliteSchemaGate.prepareSearch(lexical, storeName: 'search.db');
      vectors = await SqliteBackend.open(p.join(root.path, 'vectors.db'));
      await SqliteSchemaGate.prepareVectors(vectors, storeName: 'vectors.db');
      return EvaluationBackendPipeline._(
        backendName: 'sqlite',
        vectorBackend: vectors,
        embeddingProvider: embeddingProvider,
        lexicalFactory: (_, corpus) => SqliteFtsIndex(
          lexical,
          table: corpus == 'memory' ? SqliteFtsTable.memoryChunks : SqliteFtsTable.conversationChunks,
        ),
        close: () async {
          try {
            await vectors!.close();
          } finally {
            try {
              await lexical.close();
            } finally {
              if (root.existsSync()) root.deleteSync(recursive: true);
            }
          }
        },
      );
    } catch (_) {
      await vectors?.close();
      await lexical.close();
      if (root.existsSync()) root.deleteSync(recursive: true);
      rethrow;
    }
  }

  static Future<EvaluationBackendPipeline> openPostgresql({
    required String dsn,
    required EmbeddingProvider embeddingProvider,
  }) async {
    final namespace =
        'dc_eval_${DateTime.now().microsecondsSinceEpoch}_${math.Random().nextInt(1 << 20).toRadixString(16)}';
    final admin = await PostgresBackend.open(dsn: dsn, poolSize: 1, credentialRef: 'DARTCLAW_TEST_POSTGRES_URL');
    PostgresBackend? scoped;
    try {
      await admin.execute('CREATE SCHEMA "$namespace"');
      scoped = await PostgresBackend.open(
        dsn: dsn,
        poolSize: 3,
        namespace: namespace,
        credentialRef: 'DARTCLAW_TEST_POSTGRES_URL',
      );
      await PostgresSchemaGate.preflightVectorExtension(scoped, databaseIdentity: scoped.databaseIdentity);
      await PostgresSchemaGate.prepare(scoped, databaseIdentity: scoped.databaseIdentity);
      await PostgresSchemaGate.prepareVectorProjection(scoped, databaseIdentity: scoped.databaseIdentity);
      return EvaluationBackendPipeline._(
        backendName: 'postgresql',
        vectorBackend: scoped,
        embeddingProvider: embeddingProvider,
        lexicalFactory: (language, corpus) => PostgresFtsIndex(
          scoped!,
          table: corpus == 'memory' ? PostgresFtsTable.memoryChunks : PostgresFtsTable.conversationChunks,
          language: language == 'en' ? 'english' : 'swedish',
        ),
        close: () async {
          try {
            await scoped!.close();
          } finally {
            try {
              await admin.execute('DROP SCHEMA IF EXISTS "$namespace" CASCADE');
            } finally {
              await admin.close();
            }
          }
        },
      );
    } catch (_) {
      await scoped?.close();
      try {
        await admin.execute('DROP SCHEMA IF EXISTS "$namespace" CASCADE');
      } catch (_) {}
      await admin.close();
      rethrow;
    }
  }

  Future<EvaluationProjectionCounts> prepareLanguage(String language, List<EvaluationDocument> documents) async {
    if (!evaluationLanguages.contains(language)) throw ArgumentError.value(language, 'language');
    final memory = _memoryLexical = _lexicalFactory(language, 'memory');
    final conversation = _conversationLexical = _lexicalFactory(language, 'conversation');
    final memoryDocuments = _projectMemory(
      documents.where((item) => item.corpus == 'memory' && item.tenant == 'fixture-owner'),
    );
    final conversationDocuments = _projectConversations(
      documents.where((item) => item.corpus == 'conversation' && item.tenant == 'fixture-owner'),
    );
    final foreignMemory = _projectMemory(
      documents.where((item) => item.corpus == 'memory' && item.tenant == 'other-owner'),
    );
    final foreignConversation = _projectConversations(
      documents.where((item) => item.corpus == 'conversation' && item.tenant == 'other-owner'),
    );
    await memory.replaceAll(memoryDocuments, userId: 'fixture-owner');
    await memory.replaceAll(foreignMemory, userId: 'other-owner');
    await conversation.replaceAll(conversationDocuments, userId: 'fixture-owner');
    await conversation.replaceAll(foreignConversation, userId: 'other-owner');

    final memoryVectors = _memoryVectors ??= backendName == 'sqlite'
        ? SqliteVectorIndex(_vectorBackend, table: VectorTable.memoryChunks)
        : PostgresVectorIndex(_vectorBackend, table: VectorTable.memoryChunks);
    final conversationVectors = _conversationVectors ??= backendName == 'sqlite'
        ? SqliteVectorIndex(_vectorBackend, table: VectorTable.conversationChunks)
        : PostgresVectorIndex(_vectorBackend, table: VectorTable.conversationChunks);
    _memoryHybrid = HybridSearch(
      lexicalIndex: memory,
      vectorIndex: memoryVectors,
      embeddingProvider: _provider,
      sourceLayer: 'memory',
    );
    _conversationHybrid = HybridSearch(
      lexicalIndex: conversation,
      vectorIndex: conversationVectors,
      embeddingProvider: _provider,
      sourceLayer: 'conversation',
    );
    final memorySynchronizer = VectorSynchronizer(
      lexicalIndex: memory,
      vectorIndex: memoryVectors,
      embeddingProvider: _provider,
      sourceLayer: 'memory',
    );
    final conversationSynchronizer = VectorSynchronizer(
      lexicalIndex: conversation,
      vectorIndex: conversationVectors,
      embeddingProvider: _provider,
      sourceLayer: 'conversation',
    );
    final results = <VectorSynchronizationResult>[
      await memorySynchronizer.rebuild(userId: 'fixture-owner'),
      await memorySynchronizer.rebuild(userId: 'other-owner'),
      await conversationSynchronizer.rebuild(userId: 'fixture-owner'),
      await conversationSynchronizer.rebuild(userId: 'other-owner'),
    ];
    return EvaluationProjectionCounts(
      memoryDocuments: memoryDocuments.length + foreignMemory.length,
      conversationDocuments: conversationDocuments.length + foreignConversation.length,
      embedded: results.fold(0, (total, item) => total + item.embeddedCount),
      reused: results.fold(0, (total, item) => total + item.reusedCount),
      retired: results.fold(0, (total, item) => total + item.retiredCount),
      unembedded: results.fold(0, (total, item) => total + item.unembeddedCount),
    );
  }

  Future<List<SearchResult>> search(String corpus, String mode, String query) async {
    final lexical = corpus == 'memory' ? _memoryLexical : _conversationLexical;
    final vectors = corpus == 'memory' ? _memoryVectors : _conversationVectors;
    final hybrid = corpus == 'memory' ? _memoryHybrid : _conversationHybrid;
    if (lexical == null || vectors == null || hybrid == null) throw StateError('evaluation pipeline is not prepared');
    return switch (mode) {
      'keyword' => lexical.search(query, userId: 'fixture-owner', limit: 20),
      'vector' => _vectorResults(lexical, vectors, query),
      'hybrid' => hybrid.search(query, userId: 'fixture-owner', limit: 20),
      _ => throw ArgumentError.value(mode, 'mode'),
    };
  }

  Future<List<SearchResult>> _vectorResults(FullTextIndex lexical, VectorIndex vectors, String query) async {
    final embedded = await _provider.embedQuery(query);
    final matches = await vectors.search(
      embedded,
      userId: 'fixture-owner',
      modelFingerprint: _provider.modelFingerprint,
      limit: 20,
    );
    final eligible = matches.where((item) => item.score >= 0.20).toList(growable: false);
    final current = await lexical.fetch(eligible.map((item) => item.documentId).toSet(), userId: 'fixture-owner');
    final currentByIdentity = <VectorIdentity, ({SearchDocument document, String chunk})>{};
    for (final document in current) {
      for (var index = 0; index < document.chunks.length; index++) {
        currentByIdentity[VectorIdentity(documentId: document.id, chunkIndex: index)] = (
          document: document,
          chunk: document.chunks[index],
        );
      }
    }
    final results = <SearchResult>[];
    for (final match in eligible) {
      final currentChunk =
          currentByIdentity[VectorIdentity(documentId: match.documentId, chunkIndex: match.chunkIndex)];
      if (currentChunk == null || sha256.convert(utf8.encode(currentChunk.chunk)).toString() != match.contentHash) {
        continue;
      }
      results.add(
        SearchResult(
          id: match.documentId,
          chunk: currentChunk.chunk,
          chunkIndex: match.chunkIndex,
          metadata: currentChunk.document.metadata,
          timestamp: currentChunk.document.timestamp,
          score: match.score,
        ),
      );
    }
    return List.unmodifiable(results);
  }

  Future<void> close() => _close();
}

Future<int> runRetrievalEvaluation(RetrievalEvaluationArguments arguments, RetrievalFixture fixture) async {
  final output = Directory(arguments.outputDirectory!)..createSync(recursive: true);
  final protocol = await _protocol(fixture.settings);
  final environment = _environment();
  final postgresDsn = Platform.environment['DARTCLAW_TEST_POSTGRES_URL'];
  if (postgresDsn == null || postgresDsn.isEmpty) {
    await _writeFailure(output, protocol, environment, 'postgresql-unavailable', modelPath: arguments.modelPath!);
    stderr.writeln('Retrieval evaluation requires DARTCLAW_TEST_POSTGRES_URL.');
    return 1;
  }

  final observations = <RankingObservation>[];
  final backendRuns = <Map<String, Object?>>[];
  final identities = <String, ({String tenant, String corpus})>{
    for (final document in fixture.documents) document.id: (tenant: document.tenant, corpus: document.corpus),
  };
  try {
    for (final backend in evaluationBackends) {
      final provider = ObservedEmbeddingProvider(
        NativeEmbeddingProvider(
          modelPath: arguments.modelPath!,
          expectedSha256: fixture.settings['modelSha256']! as String,
        ),
      );
      final stopwatch = Stopwatch()..start();
      EvaluationBackendPipeline? pipeline;
      var totals = const EvaluationProjectionCounts(
        memoryDocuments: 0,
        conversationDocuments: 0,
        embedded: 0,
        reused: 0,
        retired: 0,
        unembedded: 0,
      );
      try {
        pipeline = backend == 'sqlite'
            ? await EvaluationBackendPipeline.openSqlite(
                directory: p.join(output.parent.path, '.retrieval-evaluation-sqlite-$pid'),
                embeddingProvider: provider,
              )
            : await EvaluationBackendPipeline.openPostgresql(dsn: postgresDsn, embeddingProvider: provider);
        for (final language in evaluationLanguages) {
          totals += await pipeline.prepareLanguage(language, fixture.documents);
          for (final query in fixture.queries.where((item) => item.language == language)) {
            for (final mode in evaluationModes) {
              await pipeline.search(query.corpus, mode, query.text);
              final warm = Stopwatch()..start();
              final results = await pipeline.search(query.corpus, mode, query.text);
              warm.stop();
              var foreignOwners = 0;
              var wrongCorpora = 0;
              for (final result in results) {
                final identity = identities[result.id];
                if (identity == null || identity.tenant != query.tenant) foreignOwners++;
                if (identity == null || identity.corpus != query.corpus) wrongCorpora++;
              }
              observations.add(
                RankingObservation(
                  backend: backend,
                  mode: mode,
                  query: query,
                  documentIds: results.map((item) => item.id),
                  warmMicros: warm.elapsedMicroseconds,
                  foreignOwnerCount: foreignOwners,
                  wrongCorpusCount: wrongCorpora,
                ),
              );
            }
          }
        }
        final cold = provider.firstDocumentEmbeddingMicros;
        if (cold == null) throw StateError('provider was not observed during synchronization');
        backendRuns.add({
          'backend': backend,
          'providerFingerprint': provider.modelFingerprint,
          'coldFirstEmbedDocumentsMs': _round4(cold / 1000),
          'projectionCounts': {
            'memoryDocuments': totals.memoryDocuments,
            'conversationDocuments': totals.conversationDocuments,
          },
          'synchronizationCounts': {
            'embedded': totals.embedded,
            'reused': totals.reused,
            'retired': totals.retired,
            'unembedded': totals.unembedded,
          },
          'totalDurationMs': _round4(stopwatch.elapsedMicroseconds / 1000),
        });
      } finally {
        await pipeline?.close();
        await provider.dispose();
      }
    }
    final slices = buildSliceRows(fixture.queries, observations);
    final gates = buildGateRows(fixture.queries, observations);
    final violations = [
      for (final row in gates)
        if (!row.passed) row.id,
    ];
    final artifactHashes = await collectEvaluationArtifactHashes(arguments.modelPath!);
    protocol['artifactSha256'] = artifactHashes;
    protocol['modelSha256'] = artifactHashes['model/${p.basename(arguments.modelPath!)}'];
    final report = {
      'schemaVersion': '1',
      'status': violations.isEmpty ? 'pass' : 'fail',
      'protocol': protocol,
      'environment': environment,
      'backendRuns': backendRuns,
      'sliceRows': slices.map((item) => item.toJson()).toList(growable: false),
      'gateRows': gates.map((item) => item.toJson()).toList(growable: false),
      'violations': violations,
    };
    await writeEvaluationArtifacts(output, report, artifactHashes: artifactHashes);
    if (violations.isEmpty) {
      stdout.writeln('Retrieval evaluation: PASS (144 slice rows, 0 violations)');
      return 0;
    }
    stdout.writeln('Retrieval evaluation: FAIL (${violations.length} violations)');
    return 1;
  } on Object {
    await _writeFailure(output, protocol, environment, 'evaluation-incomplete', modelPath: arguments.modelPath!);
    stderr.writeln('Retrieval evaluation could not complete; check the model and PostgreSQL/pgvector setup.');
    return 1;
  }
}

Future<Map<String, Object?>> _protocol(Map<String, Object?> settings) async => {
  'rrfK': settings['rrfK'],
  'keywordWeight': settings['keywordWeight'],
  'vectorWeight': settings['vectorWeight'],
  'minimumCosine': settings['minimumCosine'],
  'topK': 5,
  'candidateLimit': 20,
  'warmupCount': 1,
  'repetitions': 1,
  'postgresLanguages': {'en': 'english', 'sv': 'swedish'},
  'fixtureSha256': heldoutSha256,
  'settingsSha256': selectedSettingsSha256,
  'calibrationFixtureSha256': calibrationFixtureSha256,
  'calibrationNegativesSha256': calibrationNegativesSha256,
  'calibrationSummarySha256': calibrationSummarySha256,
  'modelSha256': settings['modelSha256'],
  'sourceRevision': await _sourceRevision(),
};

Map<String, Object?> _environment() => {
  'dartVersion': Platform.version.split(' ').first,
  'operatingSystem': Platform.operatingSystem,
  'operatingSystemVersion': Platform.operatingSystemVersion,
  'architecture': Abi.current().toString(),
  'processorCount': Platform.numberOfProcessors,
};

Future<String> _sourceRevision() async {
  try {
    final result = await Process.run('git', ['rev-parse', 'HEAD']);
    final revision = (result.stdout as String).trim();
    return result.exitCode == 0 && RegExp(r'^[0-9a-f]{40}$').hasMatch(revision) ? revision : 'unknown';
  } on Object {
    return 'unknown';
  }
}

Future<void> _writeFailure(
  Directory output,
  Map<String, Object?> protocol,
  Map<String, Object?> environment,
  String violation, {
  required String modelPath,
}) async {
  final artifactHashes = await collectEvaluationArtifactHashes(modelPath, requireModel: false);
  protocol['artifactSha256'] = artifactHashes;
  protocol['modelSha256'] = artifactHashes['model/${p.basename(modelPath)}'];
  await writeEvaluationArtifacts(output, {
    'schemaVersion': '1',
    'status': 'incomplete',
    'protocol': protocol,
    'environment': environment,
    'backendRuns': <Object?>[],
    'sliceRows': <Object?>[],
    'gateRows': <Object?>[],
    'violations': [violation],
  }, artifactHashes: artifactHashes);
}

Future<void> writeEvaluationArtifacts(
  Directory output,
  Map<String, Object?> report, {
  Map<String, String> artifactHashes = const {},
}) async {
  final bytes = utf8.encode('${const JsonEncoder.withIndent('  ').convert(report)}\n');
  final reportFile = File(p.join(output.path, 'report.json'));
  await _writeAtomically(reportFile, bytes);
  final manifest = <String, String>{...artifactHashes, 'report.json': sha256.convert(bytes).toString()};
  final lines = manifest.entries.toList(growable: false)..sort((left, right) => left.key.compareTo(right.key));
  await _writeAtomically(
    File(p.join(output.path, 'artifact-sha256.txt')),
    utf8.encode('${lines.map((entry) => '${entry.value}  ${entry.key}').join('\n')}\n'),
  );
}

Future<Map<String, String>> collectEvaluationArtifactHashes(String modelPath, {bool requireModel = true}) async {
  final files = <String, File>{
    'apps/dartclaw_cli/tool/retrieval_evaluation.dart': File('apps/dartclaw_cli/tool/retrieval_evaluation.dart'),
    'apps/dartclaw_cli/tool/retrieval_evaluation/evaluation.dart': File(
      'apps/dartclaw_cli/tool/retrieval_evaluation/evaluation.dart',
    ),
    'apps/dartclaw_cli/tool/retrieval_evaluation/pipeline.dart': File(
      'apps/dartclaw_cli/tool/retrieval_evaluation/pipeline.dart',
    ),
    for (final name in [
      'calibration-fixture.dart.txt',
      'calibration-negatives.json',
      'calibration-summary.md',
      'selected-settings.json',
      'heldout.json',
    ])
      'dev/testing/retrieval/$name': File('dev/testing/retrieval/$name'),
  };
  final model = File(modelPath);
  if (FileSystemEntity.typeSync(model.path, followLinks: false) == FileSystemEntityType.file) {
    files['model/${p.basename(model.path)}'] = model;
  } else if (requireModel) {
    throw const FileSystemException('Native embedding model is unavailable');
  }
  final hashes = <String, String>{};
  for (final entry in files.entries) {
    hashes[entry.key] = (await sha256.bind(entry.value.openRead()).first).toString();
  }
  return Map.unmodifiable(hashes);
}

Future<void> _writeAtomically(File target, List<int> bytes) async {
  target.parent.createSync(recursive: true);
  final temporary = File('${target.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}');
  try {
    final sink = temporary.openWrite();
    sink.add(bytes);
    await sink.flush();
    await sink.close();
    await temporary.rename(target.path);
  } finally {
    if (temporary.existsSync()) temporary.deleteSync();
  }
}

List<SearchDocument> _projectMemory(Iterable<EvaluationDocument> documents) => [
  for (final (index, document) in documents.indexed)
    MemoryIndexProjection.document(
      text: document.text,
      source: 'evaluation/${document.id}',
      category: 'retrieval-evaluation',
      createdAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: index)),
      role: 'topic',
      provenance: 'evaluation-fixture',
      locator: document.id,
      entryId: document.id,
      entryRevision: 1,
    )!,
];

List<SearchDocument> _projectConversations(Iterable<EvaluationDocument> documents) => [
  for (final (index, document) in documents.indexed)
    ConversationIndexProjection.document(
      message: Message(
        cursor: index + 1,
        id: document.id,
        sessionId: '00000000-0000-4000-8000-${(index + 1).toString().padLeft(12, '0')}',
        role: 'user',
        content: document.text,
        createdAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: index)),
      ),
      sessionType: SessionType.user,
    )!,
];

double _round4(double value) => (value * 10000).round() / 10000;
