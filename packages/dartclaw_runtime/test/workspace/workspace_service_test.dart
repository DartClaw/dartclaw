import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart' show AgentWorkspace;
import 'package:dartclaw_runtime/src/workspace/workspace_service.dart';
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

  group('managed agents', () {
    AgentWorkspace binding(String id) =>
        AgentWorkspace.managed(agentId: id, dataDir: tempDir.path, ownerWorkspaceDir: service.workspaceDir);

    test('commits the id-only marker before scaffolding an isolated workspace', () async {
      final workspace = binding('a');

      await service.prepareManagedAgents([workspace]);

      final marker = File(p.join(tempDir.path, 'agents', 'a', 'identity.json'));
      expect(marker.readAsStringSync(), '{"agentId":"a"}\n');
      expect(marker.path, isNot(startsWith(workspace.directory)));
      for (final name in ['AGENTS.md', 'SOUL.md', 'USER.md', 'TOOLS.md']) {
        expect(File(p.join(workspace.directory, name)).existsSync(), isTrue, reason: name);
      }
      expect(Directory(p.join(workspace.directory, 'wiki')).existsSync(), isFalse);
    });

    test('resumes marker-only preparation and preserves copied retained data', () async {
      final workspace = binding('a');
      final home = Directory(p.dirname(workspace.directory))..createSync(recursive: true);
      final marker = File(p.join(home.path, 'identity.json'))..writeAsStringSync('{"agentId":"a"}\n');

      await service.prepareManagedAgents([workspace]);
      File(p.join(workspace.directory, 'MEMORY.md')).writeAsStringSync('retained');
      File(p.join(workspace.directory, 'SOUL.md')).writeAsStringSync('custom');
      await service.prepareManagedAgents([workspace]);

      expect(marker.readAsStringSync(), '{"agentId":"a"}\n');
      expect(File(p.join(workspace.directory, 'MEMORY.md')).readAsStringSync(), 'retained');
      expect(File(p.join(workspace.directory, 'SOUL.md')).readAsStringSync(), 'custom');
    });

    test('retries a fresh home after an interrupted marker staging write', () async {
      final workspace = binding('a');
      final agentsRoot = Directory(p.join(tempDir.path, 'agents'))..createSync();
      Directory(p.dirname(workspace.directory)).createSync();
      final staging = File(p.join(agentsRoot.path, '.identity-a.json'))..writeAsStringSync('partial');

      await service.prepareManagedAgents([workspace]);

      expect(staging.existsSync(), isFalse);
      expect(File(p.join(p.dirname(workspace.directory), 'identity.json')).readAsStringSync(), '{"agentId":"a"}\n');
    });

    test('validates every home before mutating any of them', () async {
      final first = binding('a');
      final second = binding('b');
      final secondHome = Directory(p.dirname(second.directory))..createSync(recursive: true);
      final retained = File(p.join(secondHome.path, 'retained.txt'))..writeAsStringSync('do not adopt');

      await expectLater(service.prepareManagedAgents([first, second]), throwsA(isA<StateError>()));

      expect(Directory(p.dirname(first.directory)).existsSync(), isFalse);
      expect(retained.readAsStringSync(), 'do not adopt');
      expect(File(p.join(secondHome.path, 'identity.json')).existsSync(), isFalse);
    });

    test('refuses malformed and mismatched markers without changing bytes', () async {
      final workspace = binding('a');
      final home = Directory(p.dirname(workspace.directory))..createSync(recursive: true);
      final marker = File(p.join(home.path, 'identity.json'));
      for (final contents in [
        'not-json',
        '{"agentId":"b"}',
        '{"agentId":"a","path":"elsewhere"}',
        '{"agentId":"a"}',
        '{\n  "agentId": "a"\n}\n',
      ]) {
        marker.writeAsStringSync(contents);

        expect(() => service.validateManagedAgents([workspace]), throwsA(isA<StateError>()), reason: contents);
        expect(marker.readAsStringSync(), contents);
        expect(Directory(workspace.directory).existsSync(), isFalse);
      }
    });

    test('refuses symlinks in the managed root, home, marker and workspace', () async {
      final outside = Directory.systemTemp.createTempSync('managed_agent_link_target_');
      addTearDown(() {
        if (outside.existsSync()) outside.deleteSync(recursive: true);
      });
      final workspace = binding('a');
      final agentsRoot = p.join(tempDir.path, 'agents');

      Link(agentsRoot).createSync(outside.path);
      expect(() => service.validateManagedAgents([workspace]), throwsA(isA<StateError>()));
      Link(agentsRoot).deleteSync();

      Directory(agentsRoot).createSync();
      final home = p.dirname(workspace.directory);
      Link(home).createSync(outside.path);
      expect(() => service.validateManagedAgents([workspace]), throwsA(isA<StateError>()));
      Link(home).deleteSync();

      Directory(home).createSync();
      final markerTarget = File(p.join(outside.path, 'marker'))..writeAsStringSync('{}');
      Link(p.join(home, 'identity.json')).createSync(markerTarget.path);
      expect(() => service.validateManagedAgents([workspace]), throwsA(isA<StateError>()));
      Link(p.join(home, 'identity.json')).deleteSync();

      File(p.join(home, 'identity.json')).writeAsStringSync('{"agentId":"a"}\n');
      Link(workspace.directory).createSync(outside.path);
      expect(() => service.validateManagedAgents([workspace]), throwsA(isA<StateError>()));
    });

    test('refuses an owner workspace link into a managed home', () {
      final workspace = binding('a');
      Link(service.workspaceDir).createSync(workspace.directory, recursive: true);

      expect(
        () => service.validateManagedAgents([workspace]),
        throwsA(
          isA<StateError>().having((error) => error.message, 'message', contains('overlaps the owner workspace')),
        ),
      );
      expect(Directory(p.dirname(workspace.directory)).existsSync(), isFalse);
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
