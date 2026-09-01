import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/api/config_apply_service.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String configPath;
  late String dataDir;
  late ConfigApplyService service;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('config_apply_service_test_');
    configPath = p.join(tempDir.path, 'dartclaw.yaml');
    dataDir = p.join(tempDir.path, 'data');
    Directory(dataDir).createSync();
    File(configPath).writeAsStringSync('''
governance:
  turn_limits:
    stall_timeout: 5m
    turn_timeout: 30m
''');
    service = ConfigApplyService(
      writer: ConfigWriter(configPath: configPath),
      validator: const ConfigValidator(),
      dataDir: dataDir,
    );
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  test('malformed and incoherent partial turn-limit writes are refused atomically', () async {
    for (final testCase in const [
      (updates: {'governance.turn_limits.turn_timeout': 'bogus'}, field: 'governance.turn_limits.turn_timeout'),
      (updates: {'governance.turn_limits.turn_timeout': '5m'}, field: 'governance.turn_limits.stall_timeout'),
    ]) {
      final before = File(configPath).readAsStringSync();

      final result = await service.apply(testCase.updates);

      expect(result.errors, hasLength(1));
      expect(result.errors.single.field, testCase.field);
      expect(result.applied, isEmpty);
      expect(result.pendingRestart, isEmpty);
      expect(File(configPath).readAsStringSync(), before);
      expect(File(p.join(dataDir, 'restart.pending')).existsSync(), isFalse);
    }
  });
}
