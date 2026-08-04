import 'dart:io';

import 'package:test/test.dart';

File controllerAsset(String name) {
  final packageRelative = File('packages/dartclaw_server/lib/src/static/controllers/$name');
  return packageRelative.existsSync() ? packageRelative : File('lib/src/static/controllers/$name');
}

Future<void> expectNodeHarness(String harness, List<String> arguments) async {
  late final ProcessResult result;
  try {
    result = await Process.run('node', ['--input-type=module', '--eval', harness, ...arguments]);
  } on ProcessException catch (error) {
    fail('Node.js is required for controller tests: $error');
  }

  expect(result.exitCode, 0, reason: '${result.stderr}${result.stdout}');
}
