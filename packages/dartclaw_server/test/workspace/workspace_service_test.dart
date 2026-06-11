import 'dart:io';

import 'package:dartclaw_server/src/workspace/workspace_service.dart';
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
      expect(soulFile.readAsStringSync(), contains('Durable Behavior Updates'));
      expect(soulFile.readAsStringSync(), contains('Proactivity'));
    });

    test('writes structured USER.md and wiki README bootstrap when missing', () async {
      await service.scaffold();

      final userContent = File(p.join(tempDir.path, 'workspace', 'USER.md')).readAsStringSync();
      for (final section in [
        'Identity',
        'Goals',
        'Current Challenges',
        'Preferences',
        'Proactivity Level',
        'Not Relevant',
      ]) {
        expect(userContent, contains('## $section'));
      }

      final wikiReadme = File(p.join(tempDir.path, 'workspace', 'wiki', 'README.md'));
      expect(wikiReadme.existsSync(), isTrue);
      expect(wikiReadme.readAsStringSync(), contains('wiki/'));
      expect(wikiReadme.readAsStringSync(), contains('MEMORY.md'));
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
