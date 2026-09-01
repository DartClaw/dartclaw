import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/src/task/workflow_worktree_binder.dart';
import 'package:dartclaw_runtime/src/task/worktree_manager.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('WorkflowWorktreeBinder', () {
    test('keeps full workflow run ID as the binding key', () async {
      final binder = _binder();
      final task = _workflowTask(
        workflowRunId: '3a711b3b-9bda-4523-8829-826b0019f205',
        git: const {'worktree': 'shared'},
      );

      expect(await binder.workflowOwnedWorktreeKey(task), '3a711b3b-9bda-4523-8829-826b0019f205');
    });

    test('uses a short stable token for shared worktree task IDs', () async {
      final binder = _binder();
      final task = _workflowTask(
        workflowRunId: '3a711b3b-9bda-4523-8829-826b0019f205',
        git: const {'worktree': 'shared'},
      );

      expect(await binder.workflowOwnedWorktreeTaskId(task), 'wf-72461246f28aea5c');
    });

    test('uses a short stable token for per-map-item worktree task IDs', () async {
      final binder = _binder();
      final task = _workflowTask(
        workflowRunId: '3a711b3b-9bda-4523-8829-826b0019f205',
        git: const {'worktree': 'per-map-item'},
        mapIterationIndex: 0,
      );

      expect(await binder.workflowOwnedWorktreeKey(task), '3a711b3b-9bda-4523-8829-826b0019f205:map:0');
      expect(await binder.workflowOwnedWorktreeTaskId(task), 'wf-72461246f28aea5c-map-0');
    });

    group('inline workflow checkout git config policy', () {
      late Directory tempDir;
      late Project project;
      late File sentinel;

      setUp(() async {
        tempDir = Directory.systemTemp.createTempSync('binder_nosystem_');
        final repoPath = p.join(tempDir.path, 'repo');
        Directory(repoPath).createSync(recursive: true);
        sentinel = File(p.join(tempDir.path, 'sentinel.txt'));

        Future<void> git(List<String> args) async {
          final result = await Process.run('git', args, workingDirectory: repoPath);
          expect(result.exitCode, 0, reason: '${args.join(' ')}: ${result.stderr}');
        }

        await git(['init', '-b', 'main']);
        await git(['config', 'user.name', 'Test']);
        await git(['config', 'user.email', 'test@example.com']);
        File(p.join(repoPath, 'README.md')).writeAsStringSync('#');
        await git(['add', '.']);
        await git(['commit', '-m', 'initial', '--no-gpg-sign']);
        await git(['branch', 'feature']);

        // post-checkout dumps what the git child observed; "unset" when the
        // spawn left system git config in band.
        final hookPath = p.join(repoPath, '.git', 'hooks', 'post-checkout');
        File(hookPath)
            .writeAsStringSync('#!/bin/sh\nprintf "%s" "\${GIT_CONFIG_NOSYSTEM:-unset}" > "${sentinel.path}"\n');
        await Process.run('chmod', ['+x', hookPath]);

        project = Project(
          id: 'proj-a',
          name: 'Project A',
          remoteUrl: '',
          localPath: repoPath,
          defaultBranch: 'main',
          status: ProjectStatus.ready,
          createdAt: DateTime.now(),
        );
      });

      tearDown(() {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      });

      test('workflow-orchestrated checkout neutralizes system git config', () async {
        final task = _workflowTask(workflowRunId: 'run-1', git: const {'worktree': 'inline'});

        expect(await _binder().ensureInlineWorkflowBranchCheckedOut(task, project, 'feature'), isTrue);

        expect(sentinel.readAsStringSync(), '1');
      });

      test('non-workflow checkout leaves system git config in band', () async {
        final task = Task(
          id: 'task-plain',
          title: 'Plain task',
          description: 'Plain task',
          createdAt: DateTime.parse('2026-05-05T12:00:00Z'),
        );

        expect(await _binder().ensureInlineWorkflowBranchCheckedOut(task, project, 'feature'), isTrue);

        expect(sentinel.readAsStringSync(), 'unset');
      });
    });

    test('failed worktree creation does not leak an unhandled waiter error', () async {
      final unhandledErrors = <Object>[];
      await runZonedGuarded<Future<void>>(() async {
        final binder = _binder(worktreeManager: _ThrowingWorktreeManager());
        final task = _workflowTask(
          workflowRunId: '3a711b3b-9bda-4523-8829-826b0019f205',
          git: const {'worktree': 'per-map-item'},
          mapIterationIndex: 7,
        );

        await expectLater(
          () => binder.resolveWorkflowSharedWorktree(
            task,
            workflowWorktreeKey: '3a711b3b-9bda-4523-8829-826b0019f205:map:7',
            workflowWorktreeTaskId: 'wf-72461246f28aea5c-map-7',
            project: null,
            createBranch: true,
            baseRef: 'dartclaw/workflow/3a711b3b9bda45238829826b0019f205/integration',
          ),
          throwsA(isA<WorktreeException>()),
        );
        await Future<void>.delayed(Duration.zero);
      }, (error, _) => unhandledErrors.add(error));

      expect(unhandledErrors, isEmpty);
    });
  });
}

WorkflowWorktreeBinder _binder({WorktreeManager? worktreeManager}) => WorkflowWorktreeBinder(
  worktreeManager: worktreeManager,
  workflowRunRepository: null,
  failTask: (_, {required errorSummary, required kind, required retryable}) async {},
);

final class _ThrowingWorktreeManager extends WorktreeManager {
  new() : super(dataDir: '/tmp', projectDir: '/tmp');

  @override
  Future<WorktreeInfo> create(
    String taskId, {
    String? baseRef,
    Project? project,
    bool createBranch = true,
    Map<String, dynamic>? existingWorktreeJson,
  }) async {
    throw WorktreeException('Failed to create worktree at /tmp/$taskId', gitStderr: 'fatal: invalid reference');
  }
}

Task _workflowTask({required String workflowRunId, required Map<String, dynamic> git, int? mapIterationIndex}) => Task(
  id: 'task-1',
  title: 'Workflow task',
  description: 'Workflow task',
  createdAt: DateTime.parse('2026-05-05T12:00:00Z'),
  workflowStepExecution: WorkflowStepExecution(
    taskId: 'task-1',
    agentExecutionId: 'ae-task-1',
    workflowRunId: workflowRunId,
    stepIndex: 0,
    stepId: 'implement',
    stepType: 'coding',
    gitJson: jsonEncode(git),
    mapIterationIndex: mapIterationIndex,
  ),
);
