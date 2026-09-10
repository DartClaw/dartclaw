import 'dart:io';

import 'retrieval_evaluation/evaluation.dart';
import 'retrieval_evaluation/pipeline.dart';

export 'retrieval_evaluation/evaluation.dart';
export 'retrieval_evaluation/pipeline.dart';

Future<void> main(List<String> arguments) async {
  try {
    final parsed = RetrievalEvaluationArguments.parse(arguments);
    final assets = RetrievalAssetBundle('dev/testing/retrieval')
        .verifyAndLoad(fixturePath: parsed.fixturePath, fixtureSha256: parsed.fixtureSha256);
    if (parsed.checkAssets) {
      stdout.writeln('Retrieval evaluation assets: PASS');
      return;
    }
    exitCode = await runRetrievalEvaluation(parsed, assets);
  } on RetrievalEvaluationUsage catch (error) {
    stderr.writeln(error.message);
    exitCode = 64;
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
  } on Object {
    stderr.writeln('Retrieval evaluation could not start.');
    exitCode = 1;
  }
}
