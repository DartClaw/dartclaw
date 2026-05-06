import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_cli/src/commands/workflow/workflow_cleanup_skills_command.dart';
import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkspaceSkillLinker;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('WorkflowCleanupSkillsCommand', () {
    late Directory tempDir;
    late Directory projectDir;
    late List<String> output;
    late int? exitCode;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('workflow_cleanup_skills_command_test_');
      projectDir = Directory(p.join(tempDir.path, 'project'))..createSync(recursive: true);
      output = [];
      exitCode = null;
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('cleans DartClaw-managed artifacts from configured project workspaces', () async {
      _seedManagedWorkspaceArtifacts(projectDir.path);
      final command = WorkflowCleanupSkillsCommand(
        config: DartclawConfig(
          server: ServerConfig(dataDir: tempDir.path),
          projects: ProjectConfig(
            definitions: {'alpha': ProjectDefinition(id: 'alpha', localPath: projectDir.path, branch: 'main')},
          ),
        ),
        writeLine: output.add,
        exitFn: (code) => exitCode = code,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await runner.run(['cleanup-skills']);

      expect(Directory(p.join(projectDir.path, '.claude', 'skills', 'dartclaw-prd')).existsSync(), isFalse);
      expect(File(p.join(projectDir.path, '.claude', 'agents', 'dartclaw-review.md')).existsSync(), isFalse);
      expect(File(p.join(projectDir.path, '.git', 'info', 'exclude')).readAsStringSync(), 'operator-owned\n');
      expect(output, contains('Cleaned workflow skill links: ${projectDir.path}'));
      expect(exitCode, 0);
    });

    test('with no configured projects defaults to the current workspace', () async {
      _seedManagedWorkspaceArtifacts(projectDir.path);
      final command = WorkflowCleanupSkillsCommand(
        config: DartclawConfig(server: ServerConfig(dataDir: tempDir.path)),
        writeLine: output.add,
        exitFn: (code) => exitCode = code,
        currentDirectory: projectDir.path,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await runner.run(['cleanup-skills']);

      expect(Directory(p.join(projectDir.path, '.agents', 'skills', 'dartclaw-prd')).existsSync(), isFalse);
      expect(output, contains('Cleaned workflow skill links: ${projectDir.path}'));
      expect(exitCode, 0);
    });

    test('cleans additional workspace arguments', () async {
      final worktreeDir = Directory(p.join(tempDir.path, 'worktree'))..createSync(recursive: true);
      _seedManagedWorkspaceArtifacts(worktreeDir.path);
      final command = WorkflowCleanupSkillsCommand(
        config: DartclawConfig(server: ServerConfig(dataDir: tempDir.path)),
        writeLine: output.add,
        exitFn: (code) => exitCode = code,
        currentDirectory: projectDir.path,
      );
      final runner = CommandRunner<void>('dartclaw', 'test')..addCommand(command);

      await runner.run(['cleanup-skills', '--workspace', worktreeDir.path]);

      expect(Directory(p.join(worktreeDir.path, '.claude', 'skills', 'dartclaw-prd')).existsSync(), isFalse);
      expect(output, contains('Cleaned workflow skill links: ${worktreeDir.path}'));
      expect(exitCode, 0);
    });
  });
}

void _seedManagedWorkspaceArtifacts(String workspaceDir) {
  for (final skillRoot in [p.join(workspaceDir, '.claude', 'skills'), p.join(workspaceDir, '.agents', 'skills')]) {
    final skill = Directory(p.join(skillRoot, 'dartclaw-prd'))..createSync(recursive: true);
    File(p.join(skill.path, 'SKILL.md')).writeAsStringSync('# dartclaw-prd\n');
    File(p.join(skill.path, WorkspaceSkillLinker.managedMarkerName)).writeAsStringSync('{"fingerprint":"abc"}');
  }
  final agent = File(p.join(workspaceDir, '.claude', 'agents', 'dartclaw-review.md'))
    ..createSync(recursive: true)
    ..writeAsStringSync('# dartclaw-review\n');
  File('${agent.path}.${WorkspaceSkillLinker.managedMarkerName}').writeAsStringSync('{"fingerprint":"abc"}');
  final gitExclude = File(p.join(workspaceDir, '.git', 'info', 'exclude'))..createSync(recursive: true);
  gitExclude.writeAsStringSync('operator-owned\n${WorkspaceSkillLinker.managedExcludePatterns.join('\n')}\n');
}
