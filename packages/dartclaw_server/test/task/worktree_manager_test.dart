import 'dart:io';

import 'package:dartclaw_server/src/task/worktree_manager.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('WorktreeManager (real git)', () {
    late Directory tmpDir;
    late String projectDir;
    late String dataDir;

    setUp(() async {
      tmpDir = Directory.systemTemp.createTempSync('worktree_test_');
      projectDir = p.join(tmpDir.path, 'project');
      dataDir = p.join(tmpDir.path, 'data');
      Directory(projectDir).createSync();
      Directory(dataDir).createSync();

      // Initialize a real git repo with an initial commit
      await Process.run('git', ['init'], workingDirectory: projectDir);
      await Process.run('git', ['checkout', '-b', 'main'], workingDirectory: projectDir);
      File(p.join(projectDir, 'README.md')).writeAsStringSync('# Test');
      await Process.run('git', ['add', '.'], workingDirectory: projectDir);
      await Process.run(
        'git',
        ['commit', '-m', 'initial', '--no-gpg-sign'],
        workingDirectory: projectDir,
        environment: {
          'GIT_AUTHOR_NAME': 'Test',
          'GIT_AUTHOR_EMAIL': 'test@test.com',
          'GIT_COMMITTER_NAME': 'Test',
          'GIT_COMMITTER_EMAIL': 'test@test.com',
        },
      );
    });

    tearDown(() {
      tmpDir.deleteSync(recursive: true);
    });

    test('create() produces worktree at expected path with expected branch name', () async {
      final manager = WorktreeManager(dataDir: dataDir, projectDir: projectDir);

      final info = await manager.create('abc123');

      expect(info.path, equals(p.join(dataDir, 'worktrees', 'abc123')));
      expect(info.branch, equals('dartclaw/task-abc123'));
      expect(Directory(info.path).existsSync(), isTrue);

      // Verify the branch exists
      final branchResult = await Process.run('git', [
        'branch',
        '--list',
        'dartclaw/task-abc123',
      ], workingDirectory: projectDir);
      expect((branchResult.stdout as String).trim(), isNotEmpty);
    });

    test('create() appends -N suffix when branch already exists', () async {
      final manager = WorktreeManager(dataDir: dataDir, projectDir: projectDir);

      // Create a branch that will collide
      await Process.run('git', ['branch', 'dartclaw/task-collide', 'main'], workingDirectory: projectDir);

      final info = await manager.create('collide');
      expect(info.branch, equals('dartclaw/task-collide-2'));
    });

    test('cleanup() removes worktree directory and branch', () async {
      final manager = WorktreeManager(dataDir: dataDir, projectDir: projectDir);

      final info = await manager.create('cleanup-test');
      expect(Directory(info.path).existsSync(), isTrue);

      await manager.cleanup('cleanup-test');

      expect(Directory(info.path).existsSync(), isFalse);

      // Verify branch is deleted
      final branchResult = await Process.run('git', ['branch', '--list', info.branch], workingDirectory: projectDir);
      expect((branchResult.stdout as String).trim(), isEmpty);
    });

    test('cleanup() logs warning on failure (does not throw)', () async {
      final manager = WorktreeManager(dataDir: dataDir, projectDir: projectDir);

      // Cleanup a non-existent task should not throw
      await manager.cleanup('nonexistent');
    });

    test('getWorktreeInfo() returns info for existing worktree', () async {
      final manager = WorktreeManager(dataDir: dataDir, projectDir: projectDir);

      await manager.create('info-test');
      final info = manager.getWorktreeInfo('info-test');
      expect(info, isNotNull);
      expect(info!.branch, equals('dartclaw/task-info-test'));
    });

    test('getWorktreeInfo() returns null for non-existent worktree', () {
      final manager = WorktreeManager(dataDir: dataDir, projectDir: projectDir);

      expect(manager.getWorktreeInfo('nonexistent'), isNull);
    });

    test('detectStaleWorktrees() does not throw for empty directory', () async {
      final manager = WorktreeManager(dataDir: dataDir, projectDir: projectDir);

      // Should not throw when worktrees dir doesn't exist
      await manager.detectStaleWorktrees();
    });

    test('detectStaleWorktrees() does not throw for fresh worktrees', () async {
      final manager = WorktreeManager(dataDir: dataDir, projectDir: projectDir);

      await manager.create('fresh-task');
      await manager.detectStaleWorktrees();
    });
  });

  group('WorktreeManager (mocked git)', () {
    test('create() throws GitNotFoundException when git not available', () async {
      final manager = WorktreeManager(
        dataDir: '/tmp/test-data',
        projectDir: '/tmp/test-project',
        processRunner: (executable, arguments, {String? workingDirectory}) async {
          if (arguments.contains('--version')) {
            return ProcessResult(0, 1, '', 'git: command not found');
          }
          return ProcessResult(0, 0, '', '');
        },
      );

      expect(() => manager.create('task-1'), throwsA(isA<GitNotFoundException>()));
    });

    test('create() throws WorktreeException on git failure with stderr', () async {
      var callCount = 0;
      final manager = WorktreeManager(
        dataDir: '/tmp/test-data',
        projectDir: '/tmp/test-project',
        processRunner: (executable, arguments, {String? workingDirectory}) async {
          callCount++;
          if (callCount == 1) {
            // git --version succeeds
            return ProcessResult(0, 0, 'git version 2.40.0', '');
          }
          if (arguments.contains('--list')) {
            // branch does not exist
            return ProcessResult(0, 0, '', '');
          }
          if (arguments.first == 'branch') {
            // branch creation fails
            return ProcessResult(0, 128, '', 'fatal: not a valid ref: main');
          }
          return ProcessResult(0, 0, '', '');
        },
      );

      expect(
        () => manager.create('task-1'),
        throwsA(isA<WorktreeException>().having((e) => e.gitStderr, 'gitStderr', contains('not a valid ref'))),
      );
    });
  });

  group('WorktreeInfo', () {
    test('toJson and fromJson round-trip', () {
      final info = WorktreeInfo(
        path: '/data/worktrees/task-1',
        branch: 'dartclaw/task-1',
        createdAt: DateTime.utc(2026, 3, 9, 12, 0, 0),
      );

      final json = info.toJson();
      final restored = WorktreeInfo.fromJson(json);

      expect(restored.path, equals(info.path));
      expect(restored.branch, equals(info.branch));
      expect(restored.createdAt, equals(info.createdAt));
    });
  });

  group('WorktreeException', () {
    test('toString includes message, stderr, and exit code', () {
      const ex = WorktreeException('Failed to create', gitStderr: 'fatal: error', exitCode: 128);
      final str = ex.toString();
      expect(str, contains('Failed to create'));
      expect(str, contains('fatal: error'));
      expect(str, contains('128'));
    });

    test('toString works with null stderr and exitCode', () {
      const ex = WorktreeException('Simple error');
      expect(ex.toString(), equals('WorktreeException: Simple error'));
    });
  });
}
