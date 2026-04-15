import 'dart:io';

import 'package:dartclaw_models/dartclaw_models.dart';
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

    test('projectDir defaults to cwd when omitted', () {
      // Should not throw — constructor accepts optional projectDir.
      final manager = WorktreeManager(dataDir: '/tmp/test-data');
      expect(manager, isNotNull);
    });

    group('project-aware create()', () {
      late List<({String executable, List<String> arguments, String? workingDirectory})> calls;

      setUp(() {
        calls = [];
      });

      Future<ProcessResult> Function(String, List<String>, {String? workingDirectory}) recordingRunner({
        Map<String, String>? stdoutByArg,
        int branchListExitCode = 0,
        int worktreeExitCode = 0,
      }) {
        return (executable, arguments, {String? workingDirectory}) async {
          calls.add((executable: executable, arguments: arguments, workingDirectory: workingDirectory));
          if (arguments.contains('--version')) return ProcessResult(0, 0, 'git version 2', '');
          if (arguments.contains('--list')) return ProcessResult(0, branchListExitCode, '', '');
          if (arguments.contains('worktree')) return ProcessResult(0, worktreeExitCode, '', '');
          return ProcessResult(0, 0, '', '');
        };
      }

      test('create() with project uses project.localPath as working directory', () async {
        final project = Project(
          id: 'my-app',
          name: 'My App',
          remoteUrl: 'git@github.com:u/my-app.git',
          localPath: '/data/projects/my-app',
          defaultBranch: 'main',
          status: ProjectStatus.ready,
          createdAt: DateTime.now(),
        );

        final manager = WorktreeManager(dataDir: '/tmp/test-data', processRunner: recordingRunner());

        await manager.create('task-1', project: project);

        // All git calls after --version should target project.localPath
        final gitCalls = calls.where((c) => !c.arguments.contains('--version')).toList();
        for (final call in gitCalls) {
          expect(call.workingDirectory, equals('/data/projects/my-app'));
        }
      });

      test('create() with project uses origin/<defaultBranch> as start point', () async {
        final project = Project(
          id: 'my-app',
          name: 'My App',
          remoteUrl: 'git@github.com:u/my-app.git',
          localPath: '/data/projects/my-app',
          defaultBranch: 'develop',
          status: ProjectStatus.ready,
          createdAt: DateTime.now(),
        );

        final manager = WorktreeManager(dataDir: '/tmp/test-data', processRunner: recordingRunner());

        await manager.create('task-1', project: project);

        // The worktree add call should include origin/develop as startpoint
        final worktreeCall = calls.firstWhere((c) => c.arguments.contains('worktree'));
        expect(worktreeCall.arguments, contains('origin/develop'));
      });

      test('create() with project honors explicit baseRef overrides', () async {
        final project = Project(
          id: 'my-app',
          name: 'My App',
          remoteUrl: 'git@github.com:u/my-app.git',
          localPath: '/data/projects/my-app',
          defaultBranch: 'develop',
          status: ProjectStatus.ready,
          createdAt: DateTime.now(),
        );

        final manager = WorktreeManager(dataDir: '/tmp/test-data', processRunner: recordingRunner());

        await manager.create('task-1', project: project, baseRef: 'origin/release/0.16');

        final worktreeCall = calls.firstWhere((c) => c.arguments.contains('worktree'));
        expect(worktreeCall.arguments, contains('origin/release/0.16'));
        expect(worktreeCall.arguments, isNot(contains('origin/develop')));
      });

      test('create() with project normalizes raw branch overrides to remote-tracking refs', () async {
        final project = Project(
          id: 'my-app',
          name: 'My App',
          remoteUrl: 'git@github.com:u/my-app.git',
          localPath: '/data/projects/my-app',
          defaultBranch: 'develop',
          status: ProjectStatus.ready,
          createdAt: DateTime.now(),
        );

        final manager = WorktreeManager(dataDir: '/tmp/test-data', processRunner: recordingRunner());

        await manager.create('task-1', project: project, baseRef: 'release/0.16');

        final worktreeCall = calls.firstWhere((c) => c.arguments.contains('worktree'));
        expect(worktreeCall.arguments, contains('origin/release/0.16'));
      });

      test('create() with project uses single-step git worktree add -b', () async {
        final project = Project(
          id: 'my-app',
          name: 'My App',
          remoteUrl: 'git@github.com:u/my-app.git',
          localPath: '/data/projects/my-app',
          defaultBranch: 'main',
          status: ProjectStatus.ready,
          createdAt: DateTime.now(),
        );

        final manager = WorktreeManager(dataDir: '/tmp/test-data', processRunner: recordingRunner());

        await manager.create('task-1', project: project);

        // Should be a single worktree add with -b flag, no separate git branch command
        final worktreeCall = calls.firstWhere((c) => c.arguments.contains('worktree'));
        expect(worktreeCall.arguments, contains('-b'));
        // No separate 'git branch' create command (only --list for collision check)
        final branchCreateCalls = calls.where((c) => c.arguments.first == 'branch' && !c.arguments.contains('--list'));
        expect(branchCreateCalls, isEmpty);
      });

      test('create() without project uses existing two-step behavior', () async {
        final manager = WorktreeManager(
          dataDir: '/tmp/test-data',
          projectDir: '/tmp/test-project',
          processRunner: recordingRunner(),
        );

        await manager.create('task-1');

        // Should include git branch create (non-list) and git worktree add (without -b)
        final branchCreateCalls = calls.where((c) => c.arguments.first == 'branch' && !c.arguments.contains('--list'));
        expect(branchCreateCalls, isNotEmpty);
      });

      test('cleanup() with project uses project.localPath', () async {
        final project = Project(
          id: 'my-app',
          name: 'My App',
          remoteUrl: 'git@github.com:u/my-app.git',
          localPath: '/data/projects/my-app',
          defaultBranch: 'main',
          status: ProjectStatus.ready,
          createdAt: DateTime.now(),
        );

        final manager = WorktreeManager(
          dataDir: '/tmp/test-data',
          projectDir: '/tmp/default-project',
          processRunner: recordingRunner(),
        );

        await manager.cleanup('task-1', project: project);

        // Git cleanup calls should target project.localPath
        for (final call in calls) {
          expect(call.workingDirectory, equals('/data/projects/my-app'));
        }
      });

      test('cleanup() without project uses default _projectDir', () async {
        final manager = WorktreeManager(
          dataDir: '/tmp/test-data',
          projectDir: '/tmp/default-project',
          processRunner: recordingRunner(),
        );

        await manager.cleanup('task-1');

        // Git cleanup calls should target default projectDir
        for (final call in calls) {
          expect(call.workingDirectory, equals('/tmp/default-project'));
        }
      });

      test('branch name collision with project-backed worktree applies -N suffix', () async {
        var listCallCount = 0;
        final project = Project(
          id: 'my-app',
          name: 'My App',
          remoteUrl: 'git@github.com:u/my-app.git',
          localPath: '/data/projects/my-app',
          defaultBranch: 'main',
          status: ProjectStatus.ready,
          createdAt: DateTime.now(),
        );

        final manager = WorktreeManager(
          dataDir: '/tmp/test-data',
          processRunner: (executable, arguments, {String? workingDirectory}) async {
            if (arguments.contains('--version')) return ProcessResult(0, 0, 'git version 2', '');
            if (arguments.contains('--list')) {
              listCallCount++;
              // First collision check: base branch exists.
              if (listCallCount == 1) return ProcessResult(0, 0, '  dartclaw/task-task-1', '');
              // Second check: -2 suffix is available.
              return ProcessResult(0, 0, '', '');
            }
            return ProcessResult(0, 0, '', '');
          },
        );

        final info = await manager.create('task-1', project: project);
        expect(info.branch, equals('dartclaw/task-task-1-2'));
      });
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
