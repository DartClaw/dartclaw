import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkspaceSkillInventory, WorkspaceSkillLinker;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('WorkspaceSkillLinker', () {
    late Directory tempDir;
    late String dataDir;
    late String workspaceDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('workspace_skill_linker_test_');
      dataDir = p.join(tempDir.path, 'data');
      workspaceDir = p.join(tempDir.path, 'workspace');
      Directory(workspaceDir).createSync(recursive: true);
      _seedDataDir(dataDir);
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('materialize creates DC-native per-skill symlinks idempotently', () {
      var linkWrites = 0;
      final linker = WorkspaceSkillLinker(
        linkFactory: ({required targetPath, required linkPath}) {
          linkWrites++;
          Link(linkPath).createSync(targetPath);
        },
      );
      final inventory = WorkspaceSkillInventory.fromDataDir(dataDir);

      linker.materialize(
        dataDir: dataDir,
        workspaceDir: workspaceDir,
        skillNames: inventory.skillNames,
        agentMdNames: inventory.agentMdNames,
        agentTomlNames: inventory.agentTomlNames,
      );

      expect(
        Link(p.join(workspaceDir, '.claude', 'skills', 'dartclaw-discover-project')).targetSync(),
        p.join(dataDir, '.claude', 'skills', 'dartclaw-discover-project'),
      );
      expect(
        Link(p.join(workspaceDir, '.agents', 'skills', 'dartclaw-merge-resolve')).targetSync(),
        p.join(dataDir, '.agents', 'skills', 'dartclaw-merge-resolve'),
      );

      final writesAfterFirstRun = linkWrites;
      linker.materialize(
        dataDir: dataDir,
        workspaceDir: workspaceDir,
        skillNames: inventory.skillNames,
        agentMdNames: inventory.agentMdNames,
        agentTomlNames: inventory.agentTomlNames,
      );

      expect(linkWrites, writesAfterFirstRun);
    });

    test('git exclude patterns are written once and non-git workspaces are ignored', () {
      final gitDir = Directory(p.join(workspaceDir, '.git'))..createSync(recursive: true);
      final linker = WorkspaceSkillLinker();
      final inventory = WorkspaceSkillInventory.fromDataDir(dataDir);

      linker.materialize(
        dataDir: dataDir,
        workspaceDir: workspaceDir,
        skillNames: inventory.skillNames,
        agentMdNames: inventory.agentMdNames,
        agentTomlNames: inventory.agentTomlNames,
      );
      final exclude = File(p.join(gitDir.path, 'info', 'exclude'));
      final firstContents = exclude.readAsStringSync();

      linker.materialize(
        dataDir: dataDir,
        workspaceDir: workspaceDir,
        skillNames: inventory.skillNames,
        agentMdNames: inventory.agentMdNames,
        agentTomlNames: inventory.agentTomlNames,
      );

      expect(exclude.readAsStringSync(), firstContents);
      for (final pattern in WorkspaceSkillLinker.managedExcludePatterns) {
        expect(RegExp('^${RegExp.escape(pattern)}\$', multiLine: true).allMatches(firstContents), hasLength(1));
      }

      final noGit = Directory(p.join(tempDir.path, 'no-git'))..createSync();
      linker.materialize(
        dataDir: dataDir,
        workspaceDir: noGit.path,
        skillNames: inventory.skillNames,
        agentMdNames: inventory.agentMdNames,
        agentTomlNames: inventory.agentTomlNames,
      );
      expect(Directory(p.join(noGit.path, '.git')).existsSync(), isFalse);
    });

    test('linked worktree gitdir file is resolved for exclude writes', () {
      final effectiveGitDir = Directory(p.join(tempDir.path, 'main.git', 'worktrees', 'task-1'))
        ..createSync(recursive: true);
      File(p.join(workspaceDir, '.git')).writeAsStringSync('gitdir: ${effectiveGitDir.path}\n');
      final linker = WorkspaceSkillLinker();
      final inventory = WorkspaceSkillInventory.fromDataDir(dataDir);

      linker.materialize(
        dataDir: dataDir,
        workspaceDir: workspaceDir,
        skillNames: inventory.skillNames,
        agentMdNames: inventory.agentMdNames,
        agentTomlNames: inventory.agentTomlNames,
      );

      final exclude = File(p.join(effectiveGitDir.path, 'info', 'exclude')).readAsStringSync();
      expect(exclude, contains('/.claude/skills/dartclaw-discover-project'));
      expect(exclude, contains('/.agents/skills/dartclaw-merge-resolve'));
    });

    test('materialized real git worktree remains porcelain-clean', () {
      if (!_gitAvailable()) {
        markTestSkipped('git executable unavailable');
        return;
      }
      final repoDir = Directory(p.join(tempDir.path, 'repo'))..createSync(recursive: true);
      _runGit(repoDir.path, ['init']);
      _runGit(repoDir.path, ['config', 'user.email', 'test@example.invalid']);
      _runGit(repoDir.path, ['config', 'user.name', 'Test User']);
      File(p.join(repoDir.path, 'README.md')).writeAsStringSync('# repo\n');
      _runGit(repoDir.path, ['add', 'README.md']);
      _runGit(repoDir.path, ['commit', '-m', 'init']);
      final worktreeDir = p.join(tempDir.path, 'task-worktree');
      _runGit(repoDir.path, ['worktree', 'add', '-b', 'task-1', worktreeDir]);

      final linker = WorkspaceSkillLinker();
      final inventory = WorkspaceSkillInventory.fromDataDir(dataDir);
      linker.materialize(
        dataDir: dataDir,
        workspaceDir: worktreeDir,
        skillNames: inventory.skillNames,
        agentMdNames: inventory.agentMdNames,
        agentTomlNames: inventory.agentTomlNames,
      );

      final status = _runGit(worktreeDir, ['status', '--porcelain', '--untracked-files=all']);
      expect(status.stdout, isEmpty);
    });

    test('stale symlink retargets to current data dir', () {
      final staleTarget = p.join(tempDir.path, 'stale', 'dartclaw-discover-project');
      final staleLink = Link(p.join(workspaceDir, '.claude', 'skills', 'dartclaw-discover-project'));
      staleLink.createSync(staleTarget, recursive: true);
      final linker = WorkspaceSkillLinker();

      linker.materialize(
        dataDir: dataDir,
        workspaceDir: workspaceDir,
        skillNames: const ['dartclaw-discover-project'],
        agentMdNames: const [],
        agentTomlNames: const [],
      );

      expect(staleLink.targetSync(), p.join(dataDir, '.claude', 'skills', 'dartclaw-discover-project'));
    });

    test('copy fallback writes managed markers and refreshes only on fingerprint mismatch', () {
      var copyWrites = 0;
      final linker = WorkspaceSkillLinker(
        linkFactory: ({required targetPath, required linkPath}) {
          throw const FileSystemException('symlinks unavailable');
        },
        directoryCopier: (source, destination) {
          copyWrites++;
          for (final entity in source.listSync(recursive: true, followLinks: false)) {
            final relative = p.relative(entity.path, from: source.path);
            if (entity is Directory) {
              Directory(p.join(destination.path, relative)).createSync(recursive: true);
            } else if (entity is File) {
              final target = File(p.join(destination.path, relative));
              target.parent.createSync(recursive: true);
              entity.copySync(target.path);
            }
          }
        },
      );

      linker.materialize(
        dataDir: dataDir,
        workspaceDir: workspaceDir,
        skillNames: const ['dartclaw-discover-project'],
        agentMdNames: const [],
        agentTomlNames: const [],
      );
      expect(
        File(p.join(workspaceDir, '.claude', 'skills', 'dartclaw-discover-project', '.dartclaw-managed')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(workspaceDir, '.agents', 'skills', 'dartclaw-discover-project', '.dartclaw-managed')).existsSync(),
        isTrue,
      );
      expect(copyWrites, 2);

      linker.materialize(
        dataDir: dataDir,
        workspaceDir: workspaceDir,
        skillNames: const ['dartclaw-discover-project'],
        agentMdNames: const [],
        agentTomlNames: const [],
      );
      expect(copyWrites, 2);

      File(
        p.join(dataDir, '.claude', 'skills', 'dartclaw-discover-project', 'SKILL.md'),
      ).writeAsStringSync('changed\n');
      linker.materialize(
        dataDir: dataDir,
        workspaceDir: workspaceDir,
        skillNames: const ['dartclaw-discover-project'],
        agentMdNames: const [],
        agentTomlNames: const [],
      );
      expect(copyWrites, 3);
    });

    test('clean removes only managed artifacts and exact exclude lines', () {
      final operatorSkill = Directory(p.join(workspaceDir, '.claude', 'skills', 'my-custom-skill'))
        ..createSync(recursive: true);
      File(p.join(operatorSkill.path, 'SKILL.md')).writeAsStringSync('operator\n');
      Directory(p.join(workspaceDir, '.git')).createSync(recursive: true);
      final linker = WorkspaceSkillLinker(
        linkFactory: ({required targetPath, required linkPath}) {
          throw const FileSystemException('symlinks unavailable');
        },
      );

      linker.materialize(
        dataDir: dataDir,
        workspaceDir: workspaceDir,
        skillNames: const ['dartclaw-discover-project'],
        agentMdNames: const [],
        agentTomlNames: const [],
      );
      linker.clean(workspaceDir: workspaceDir);

      expect(Directory(p.join(workspaceDir, '.claude', 'skills', 'dartclaw-discover-project')).existsSync(), isFalse);
      expect(Directory(p.join(workspaceDir, '.agents', 'skills', 'dartclaw-discover-project')).existsSync(), isFalse);
      expect(File(p.join(operatorSkill.path, 'SKILL.md')).readAsStringSync(), 'operator\n');
      expect(File(p.join(workspaceDir, '.git', 'info', 'exclude')).readAsStringSync(), isEmpty);

      linker.clean(workspaceDir: workspaceDir);
      expect(File(p.join(operatorSkill.path, 'SKILL.md')).readAsStringSync(), 'operator\n');
    });
  });
}

bool _gitAvailable() {
  final result = Process.runSync('git', ['--version']);
  return result.exitCode == 0;
}

ProcessResult _runGit(String workingDirectory, List<String> arguments) {
  final result = Process.runSync('git', arguments, workingDirectory: workingDirectory);
  if (result.exitCode != 0) {
    fail('git ${arguments.join(' ')} failed: ${result.stderr}');
  }
  return result;
}

void _seedDataDir(String dataDir) {
  for (final root in [p.join(dataDir, '.claude', 'skills'), p.join(dataDir, '.agents', 'skills')]) {
    for (final name in const ['dartclaw-discover-project', 'dartclaw-validate-workflow', 'dartclaw-merge-resolve']) {
      File(p.join(root, name, 'SKILL.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('---\nname: $name\n---\nbody\n');
    }
  }
}
