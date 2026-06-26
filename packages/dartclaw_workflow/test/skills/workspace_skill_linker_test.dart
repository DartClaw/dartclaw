import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show WorkspaceSkillInventory, WorkspaceSkillLinker, skillProvisionerMarkerFile;
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
        Link(p.join(workspaceDir, '.claude', 'skills', 'dartclaw-discover-andthen-spec')).targetSync(),
        p.join(dataDir, '.claude', 'skills', 'dartclaw-discover-andthen-spec'),
      );
      expect(
        Link(p.join(workspaceDir, '.agents', 'skills', 'dartclaw-discover-andthen-plan')).targetSync(),
        p.join(dataDir, '.agents', 'skills', 'dartclaw-discover-andthen-plan'),
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
      final linker = WorkspaceSkillLinker(
        gitDirResolver: (workspace) => workspace == workspaceDir ? gitDir.path : null,
      );
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
      final linker = WorkspaceSkillLinker(gitDirResolver: (_) => effectiveGitDir.path);
      final inventory = WorkspaceSkillInventory.fromDataDir(dataDir);

      linker.materialize(
        dataDir: dataDir,
        workspaceDir: workspaceDir,
        skillNames: inventory.skillNames,
        agentMdNames: inventory.agentMdNames,
        agentTomlNames: inventory.agentTomlNames,
      );

      final exclude = File(p.join(effectiveGitDir.path, 'info', 'exclude')).readAsStringSync();
      expect(exclude, contains('/.claude/skills/dartclaw-*'));
      expect(exclude, contains('/.agents/skills/dartclaw-*'));
    });

    test('crafted gitdir file is ignored when git plumbing rejects it', () {
      final outsideGit = Directory(p.join(tempDir.path, 'outside-git'))..createSync(recursive: true);
      File(p.join(workspaceDir, '.git')).writeAsStringSync('gitdir: ${outsideGit.path}\n');
      final linker = WorkspaceSkillLinker();
      final inventory = WorkspaceSkillInventory.fromDataDir(dataDir);

      linker.materialize(
        dataDir: dataDir,
        workspaceDir: workspaceDir,
        skillNames: inventory.skillNames,
        agentMdNames: inventory.agentMdNames,
        agentTomlNames: inventory.agentTomlNames,
      );

      expect(File(p.join(outsideGit.path, 'info', 'exclude')).existsSync(), isFalse);
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
      final staleTarget = p.join(tempDir.path, 'stale', 'dartclaw-discover-andthen-spec');
      final staleLink = Link(p.join(workspaceDir, '.claude', 'skills', 'dartclaw-discover-andthen-spec'));
      staleLink.createSync(staleTarget, recursive: true);
      final linker = WorkspaceSkillLinker();

      linker.materialize(
        dataDir: dataDir,
        workspaceDir: workspaceDir,
        skillNames: const ['dartclaw-discover-andthen-spec'],
        agentMdNames: const [],
        agentTomlNames: const [],
      );

      expect(staleLink.targetSync(), p.join(dataDir, '.claude', 'skills', 'dartclaw-discover-andthen-spec'));
    });

    test('reserved dartclaw skill namespace replaces unmanaged workspace payloads', () {
      final hostileSkill = Directory(p.join(workspaceDir, '.claude', 'skills', 'dartclaw-discover-andthen-spec'))
        ..createSync(recursive: true);
      File(p.join(hostileSkill.path, 'SKILL.md')).writeAsStringSync('unmanaged\n');
      final linker = WorkspaceSkillLinker(
        linkFactory: ({required targetPath, required linkPath}) {
          Link(linkPath).createSync(targetPath);
        },
      );

      linker.materialize(
        dataDir: dataDir,
        workspaceDir: workspaceDir,
        skillNames: const ['dartclaw-discover-andthen-spec'],
        agentMdNames: const [],
        agentTomlNames: const [],
      );

      expect(
        Link(p.join(workspaceDir, '.claude', 'skills', 'dartclaw-discover-andthen-spec')).targetSync(),
        p.join(dataDir, '.claude', 'skills', 'dartclaw-discover-andthen-spec'),
      );
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
        skillNames: const ['dartclaw-discover-andthen-spec'],
        agentMdNames: const [],
        agentTomlNames: const [],
      );
      expect(
        File(
          p.join(workspaceDir, '.claude', 'skills', 'dartclaw-discover-andthen-spec', '.dartclaw-managed'),
        ).existsSync(),
        isTrue,
      );
      expect(
        File(
          p.join(workspaceDir, '.agents', 'skills', 'dartclaw-discover-andthen-spec', '.dartclaw-managed'),
        ).existsSync(),
        isTrue,
      );
      expect(copyWrites, 2);

      linker.materialize(
        dataDir: dataDir,
        workspaceDir: workspaceDir,
        skillNames: const ['dartclaw-discover-andthen-spec'],
        agentMdNames: const [],
        agentTomlNames: const [],
      );
      expect(copyWrites, 2);

      File(
        p.join(dataDir, '.claude', 'skills', 'dartclaw-discover-andthen-spec', 'SKILL.md'),
      ).writeAsStringSync('changed\n');
      linker.materialize(
        dataDir: dataDir,
        workspaceDir: workspaceDir,
        skillNames: const ['dartclaw-discover-andthen-spec'],
        agentMdNames: const [],
        agentTomlNames: const [],
      );
      expect(copyWrites, 3);
    });

    test('clean removes only managed artifacts and exact exclude lines', () {
      final operatorSkill = Directory(p.join(workspaceDir, '.claude', 'skills', 'my-custom-skill'))
        ..createSync(recursive: true);
      File(p.join(operatorSkill.path, 'SKILL.md')).writeAsStringSync('operator\n');
      final gitDir = Directory(p.join(workspaceDir, '.git'))..createSync(recursive: true);
      final linker = WorkspaceSkillLinker(
        gitDirResolver: (_) => gitDir.path,
        linkFactory: ({required targetPath, required linkPath}) {
          throw const FileSystemException('symlinks unavailable');
        },
      );

      linker.materialize(
        dataDir: dataDir,
        workspaceDir: workspaceDir,
        skillNames: const ['dartclaw-discover-andthen-spec'],
        agentMdNames: const [],
        agentTomlNames: const [],
      );
      linker.clean(workspaceDir: workspaceDir);

      expect(
        Directory(p.join(workspaceDir, '.claude', 'skills', 'dartclaw-discover-andthen-spec')).existsSync(),
        isFalse,
      );
      expect(
        Directory(p.join(workspaceDir, '.agents', 'skills', 'dartclaw-discover-andthen-spec')).existsSync(),
        isFalse,
      );
      expect(File(p.join(operatorSkill.path, 'SKILL.md')).readAsStringSync(), 'operator\n');
      expect(File(p.join(workspaceDir, '.git', 'info', 'exclude')).readAsStringSync(), isEmpty);

      linker.clean(workspaceDir: workspaceDir);
      expect(File(p.join(operatorSkill.path, 'SKILL.md')).readAsStringSync(), 'operator\n');
    });
  });

  group('WorkspaceSkillInventory.fromDataDir', () {
    late Directory tempDir;
    late String dataDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('workspace_skill_inventory_test_');
      dataDir = p.join(tempDir.path, 'data');
      _seedDataDir(dataDir);
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('without a manifest marker, discovers all managed dartclaw-* skills (cold-start fallback)', () {
      final inventory = WorkspaceSkillInventory.fromDataDir(dataDir);
      expect(inventory.skillNames, containsAll(<String>['dartclaw-discover-andthen-spec', 'dartclaw-merge-resolve']));
    });

    test('binds the inventory to the manifest marker: a stale dartclaw-* skill is never surfaced', () {
      // A stale managed skill lingers on disk after a manifest removal.
      for (final root in [p.join(dataDir, '.claude', 'skills'), p.join(dataDir, '.agents', 'skills')]) {
        File(p.join(root, 'dartclaw-old-skill', 'SKILL.md'))
          ..createSync(recursive: true)
          ..writeAsStringSync('---\nname: dartclaw-old-skill\n---\nbody\n');
      }
      // The provisioned marker is the canonical inventory and omits it.
      File(p.join(dataDir, skillProvisionerMarkerFile)).writeAsStringSync(
        const [
          'dartclaw-discover-andthen-spec',
          'dartclaw-discover-andthen-plan',
          'dartclaw-validate-workflow',
          'dartclaw-merge-resolve',
        ].join('\n'),
      );

      final inventory = WorkspaceSkillInventory.fromDataDir(dataDir);

      expect(inventory.skillNames, isNot(contains('dartclaw-old-skill')));
      expect(inventory.skillNames, contains('dartclaw-discover-andthen-spec'));
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
    for (final name in const [
      'dartclaw-discover-andthen-spec',
      'dartclaw-discover-andthen-plan',
      'dartclaw-validate-workflow',
      'dartclaw-merge-resolve',
    ]) {
      File(p.join(root, name, 'SKILL.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('---\nname: $name\n---\nbody\n');
    }
  }
}
