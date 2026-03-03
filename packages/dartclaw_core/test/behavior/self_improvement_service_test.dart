import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmpDir;
  late SelfImprovementService service;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('self_improvement_test_');
    service = SelfImprovementService(workspaceDir: tmpDir.path);
  });

  tearDown(() async {
    await service.dispose();
    tmpDir.deleteSync(recursive: true);
  });

  group('appendError', () {
    test('creates errors.md with formatted entry', () async {
      await service.appendError(
        errorType: 'GUARD_BLOCK',
        sessionId: 'sess-1',
        context: 'Blocked prompt injection attempt',
      );

      final content = await service.readErrors();
      expect(content, contains('## ['));
      expect(content, contains('GUARD_BLOCK'));
      expect(content, contains('- Session: sess-1'));
      expect(content, contains('- Context: Blocked prompt injection attempt'));
    });

    test('includes resolution when provided', () async {
      await service.appendError(
        errorType: 'TURN_FAILURE',
        sessionId: 'sess-2',
        context: 'Agent crashed',
        resolution: 'Retried successfully',
      );

      final content = await service.readErrors();
      expect(content, contains('- Resolution: Retried successfully'));
    });

    test('appends multiple entries', () async {
      await service.appendError(errorType: 'ERR_1', sessionId: 's1', context: 'first');
      await service.appendError(errorType: 'ERR_2', sessionId: 's2', context: 'second');

      final content = await service.readErrors();
      expect('## ['.allMatches(content).length, equals(2));
      expect(content, contains('ERR_1'));
      expect(content, contains('ERR_2'));
    });
  });

  group('appendLearning', () {
    test('creates learnings.md with formatted entry', () async {
      await service.appendLearning(text: 'Always validate input before parsing');

      final content = await service.readLearnings();
      expect(content, contains('- ['));
      expect(content, contains('Always validate input before parsing'));
    });

    test('appends multiple learnings', () async {
      await service.appendLearning(text: 'Learning one');
      await service.appendLearning(text: 'Learning two');

      final content = await service.readLearnings();
      expect('- ['.allMatches(content).length, equals(2));
    });
  });

  group('cap enforcement', () {
    test('trims oldest errors when cap exceeded', () async {
      final small = SelfImprovementService(workspaceDir: tmpDir.path, maxEntries: 3);
      addTearDown(() => small.dispose());

      for (var i = 0; i < 5; i++) {
        await small.appendError(errorType: 'ERR_$i', sessionId: 's$i', context: 'ctx $i');
      }

      final content = await small.readErrors();
      // Should have exactly 3 entries (the last 3)
      expect('## ['.allMatches(content).length, equals(3));
      expect(content, isNot(contains('ERR_0')));
      expect(content, isNot(contains('ERR_1')));
      expect(content, contains('ERR_2'));
      expect(content, contains('ERR_3'));
      expect(content, contains('ERR_4'));
    });

    test('trims oldest learnings when cap exceeded', () async {
      final small = SelfImprovementService(workspaceDir: tmpDir.path, maxEntries: 3);
      addTearDown(() => small.dispose());

      for (var i = 0; i < 5; i++) {
        await small.appendLearning(text: 'Learning $i');
      }

      final content = await small.readLearnings();
      expect('- ['.allMatches(content).length, equals(3));
      expect(content, isNot(contains('Learning 0')));
      expect(content, isNot(contains('Learning 1')));
      expect(content, contains('Learning 2'));
      expect(content, contains('Learning 3'));
      expect(content, contains('Learning 4'));
    });
  });

  group('readErrors / readLearnings', () {
    test('returns empty string for missing files', () async {
      expect(await service.readErrors(), isEmpty);
      expect(await service.readLearnings(), isEmpty);
    });

    test('returns file content when present', () async {
      File('${tmpDir.path}/errors.md').writeAsStringSync('## [2025-01-01] TEST\n');
      final content = await service.readErrors();
      expect(content, equals('## [2025-01-01] TEST\n'));
    });
  });

  group('atomic writes', () {
    test('no .tmp file remains after write', () async {
      await service.appendError(errorType: 'TEST', sessionId: 's1', context: 'ctx');

      final tmpFile = File('${tmpDir.path}/errors.md.tmp');
      expect(tmpFile.existsSync(), isFalse);
    });
  });

  group('concurrent writes', () {
    test('all writes complete without corruption', () async {
      final futures = <Future<void>>[];
      for (var i = 0; i < 10; i++) {
        futures.add(service.appendError(errorType: 'ERR_$i', sessionId: 's$i', context: 'ctx $i'));
      }
      await Future.wait(futures);

      final content = await service.readErrors();
      expect('## ['.allMatches(content).length, equals(10));
    });
  });
}
