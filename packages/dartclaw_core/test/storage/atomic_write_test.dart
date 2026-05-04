import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show atomicWriteJson;
import 'package:test/test.dart';

void main() {
  group('atomicWriteJson', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('atomic_write_test_');
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('50 parallel disjoint writes produce complete last-writer-wins JSON', () async {
      await Future.wait(
        List.generate(50, (index) async {
          final file = File('${tempDir.path}/target_$index.json');
          await atomicWriteJson(file, {'index': index, 'value': 'first'});
          await atomicWriteJson(file, {'index': index, 'value': 'last'});
        }),
      );

      for (var index = 0; index < 50; index++) {
        final file = File('${tempDir.path}/target_$index.json');
        final decoded = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        expect(decoded, {'index': index, 'value': 'last'});
      }
    });
  });
}
