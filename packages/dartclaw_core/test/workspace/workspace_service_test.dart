import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late WorkspaceService service;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_workspace_test_');
    service = WorkspaceService(dataDir: tempDir.path);
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('scaffold', () {
    test('creates workspace, sessions, and logs directories', () async {
      await service.scaffold();

      expect(Directory(p.join(tempDir.path, 'workspace')).existsSync(), isTrue);
      expect(Directory(p.join(tempDir.path, 'sessions')).existsSync(), isTrue);
      expect(Directory(p.join(tempDir.path, 'logs')).existsSync(), isTrue);
    });

    test('writes default AGENTS.md when missing', () async {
      await service.scaffold();

      final agentsFile = File(p.join(tempDir.path, 'workspace', 'AGENTS.md'));
      expect(agentsFile.existsSync(), isTrue);
      final content = agentsFile.readAsStringSync();
      expect(content, contains('Agent Safety Rules'));
      expect(content, contains('NEVER exfiltrate'));
    });

    test('writes default SOUL.md when missing', () async {
      await service.scaffold();

      final soulFile = File(p.join(tempDir.path, 'workspace', 'SOUL.md'));
      expect(soulFile.existsSync(), isTrue);
      expect(soulFile.readAsStringSync(), contains('helpful, capable AI assistant'));
    });

    test('is idempotent — does not overwrite existing files', () async {
      await service.scaffold();

      // Modify AGENTS.md
      final agentsFile = File(p.join(tempDir.path, 'workspace', 'AGENTS.md'));
      agentsFile.writeAsStringSync('Custom rules');

      // Scaffold again
      await service.scaffold();

      expect(agentsFile.readAsStringSync(), 'Custom rules');
    });
  });

  group('migrate', () {
    test('is a no-op if workspace/ already exists', () async {
      Directory(p.join(tempDir.path, 'workspace')).createSync();

      // Put a file in root — should NOT be moved
      File(p.join(tempDir.path, 'SOUL.md')).writeAsStringSync('root soul');

      await service.migrate();

      // Original still at root (not moved)
      expect(File(p.join(tempDir.path, 'SOUL.md')).existsSync(), isTrue);
    });

    test('copies MVP files to workspace/ and removes originals', () async {
      File(p.join(tempDir.path, 'SOUL.md')).writeAsStringSync('My soul');
      File(p.join(tempDir.path, 'MEMORY.md')).writeAsStringSync('My memory');

      await service.migrate();

      // Files moved to workspace/
      expect(File(p.join(tempDir.path, 'workspace', 'SOUL.md')).readAsStringSync(), 'My soul');
      expect(File(p.join(tempDir.path, 'workspace', 'MEMORY.md')).readAsStringSync(), 'My memory');

      // Originals removed
      expect(File(p.join(tempDir.path, 'SOUL.md')).existsSync(), isFalse);
      expect(File(p.join(tempDir.path, 'MEMORY.md')).existsSync(), isFalse);
    });

    test('copies CLAUDE.md if present', () async {
      File(p.join(tempDir.path, 'CLAUDE.md')).writeAsStringSync('Legacy claude');

      await service.migrate();

      expect(File(p.join(tempDir.path, 'workspace', 'CLAUDE.md')).readAsStringSync(), 'Legacy claude');
      expect(File(p.join(tempDir.path, 'CLAUDE.md')).existsSync(), isFalse);
    });

    test('copies memory/ directory recursively', () async {
      final memDir = Directory(p.join(tempDir.path, 'memory'))..createSync();
      File(p.join(memDir.path, '2026-01-01.md')).writeAsStringSync('Day 1 log');
      Directory(p.join(memDir.path, 'sub')).createSync();
      File(p.join(memDir.path, 'sub', 'nested.md')).writeAsStringSync('Nested content');

      await service.migrate();

      expect(File(p.join(tempDir.path, 'workspace', 'memory', '2026-01-01.md')).readAsStringSync(), 'Day 1 log');
      expect(
        File(p.join(tempDir.path, 'workspace', 'memory', 'sub', 'nested.md')).readAsStringSync(),
        'Nested content',
      );
      // Original dir removed
      expect(Directory(p.join(tempDir.path, 'memory')).existsSync(), isFalse);
    });

    test('no-op when no MVP files exist', () async {
      await service.migrate();

      // workspace/ not created by migrate when nothing to migrate
      expect(Directory(p.join(tempDir.path, 'workspace')).existsSync(), isFalse);
    });

    test('leaves originals intact when workspace creation fails', () async {
      File(p.join(tempDir.path, 'SOUL.md')).writeAsStringSync('precious content');

      // Block workspace creation by placing a file at the expected directory path
      File(p.join(tempDir.path, 'workspace')).writeAsStringSync('blocker');

      await expectLater(service.migrate(), throwsA(isA<WorkspaceMigrationException>()));

      // Original preserved
      expect(File(p.join(tempDir.path, 'SOUL.md')).readAsStringSync(), 'precious content');
    });
  });

  group('getters', () {
    test('workspaceDir returns dataDir/workspace', () {
      expect(service.workspaceDir, p.join(tempDir.path, 'workspace'));
    });

    test('logsDir returns dataDir/logs', () {
      expect(service.logsDir, p.join(tempDir.path, 'logs'));
    });

    test('sessionsDir returns dataDir/sessions', () {
      expect(service.sessionsDir, p.join(tempDir.path, 'sessions'));
    });
  });
}
