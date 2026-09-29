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

  test('argument contract keeps fixture selection paired, declared, and immutable', () {
    expect(RetrievalEvaluationArguments.parse(['--check-assets']).checkAssets, isTrue);
    final full = RetrievalEvaluationArguments.parse(['--output-dir', 'out', '--model-path', 'model.gguf']);
    expect(
      (
        full.checkAssets,
        full.modelPath,
        full.outputDirectory,
        full.fixturePath,
        full.fixtureSha256,
        full.fixtureStatus,
      ),
      (false, 'model.gguf', 'out', null, null, RetrievalFixtureStatus.exposedRegression),
    );
    const fixtureHash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final external = RetrievalEvaluationArguments.parse([
      '--model-path',
      'model.gguf',
      '--fixture-sha256',
      fixtureHash,
      '--output-dir',
      'out',
      '--fixture-path',
      'fixture.json',
      '--fixture-status',
      'independent-evaluation',
    ]);
    expect(
      (external.fixturePath, external.fixtureSha256, external.fixtureStatus),
      ('fixture.json', fixtureHash, RetrievalFixtureStatus.independentEvaluation),
    );
    expect(
      RetrievalEvaluationArguments.parse([
        '--check-assets',
        '--fixture-path',
        'fixture.json',
        '--fixture-sha256',
        fixtureHash,
        '--fixture-status',
        'exposed-regression',
      ]).checkAssets,
      isTrue,
    );
    for (final invalid in [
      ['--model-path', 'model.gguf', '--output-dir', 'out', '--fixture-path', 'fixture.json'],
      ['--model-path', 'model.gguf', '--output-dir', 'out', '--fixture-sha256', fixtureHash],
      [
        '--model-path',
        'model.gguf',
        '--output-dir',
        'out',
        '--fixture-path',
        'fixture.json',
        '--fixture-sha256',
        fixtureHash,
      ],
      [
        '--model-path',
        'model.gguf',
        '--output-dir',
        'out',
        '--fixture-path',
        'fixture.json',
        '--fixture-sha256',
        fixtureHash,
        '--fixture-status',
        'unknown',
      ],
      [
        '--model-path',
        'model.gguf',
        '--output-dir',
        'out',
        '--fixture-path',
        'one.json',
        '--fixture-path',
        'two.json',
        '--fixture-sha256',
        fixtureHash,
        '--fixture-status',
        'exposed-regression',
      ],
      [
        '--model-path',
        'model.gguf',
        '--output-dir',
        'out',
        '--fixture-path',
        'fixture.json',
        '--fixture-sha256',
        fixtureHash,
        '--fixture-sha256',
        fixtureHash,
        '--fixture-status',
        'exposed-regression',
      ],
      [
        '--model-path',
        'model.gguf',
        '--output-dir',
        'out',
        '--fixture-path',
        'fixture.json',
        '--fixture-sha256',
        fixtureHash.toUpperCase(),
        '--fixture-status',
        'exposed-regression',
      ],
      [
        '--model-path',
        'model.gguf',
        '--output-dir',
        'out',
        '--fixture-path',
        'fixture.json',
        '--fixture-sha256',
        fixtureHash,
        '--fixture-status',
        'exposed-regression',
        '--fixture-status',
        'independent-evaluation',
      ],
      ['--model-path', 'model.gguf', '--output-dir', 'out', '--fixture-status', 'exposed-regression'],
      ['--model-path', 'model.gguf', '--output-dir', 'out', '--fixture-status', 'independent-evaluation'],
    ]) {
      expect(() => RetrievalEvaluationArguments.parse(invalid), throwsA(isA<RetrievalEvaluationUsage>()));
    }
    expect(
      () => RetrievalEvaluationArguments.parse([
        '--model-path',
        'model.gguf',
        '--output-dir',
        'out',
        '--runtime-config',
        'runtime.yaml',
      ]),
      throwsA(isA<RetrievalEvaluationUsage>()),
    );
    expect(
      () => RetrievalEvaluationArguments.parse(['--model-path', 'model.gguf', '--top-k', '7']),
      throwsA(isA<RetrievalEvaluationUsage>()),
    );
  });

  test('infrastructure refusal retains declared external fixture provenance', () async {
    final root = Directory.systemTemp.createTempSync('retrieval_external_provenance_');
    addTearDown(() => root.deleteSync(recursive: true));
    final fixture = File(p.join(root.path, 'fixture.json'));
    fixture.writeAsBytesSync(File(p.join(repositoryRoot, 'dev/testing/retrieval/retrieval-v2.json')).readAsBytesSync());
    final fixtureHash = sha256.convert(fixture.readAsBytesSync()).toString();
    final environment = Map<String, String>.of(Platform.environment)..remove('DARTCLAW_TEST_POSTGRES_URL');

    for (final status in const ['exposed-regression', 'independent-evaluation']) {
      final output = p.join(root.path, status);
      final result = await Process.run(
        Platform.resolvedExecutable,
        [
          'run',
          'apps/dartclaw_cli/tool/retrieval_evaluation.dart',
          '--model-path',
          p.join(root.path, 'missing-model.gguf'),
          '--output-dir',
          output,
          '--fixture-path',
          fixture.path,
          '--fixture-sha256',
          fixtureHash,
          '--fixture-status',
          status,
        ],
        workingDirectory: repositoryRoot,
        environment: environment,
        includeParentEnvironment: false,
      );

      expect(result.exitCode, 1);
      final report = jsonDecode(File(p.join(output, 'report.json')).readAsStringSync()) as Map<String, dynamic>;
      final protocol = report['protocol'] as Map<String, dynamic>;
      expect(report['violations'], ['postgresql-unavailable']);
      expect(report['noMatchRows'], isEmpty);
      expect(protocol['protocolVersion'], 3);
      expect(protocol['semanticNoMatchPolicy'], 'diagnostic');
      expect(protocol['fixtureStatus'], status);
      expect(protocol['fixtureSha256'], fixtureHash);
      expect((protocol['artifactSha256'] as Map<String, dynamic>)['external/retrieval-fixture.json'], fixtureHash);
      expect(
        File(p.join(output, 'artifact-sha256.txt')).readAsStringSync(),
        contains('$fixtureHash  external/retrieval-fixture.json'),
      );
    }
  });

  test('artifact hashes retain historical inputs and bind the version 2 fixture', () async {
    final hashes = await collectEvaluationArtifactHashes(
      'missing-model.gguf',
      requireModel: false,
      repositoryRoot: repositoryRoot,
    );

    expect(hashes['dev/testing/retrieval/heldout.json'], historicalHeldoutSha256);
    expect(hashes['dev/testing/retrieval/retrieval-v2.json'], retrievalV2Sha256);
    expect(hashes, isNot(contains('apps/dartclaw_cli/tool/retrieval_evaluation/relevance_runtime.dart')));
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
    final reportSha256 = (await sha256.bind(File('${root.path}/report.json').openRead()).first).toString();
    final manifest = File(p.join(root.path, 'artifact-sha256.txt')).readAsStringSync();
    expect(
      manifest,
      startsWith(
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  '
        'dev/testing/retrieval/literal.json\n'
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  model/literal.gguf\n',
      ),
    );
    expect(manifest, endsWith('$reportSha256  report.json\n'));
    expect(root.listSync().where((entity) => entity.path.contains('.tmp-')), isEmpty);
    final decoded = jsonDecode(utf8.decode(reportBytes)) as Map<String, dynamic>;
    expect(decoded['violations'], ['literal-failure']);
  });
}
