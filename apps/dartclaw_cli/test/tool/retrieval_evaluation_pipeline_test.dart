import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

import '../../tool/retrieval_evaluation.dart';

void main() {
  test('argument contract has only asset-check and fixed full-run modes', () {
    expect(RetrievalEvaluationArguments.parse(['--check-assets']).checkAssets, isTrue);
    final full = RetrievalEvaluationArguments.parse(['--output-dir', 'out', '--model-path', 'model.gguf']);
    expect((full.checkAssets, full.modelPath, full.outputDirectory), (false, 'model.gguf', 'out'));
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

final class _LiteralEmbeddingProvider implements EmbeddingProvider {
  var documentCalls = 0;

  @override
  String get modelFingerprint => 'literal-model';

  @override
  Future<List<double>> embedQuery(String query) async => _vector(query);

  @override
  Future<List<List<double>>> embedDocuments(List<String> documents) async {
    documentCalls++;
    return [for (final document in documents) _vector(document)];
  }

  List<double> _vector(String value) => value.contains('semantic') ? const [0, 1] : const [1, 0];

  @override
  Future<void> dispose() async {}
}
