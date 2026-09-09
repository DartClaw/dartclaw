import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_search/dartclaw_search.dart';

Future<void> main(List<String> arguments) async {
  final modelPath = _value(arguments, '--model');
  final expectedSha256 = _value(arguments, '--sha256');
  final expectedFailure = _value(arguments, '--expect-failure');
  if (modelPath == null || expectedSha256 == null) {
    stderr.writeln('Usage: native_embedding_probe --model <path> --sha256 <digest> [--expect-failure <operation>]');
    exitCode = 64;
    return;
  }

  final provider = NativeEmbeddingProvider(modelPath: modelPath, expectedSha256: expectedSha256);
  final total = Stopwatch()..start();
  String operation = expectedFailure ?? 'coldFirstEmbed';
  try {
    if (expectedFailure != null) {
      await provider.embedQuery('platform failure probe');
      stdout.writeln(
        jsonEncode({'result': 'fail', 'operation': expectedFailure, 'error': 'Expected failure did not occur'}),
      );
      exitCode = 1;
      return;
    }

    final coldWatch = Stopwatch()..start();
    final cold = await provider.embedQuery('platform cold probe');
    coldWatch.stop();
    operation = 'warmQuery';
    final warmWatch = Stopwatch()..start();
    final warm = await provider.embedQuery('platform warm probe');
    warmWatch.stop();
    operation = 'documentBatch';
    final documentWatch = Stopwatch()..start();
    final documentInputs = const ['platform document alpha', 'platform document omega'];
    final documents = await provider.embedDocuments(documentInputs);
    documentWatch.stop();
    final firstDocument = await provider.embedDocuments([documentInputs.first]);
    final secondDocument = await provider.embedDocuments([documentInputs.last]);
    _requireVectors([cold, warm, ...documents, ...firstDocument, ...secondDocument], expectedCardinality: 6);
    _requireSameVector(documents[0], firstDocument.single);
    _requireSameVector(documents[1], secondDocument.single);

    operation = 'dispose';
    final disposeWatch = Stopwatch()..start();
    await provider.dispose();
    disposeWatch.stop();
    stdout.writeln(
      jsonEncode({
        'result': 'pass',
        'metrics': {
          'coldFirstEmbedMs': coldWatch.elapsedMilliseconds,
          'warmQueryMs': warmWatch.elapsedMilliseconds,
          'documentBatchMs': documentWatch.elapsedMilliseconds,
          'disposeMs': disposeWatch.elapsedMilliseconds,
          'vectorDimension': cold.length,
          'documentCardinality': documents.length,
        },
      }),
    );
  } catch (error) {
    var disposeElapsed = 0;
    final disposeWatch = Stopwatch()..start();
    try {
      await provider.dispose();
    } catch (_) {}
    disposeWatch.stop();
    disposeElapsed = disposeWatch.elapsedMilliseconds;
    final wantedFailure = expectedFailure != null;
    stdout.writeln(
      jsonEncode({
        'result': wantedFailure ? 'expected-failure' : 'fail',
        'operation': operation,
        'elapsedMs': total.elapsedMilliseconds,
        'disposeMs': disposeElapsed,
        'error': _safeError(error),
      }),
    );
    exitCode = 1;
  }
}

void _requireVectors(List<List<double>> vectors, {required int expectedCardinality}) {
  if (vectors.length != expectedCardinality || vectors.first.isEmpty) throw StateError('Invalid embedding cardinality');
  final dimension = vectors.first.length;
  if (vectors.any((vector) => vector.length != dimension || vector.any((value) => !value.isFinite))) {
    throw StateError('Invalid embedding vector');
  }
}

void _requireSameVector(List<double> batch, List<double> individual) {
  if (batch.length != individual.length) throw StateError('Native embedding document order was not preserved');
  for (var index = 0; index < batch.length; index++) {
    if ((batch[index] - individual[index]).abs() > 1e-6) {
      throw StateError('Native embedding document order was not preserved');
    }
  }
}

String _safeError(Object error) {
  final text = '$error'.replaceAll(RegExp(r'[\r\n]+'), ' ');
  if (text.contains('/') || text.contains('\\')) return 'Native embedding operation failed';
  return text.length <= 240 ? text : text.substring(0, 240);
}

String? _value(List<String> arguments, String name) {
  final index = arguments.indexOf(name);
  if (index < 0 || index + 1 >= arguments.length) return null;
  return arguments[index + 1];
}
