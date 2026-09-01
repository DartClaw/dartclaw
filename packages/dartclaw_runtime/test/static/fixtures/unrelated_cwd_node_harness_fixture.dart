import 'dart:io';

import 'package:test/test.dart';

import '../controller_test_support.dart';

void main() {
  test('controller assets resolve from an unrelated process working directory', () async {
    final originalDirectory = Directory.current;
    final unrelatedDirectory = Directory.systemTemp.createTempSync('dartclaw_controller_asset_cwd_');
    try {
      Directory.current = unrelatedDirectory;

      expect((await controllerAsset('shared.js')).existsSync(), isTrue);
    } finally {
      Directory.current = originalDirectory;
      unrelatedDirectory.deleteSync(recursive: true);
    }
  });

  test('node harness does not inherit the process working directory', () async {
    final originalDirectory = Directory.current;
    final unrelatedDirectory = Directory.systemTemp.createTempSync('dartclaw_controller_node_cwd_');
    File('${unrelatedDirectory.path}${Platform.pathSeparator}.dartclaw-inherited-cwd-marker')
        .writeAsStringSync('marker');
    try {
      Directory.current = unrelatedDirectory;
      await expectNodeHarness(
        "import { existsSync } from 'node:fs'; "
        "if (existsSync('.dartclaw-inherited-cwd-marker')) throw new Error('inherited cwd');",
        const [],
      );
    } finally {
      Directory.current = originalDirectory;
      unrelatedDirectory.deleteSync(recursive: true);
    }
  });
}
