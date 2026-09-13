import 'dart:io';

import 'native_artifact_preparation.dart';

Future<void> main(List<String> arguments) async {
  final index = arguments.indexOf('--destination');
  if (index < 0 || index + 1 >= arguments.length) {
    stderr.writeln('Usage: prepare_native_embedding_model.dart --destination <path>');
    exitCode = 64;
    return;
  }
  final manifest = await NativeArtifactManifest.load('dev/native_artifacts.json');
  final destination = arguments[index + 1];
  if (File(destination).uri.pathSegments.last != manifest.model.basename) {
    throw ArgumentError('Embedding model destination must retain ${manifest.model.basename}');
  }
  await NativeArtifactPreparer().acquireVerified(artifact: manifest.model, destinationPath: destination);
  stdout.writeln('verified: ${manifest.model.basename}');
}
