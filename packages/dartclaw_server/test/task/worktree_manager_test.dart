import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show Task, TaskStatus, TaskType;
import 'package:dartclaw_models/dartclaw_models.dart';
import 'package:dartclaw_server/src/task/worktree_manager.dart';
import 'package:logging/logging.dart';
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

    test('create() materializes workflow skills before returning', () async {
      final sourceSkill = Directory(p.join(dataDir, '.claude', 'skills', 'dartclaw-test'))..createSync(recursive: true);
      File(p.join(sourceSkill.path, 'SKILL.md')).writeAsStringSync('---\nname: dartclaw-test\n---\n');
      final manager = WorktreeManager(
        dataDir: dataDir,
        projectDir: projectDir,
        skillMaterializer: (worktreePath) async {
          Link(
            p.join(worktreePath, '.claude', 'skills', 'dartclaw-test'),
          ).createSync(sourceSkill.path, recursive: true);
        },
      );

      final info = await manager.create('skills-test');

      expect(Link(p.join(info.path, '.claude', 'skills', 'dartclaw-test')).targetSync(), sourceSkill.path);
    });

    test('create() rolls back worktree and branch when skill materialization fails', () async {
      final manager = WorktreeManager(
        dataDir: dataDir,
        projectDir: projectDir,
        skillMaterializer: (_) async {
          throw StateError('link failed');
        },
      );

      await expectLater(
        manager.create('rollback-skills'),
        throwsA(isA<WorktreeException>().having((e) => e.message, 'message', contains('Failed to materialize'))),
      );

      expect(Directory(p.join(dataDir, 'worktrees', 'rollback-skills')).existsSync(), isFalse);
      final branchResult = await Process.run('git', [
        'branch',
        '--list',
        'dartclaw/task-rollback-skills',
      ], workingDirectory: projectDir);
      expect((branchResult.stdout as String).trim(), isEmpty);
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

    test('detectStaleWorktrees() logs and continues when stale reap fails', () async {
      final staleDir = Directory(p.join(dataDir, 'worktrees', 'task-stale'))..createSync(recursive: true);
      File(p.join(staleDir.path, 'README.md')).writeAsStringSync('stale');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final manager = WorktreeManager(
        dataDir: dataDir,
        projectDir: projectDir,
        staleTimeoutHours: 0,
        taskLookup: (_) async => Task(
          id: 'task-stale',
          title: 'stale',
          description: 'stale',
          type: TaskType.coding,
          createdAt: DateTime.now(),
          status: TaskStatus.accepted,
        ),
        processRunner: (executable, arguments, {String? workingDirectory}) async {
          if (arguments.contains('--version')) return ProcessResult(0, 0, 'git version 2', '');
          if (arguments.length >= 3 && arguments[0] == 'worktree' && arguments[1] == 'list') {
            return ProcessResult(0, 0, 'worktree ${staleDir.path}\nbranch refs/heads/main\n\n', '');
          }
          if (arguments.length >= 3 && arguments[0] == 'worktree' && arguments[1] == 'remove') {
            return ProcessResult(0, 1, '', 'fatal: worktree locked');
          }
          return ProcessResult(0, 0, '', '');
        },
      );

      await manager.detectStaleWorktrees();

      expect(staleDir.existsSync(), isTrue, reason: 'failed reaps should leave the stale dir in place');
    });

    test('detectStaleWorktrees() routes reap to the owning project repo', () async {
      final reapCalls = <({List<String> arguments, String? workingDirectory})>[];
      final staleDir = Directory(p.join(dataDir, 'worktrees', 'task-project'))..createSync(recursive: true);
      File(p.join(staleDir.path, 'README.md')).writeAsStringSync('stale');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final owningProject = Project(
        id: 'proj-a',
        name: 'Project A',
        remoteUrl: 'git@example.com:u/proj-a.git',
        localPath: '/data/projects/proj-a',
        defaultBranch: 'main',
        status: ProjectStatus.ready,
        createdAt: DateTime.now(),
      );

      final manager = WorktreeManager(
        dataDir: dataDir,
        projectDir: projectDir,
        staleTimeoutHours: 0,
        taskLookup: (_) async => Task(
          id: 'task-project',
          title: 'stale',
          description: 'stale',
          type: TaskType.coding,
          projectId: 'proj-a',
          createdAt: DateTime.now(),
          status: TaskStatus.accepted,
        ),
        projectLookup: (id) async => id == 'proj-a' ? owningProject : null,
        processRunner: (executable, arguments, {String? workingDirectory}) async {
          reapCalls.add((arguments: List<String>.from(arguments), workingDirectory: workingDirectory));
          if (arguments.contains('--version')) return ProcessResult(0, 0, 'git version 2', '');
          if (arguments.length >= 2 && arguments[0] == 'worktree' && arguments[1] == 'list') {
            return ProcessResult(0, 0, 'worktree ${staleDir.path}\nbranch refs/heads/main\n\n', '');
          }
          return ProcessResult(0, 0, '', '');
        },
      );

      await manager.detectStaleWorktrees();

      expect(staleDir.existsSync(), isFalse, reason: 'confirmed orphan should be reaped from disk');
      final reapWorktreeCalls = reapCalls.where(
        (c) => c.arguments.length >= 2 && c.arguments[0] == 'worktree' && c.arguments.contains('remove'),
      );
      expect(reapWorktreeCalls, isNotEmpty, reason: 'worktree remove should be invoked');
      for (final call in reapWorktreeCalls) {
        expect(
          call.workingDirectory,
          equals('/data/projects/proj-a'),
          reason: 'orphan worktree must be unregistered from the owning project repo, not the default',
        );
      }
    });

    test('default runner propagates GIT_CONFIG_NOSYSTEM=1 to git child processes', () async {
      // git worktree add triggers a post-checkout hook; the hook dumps the
      // value of $GIT_CONFIG_NOSYSTEM seen by the child. If the default
      // runner forgets to set the flag, the sentinel reads "unset".
      final sentinel = File(p.join(tmpDir.path, 'git-config-nosystem.txt'));
      final hookPath = p.join(projectDir, '.git', 'hooks', 'post-checkout');
      File(
        hookPath,
      ).writeAsStringSync('#!/bin/sh\nprintf "%s" "\${GIT_CONFIG_NOSYSTEM:-unset}" > "${sentinel.path}"\n');
      await Process.run('chmod', ['+x', hookPath]);

      final manager = WorktreeManager(dataDir: dataDir, projectDir: projectDir);
      await manager.create('nosystem-sentinel');

      expect(sentinel.existsSync(), isTrue, reason: 'post-checkout hook did not run — git child may have failed');
      expect(
        sentinel.readAsStringSync(),
        '1',
        reason: 'workflow-owned worktree children must carry GIT_CONFIG_NOSYSTEM=1 (S39 hardening)',
      );
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

    test('projectDir fallback uses the current cwd when create is called', () async {
      final calls = <({List<String> arguments, String? workingDirectory})>[];
      final manager = WorktreeManager(
        dataDir: '/tmp/test-data',
        processRunner: (executable, arguments, {String? workingDirectory}) async {
          calls.add((arguments: arguments, workingDirectory: workingDirectory));
          if (arguments.contains('--version')) return ProcessResult(0, 0, 'git version 2', '');
          if (arguments.contains('--list')) return ProcessResult(0, 0, '', '');
          if (arguments.first == 'branch') return ProcessResult(0, 0, '', '');
          if (arguments.contains('worktree')) return ProcessResult(0, 0, '', '');
          return ProcessResult(0, 0, '', '');
        },
      );

      final savedCwd = Directory.current;
      final tempCwd = Directory.systemTemp.createTempSync('worktree_manager_cwd_');
      final expectedWorkingDirectory = tempCwd.resolveSymbolicLinksSync();
      Directory.current = tempCwd;

      try {
        await manager.create('task-1');
      } finally {
        Directory.current = savedCwd;
        tempCwd.deleteSync(recursive: true);
      }

      final gitCalls = calls.where((call) => !call.arguments.contains('--version')).toList();
      for (final call in gitCalls) {
        expect(call.workingDirectory, expectedWorkingDirectory);
      }
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
          if (arguments.length >= 3 && arguments[0] == 'rev-parse' && arguments[1] == '--verify') {
            return ProcessResult(0, 1, '', '');
          }
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
        final worktreeCall = calls.firstWhere(
          (c) => c.arguments.length >= 2 && c.arguments[0] == 'worktree' && c.arguments[1] == 'add',
        );
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

        final worktreeCall = calls.firstWhere(
          (c) => c.arguments.length >= 2 && c.arguments[0] == 'worktree' && c.arguments[1] == 'add',
        );
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

        final worktreeCall = calls.firstWhere(
          (c) => c.arguments.length >= 2 && c.arguments[0] == 'worktree' && c.arguments[1] == 'add',
        );
        expect(worktreeCall.arguments, contains('origin/release/0.16'));
      });

      test('create() with local-path project keeps explicit baseRef local when no remote exists', () async {
        final project = Project(
          id: 'my-app',
          name: 'My App',
          remoteUrl: '',
          localPath: '/data/projects/my-app',
          defaultBranch: '',
          status: ProjectStatus.ready,
          createdAt: DateTime.now(),
        );

        final manager = WorktreeManager(dataDir: '/tmp/test-data', processRunner: recordingRunner());

        await manager.create('task-1', project: project, baseRef: 'feature/local');

        final worktreeCall = calls.firstWhere(
          (c) => c.arguments.length >= 2 && c.arguments[0] == 'worktree' && c.arguments[1] == 'add',
        );
        expect(worktreeCall.arguments, contains('feature/local'));
        expect(worktreeCall.arguments, isNot(contains('origin/feature/local')));
      });

      test('create() with local-path project and no explicit baseRef uses the local defaultBranch', () async {
        final project = Project(
          id: 'my-app',
          name: 'My App',
          remoteUrl: '',
          localPath: '/data/projects/my-app',
          defaultBranch: 'main',
          status: ProjectStatus.ready,
          createdAt: DateTime.now(),
        );

        final manager = WorktreeManager(dataDir: '/tmp/test-data', processRunner: recordingRunner());

        await manager.create('task-1', project: project);

        final worktreeCall = calls.firstWhere(
          (c) => c.arguments.length >= 2 && c.arguments[0] == 'worktree' && c.arguments[1] == 'add',
        );
        expect(worktreeCall.arguments, contains('main'));
        expect(worktreeCall.arguments, isNot(contains('origin/main')));
      });

      test('create() with project preserves explicit local workflow refs when they already exist locally', () async {
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
            if (arguments.contains('--list')) return ProcessResult(0, 0, '', '');
            if (arguments.length >= 4 &&
                arguments[0] == 'rev-parse' &&
                arguments[1] == '--verify' &&
                arguments[2] == '--quiet' &&
                arguments[3] == 'dartclaw/workflow/run123') {
              return ProcessResult(0, 0, 'dartclaw/workflow/run123', '');
            }
            calls.add((executable: executable, arguments: arguments, workingDirectory: workingDirectory));
            return ProcessResult(0, 0, '', '');
          },
        );

        await manager.create('task-1', project: project, baseRef: 'dartclaw/workflow/run123');

        final worktreeCall = calls.firstWhere(
          (c) => c.arguments.length >= 2 && c.arguments[0] == 'worktree' && c.arguments[1] == 'add',
        );
        expect(worktreeCall.arguments, contains('dartclaw/workflow/run123'));
        expect(worktreeCall.arguments, isNot(contains('origin/dartclaw/workflow/run123')));
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
        final worktreeCall = calls.firstWhere(
          (c) => c.arguments.length >= 2 && c.arguments[0] == 'worktree' && c.arguments[1] == 'add',
        );
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

  group('WorktreeManager reconciliation', () {
    test('create() adopts persisted worktreeJson when directory and git registration match', () async {
      final tempDir = Directory.systemTemp.createTempSync('worktree_reconcile_match_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });
      final worktreePath = p.join(tempDir.path, 'worktrees', 'task-1');
      await Directory(worktreePath).create(recursive: true);
      var worktreeAddCalls = 0;
      final manager = WorktreeManager(
        dataDir: tempDir.path,
        projectDir: tempDir.path,
        processRunner: (executable, arguments, {workingDirectory}) async {
          if (arguments.contains('--version')) return ProcessResult(0, 0, 'git version 2', '');
          if (arguments.length >= 3 && arguments[0] == 'worktree' && arguments[1] == 'list') {
            return ProcessResult(
              0,
              0,
              'worktree $worktreePath\nHEAD abc123\nbranch refs/heads/dartclaw/task-task-1\n\n',
              '',
            );
          }
          if (arguments.length >= 3 && arguments[0] == 'worktree' && arguments[1] == 'add') {
            worktreeAddCalls++;
          }
          return ProcessResult(0, 0, '', '');
        },
      );

      final info = await manager.create(
        'task-1',
        existingWorktreeJson: {
          'path': worktreePath,
          'branch': 'dartclaw/task-task-1',
          'createdAt': '2026-04-20T10:00:00.000Z',
        },
      );

      expect(info.path, worktreePath);
      expect(info.branch, 'dartclaw/task-task-1');
      expect(worktreeAddCalls, 0);
      expect(manager.getWorktreeInfo('task-1')?.path, worktreePath);
    });

    test('create() removes orphaned directory and recreates the worktree', () async {
      final tempDir = Directory.systemTemp.createTempSync('worktree_reconcile_orphan_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });
      final worktreePath = p.join(tempDir.path, 'worktrees', 'task-1');
      await Directory(worktreePath).create(recursive: true);
      File(p.join(worktreePath, 'orphan.txt')).writeAsStringSync('stale');
      var worktreeAddCalls = 0;
      final manager = WorktreeManager(
        dataDir: tempDir.path,
        projectDir: tempDir.path,
        processRunner: (executable, arguments, {workingDirectory}) async {
          if (arguments.contains('--version')) return ProcessResult(0, 0, 'git version 2', '');
          if (arguments.length >= 3 && arguments[0] == 'worktree' && arguments[1] == 'list') {
            return ProcessResult(0, 0, '', '');
          }
          if (arguments.length >= 3 && arguments[0] == 'branch' && arguments[1] == '--list') {
            return ProcessResult(0, 0, '', '');
          }
          if (arguments.isNotEmpty && arguments[0] == 'branch') {
            return ProcessResult(0, 0, '', '');
          }
          if (arguments.length >= 3 && arguments[0] == 'worktree' && arguments[1] == 'add') {
            worktreeAddCalls++;
            await Directory(arguments[2]).create(recursive: true);
            return ProcessResult(0, 0, '', '');
          }
          return ProcessResult(0, 0, '', '');
        },
      );

      await manager.create('task-1');

      expect(worktreeAddCalls, 1);
      expect(Directory(worktreePath).existsSync(), isTrue);
      expect(File(p.join(worktreePath, 'orphan.txt')).existsSync(), isFalse);
    });

    test('create() prunes dangling git registration before recreating', () async {
      final tempDir = Directory.systemTemp.createTempSync('worktree_reconcile_prune_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });
      final worktreePath = p.join(tempDir.path, 'worktrees', 'task-1');
      var pruneCalls = 0;
      var worktreeAddCalls = 0;
      final manager = WorktreeManager(
        dataDir: tempDir.path,
        projectDir: tempDir.path,
        processRunner: (executable, arguments, {workingDirectory}) async {
          if (arguments.contains('--version')) return ProcessResult(0, 0, 'git version 2', '');
          if (arguments.length >= 3 && arguments[0] == 'worktree' && arguments[1] == 'list') {
            return ProcessResult(
              0,
              0,
              'worktree $worktreePath\nHEAD abc123\nbranch refs/heads/dartclaw/task-task-1\n\n',
              '',
            );
          }
          if (arguments.length >= 2 && arguments[0] == 'worktree' && arguments[1] == 'prune') {
            pruneCalls++;
            return ProcessResult(0, 0, '', '');
          }
          if (arguments.length >= 3 && arguments[0] == 'branch' && arguments[1] == '--list') {
            return ProcessResult(0, 0, '', '');
          }
          if (arguments.isNotEmpty && arguments[0] == 'branch') {
            return ProcessResult(0, 0, '', '');
          }
          if (arguments.length >= 3 && arguments[0] == 'worktree' && arguments[1] == 'add') {
            worktreeAddCalls++;
            await Directory(arguments[2]).create(recursive: true);
            return ProcessResult(0, 0, '', '');
          }
          return ProcessResult(0, 0, '', '');
        },
      );

      await manager.create('task-1');

      expect(pruneCalls, 1);
      expect(worktreeAddCalls, 1);
      expect(Directory(worktreePath).existsSync(), isTrue);
    });
  });

  group('detectStaleWorktrees()', () {
    test('reaps confirmed orphans and leaves running-task worktrees alone', () async {
      final tempDir = Directory.systemTemp.createTempSync('worktree_stale_reap_');
      addTearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });
      final worktreesDir = p.join(tempDir.path, 'worktrees');
      final runningPath = p.join(worktreesDir, 'A');
      final completedPath = p.join(worktreesDir, 'B');
      final missingPath = p.join(worktreesDir, 'C');
      await Directory(runningPath).create(recursive: true);
      await Directory(completedPath).create(recursive: true);
      await Directory(missingPath).create(recursive: true);
      final removedPaths = <String>[];
      final records = <LogRecord>[];
      final subscription = Logger('WorktreeManager').onRecord.listen(records.add);
      addTearDown(subscription.cancel);

      final manager = WorktreeManager(
        dataDir: tempDir.path,
        projectDir: tempDir.path,
        staleTimeoutHours: 0,
        taskLookup: (taskId) async => switch (taskId) {
          'A' => Task(
            id: 'A',
            title: 'Running task',
            description: 'desc',
            type: TaskType.coding,
            status: TaskStatus.running,
            createdAt: DateTime.now(),
          ),
          'B' => Task(
            id: 'B',
            title: 'Completed task',
            description: 'desc',
            type: TaskType.coding,
            status: TaskStatus.failed,
            createdAt: DateTime.now(),
          ),
          _ => null,
        },
        processRunner: (executable, arguments, {workingDirectory}) async {
          if (arguments.contains('--version')) return ProcessResult(0, 0, 'git version 2', '');
          if (arguments.length >= 3 && arguments[0] == 'worktree' && arguments[1] == 'list') {
            return ProcessResult(
              0,
              0,
              'worktree $runningPath\nHEAD a\nbranch refs/heads/dartclaw/task-A\n\n'
                  'worktree $completedPath\nHEAD b\nbranch refs/heads/dartclaw/task-B\n\n'
                  'worktree $missingPath\nHEAD c\nbranch refs/heads/dartclaw/task-C\n\n',
              '',
            );
          }
          if (arguments.length >= 4 && arguments[0] == 'worktree' && arguments[1] == 'remove') {
            removedPaths.add(arguments[3]);
            return ProcessResult(0, 0, '', '');
          }
          return ProcessResult(0, 0, '', '');
        },
      );

      await manager.detectStaleWorktrees();

      expect(Directory(runningPath).existsSync(), isTrue);
      expect(Directory(completedPath).existsSync(), isFalse);
      expect(Directory(missingPath).existsSync(), isFalse);
      expect(removedPaths, containsAll([completedPath, missingPath]));
      expect(
        records.where((record) => record.level == Level.INFO).map((record) => record.message),
        anyElement(contains(completedPath)),
      );
      expect(
        records.where((record) => record.level == Level.INFO).map((record) => record.message),
        anyElement(contains(missingPath)),
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

  group('applyExternalArtifactMount (per-story-copy)', () {
    late Directory tmpDir;
    late String fromProjectDir;
    late String worktreeDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('mount_test_');
      fromProjectDir = p.join(tmpDir.path, 'fromProject');
      worktreeDir = p.join(tmpDir.path, 'worktree');
      Directory(p.join(fromProjectDir, 'docs/specs/0.16.5/fis')).createSync(recursive: true);
      Directory(worktreeDir).createSync();
      File(p.join(fromProjectDir, 'docs/specs/0.16.5/fis/s13-helpers.md')).writeAsStringSync('# S13 FIS');
      File(p.join(fromProjectDir, 'docs/specs/0.16.5/fis/s14-other.md')).writeAsStringSync('# S14 FIS');
    });

    tearDown(() {
      if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
    });

    test('copies exactly the named source file into the worktree at the same relative path', () async {
      final wm = WorktreeManager(dataDir: tmpDir.path);
      final wt = WorktreeInfo(path: worktreeDir, branch: 'b', createdAt: DateTime.now());
      final target = await wm.applyExternalArtifactMount(
        worktree: wt,
        fromProjectDir: fromProjectDir,
        relativeSourcePath: 'docs/specs/0.16.5/fis/s13-helpers.md',
      );
      expect(target, equals(p.join(worktreeDir, 'docs/specs/0.16.5/fis/s13-helpers.md')));
      expect(File(target).readAsStringSync(), equals('# S13 FIS'));
      // Sibling FIS not copied — least privilege.
      expect(File(p.join(worktreeDir, 'docs/specs/0.16.5/fis/s14-other.md')).existsSync(), isFalse);
    });

    test('rejects paths that escape the fromProject root', () async {
      final wm = WorktreeManager(dataDir: tmpDir.path);
      final wt = WorktreeInfo(path: worktreeDir, branch: 'b', createdAt: DateTime.now());
      await expectLater(
        wm.applyExternalArtifactMount(worktree: wt, fromProjectDir: fromProjectDir, relativeSourcePath: '../escape.md'),
        throwsA(isA<WorktreeException>()),
      );
    });

    test('rejects absolute source paths', () async {
      final wm = WorktreeManager(dataDir: tmpDir.path);
      final wt = WorktreeInfo(path: worktreeDir, branch: 'b', createdAt: DateTime.now());
      await expectLater(
        wm.applyExternalArtifactMount(worktree: wt, fromProjectDir: fromProjectDir, relativeSourcePath: '/etc/passwd'),
        throwsA(isA<WorktreeException>()),
      );
    });

    test('raises WorktreeException when source file is missing', () async {
      final wm = WorktreeManager(dataDir: tmpDir.path);
      final wt = WorktreeInfo(path: worktreeDir, branch: 'b', createdAt: DateTime.now());
      await expectLater(
        wm.applyExternalArtifactMount(
          worktree: wt,
          fromProjectDir: fromProjectDir,
          relativeSourcePath: 'docs/specs/0.16.5/fis/s99-missing.md',
        ),
        throwsA(isA<WorktreeException>()),
      );
    });

    test('bind-mount mode raises until a platform provider is implemented', () async {
      final wm = WorktreeManager(dataDir: tmpDir.path);
      final wt = WorktreeInfo(path: worktreeDir, branch: 'b', createdAt: DateTime.now());
      await expectLater(
        wm.applyExternalArtifactMount(
          worktree: wt,
          fromProjectDir: fromProjectDir,
          relativeSourcePath: 'docs/specs/0.16.5/fis/s13-helpers.md',
          mode: 'bind-mount',
        ),
        throwsA(isA<WorktreeException>()),
      );
    });

    test('warns and overwrites when target already exists with different content', () async {
      final records = <LogRecord>[];
      final sub = Logger('WorktreeManager').onRecord.listen(records.add);
      final wm = WorktreeManager(dataDir: tmpDir.path);
      final wt = WorktreeInfo(path: worktreeDir, branch: 'b', createdAt: DateTime.now());
      final existingTarget = File(p.join(worktreeDir, 'docs/specs/0.16.5/fis/s13-helpers.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('decoy');

      final target = await wm.applyExternalArtifactMount(
        worktree: wt,
        fromProjectDir: fromProjectDir,
        relativeSourcePath: 'docs/specs/0.16.5/fis/s13-helpers.md',
      );

      await sub.cancel();

      expect(target, existingTarget.path);
      expect(existingTarget.readAsStringSync(), equals('# S13 FIS'));
      expect(records.any((record) => record.level == Level.WARNING), isTrue);
      expect(records.any((record) => record.message.contains('different content')), isTrue);
    });
  });
}
