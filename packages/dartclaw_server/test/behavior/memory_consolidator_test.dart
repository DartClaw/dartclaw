import 'dart:io';

import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late Level previousLogLevel;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('memory_consolidator_test_');
    previousLogLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
  });

  tearDown(() {
    Logger.root.level = previousLogLevel;
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('MemoryConsolidator', () {
    test('does nothing when MEMORY.md does not exist', () async {
      final dispatched = <(String, String)>[];
      final consolidator = MemoryConsolidator(
        workspaceDir: tempDir.path,
        dispatch: (sessionKey, message) async => dispatched.add((sessionKey, message)),
      );

      await consolidator.runIfNeeded();

      expect(dispatched, isEmpty);
    });

    test('does nothing when MEMORY.md is below threshold', () async {
      File('${tempDir.path}/MEMORY.md').writeAsStringSync('small');
      final dispatched = <(String, String)>[];
      final consolidator = MemoryConsolidator(
        workspaceDir: tempDir.path,
        threshold: 1024,
        dispatch: (sessionKey, message) async => dispatched.add((sessionKey, message)),
      );

      await consolidator.runIfNeeded();

      expect(dispatched, isEmpty);
    });

    test('dispatches consolidation when MEMORY.md exceeds threshold', () async {
      File('${tempDir.path}/MEMORY.md').writeAsStringSync('x' * 64);
      final dispatched = <(String, String)>[];
      final consolidator = MemoryConsolidator(
        workspaceDir: tempDir.path,
        threshold: 16,
        dispatch: (sessionKey, message) async => dispatched.add((sessionKey, message)),
      );

      await consolidator.runIfNeeded();

      expect(dispatched, hasLength(1));
      expect(dispatched.single.$2, MemoryConsolidator.consolidationPrompt);
    });

    test('logs warning on dispatch failure', () async {
      File('${tempDir.path}/MEMORY.md').writeAsStringSync('x' * 64);
      final records = <LogRecord>[];
      final sub = Logger('MemoryConsolidator').onRecord.listen(records.add);
      final consolidator = MemoryConsolidator(
        workspaceDir: tempDir.path,
        threshold: 16,
        dispatch: (_, _) async => throw Exception('boom'),
      );

      await consolidator.runIfNeeded();
      await sub.cancel();

      expect(
        records.any(
          (record) => record.level == Level.WARNING && record.message.contains('Memory consolidation failed'),
        ),
        isTrue,
      );
    });

    test('uses correct session key format', () async {
      File('${tempDir.path}/MEMORY.md').writeAsStringSync('x' * 64);
      final dispatched = <(String, String)>[];
      final consolidator = MemoryConsolidator(
        workspaceDir: tempDir.path,
        threshold: 16,
        dispatch: (sessionKey, message) async => dispatched.add((sessionKey, message)),
      );

      await consolidator.runIfNeeded();

      expect(dispatched, hasLength(1));
      final sessionKey = dispatched.single.$1;
      const prefix = 'agent:main:consolidation:';
      expect(sessionKey, startsWith(prefix));
      expect(DateTime.parse(sessionKey.substring(prefix.length)), isA<DateTime>());
    });
  });
}
