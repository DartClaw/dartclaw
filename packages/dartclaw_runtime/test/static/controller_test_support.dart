import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../test_utils.dart';

Future<File> controllerAsset(String name) async {
  final staticDir = await resolveStaticDir();
  return File(p.join(staticDir, 'controllers', name));
}

Future<void> expectNodeHarness(String harness, List<String> arguments) async {
  late final ProcessResult result;
  try {
    result = await Process.run('node', [
      '--input-type=module',
      '--eval',
      harness,
      ...arguments,
    ], workingDirectory: Directory.systemTemp.path);
  } on ProcessException catch (error) {
    fail('Node.js is required for controller tests: $error');
  }

  expect(result.exitCode, 0, reason: '${result.stderr}${result.stdout}');
}
