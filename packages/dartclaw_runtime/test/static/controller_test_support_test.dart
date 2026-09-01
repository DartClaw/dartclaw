import 'dart:io';

import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  test('controller test support is independent of the process working directory', () async {
    final packageRoot = await resolveServerPackageRoot();
    final fixture = await resolveServerPackagePath(
      'test',
      'static',
      'fixtures',
      'unrelated_cwd_node_harness_fixture.dart',
    );

    final result = await Process.run(Platform.resolvedExecutable, [
      'test',
      fixture,
      '--reporter=failures-only',
    ], workingDirectory: packageRoot);

    expect(result.exitCode, 0, reason: '${result.stderr}${result.stdout}');
  });
}
