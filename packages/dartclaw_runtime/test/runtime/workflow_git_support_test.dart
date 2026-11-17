import 'dart:io';

import 'package:dartclaw_runtime/src/runtime/workflow_git_support.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show PushAuthFailure, PushSuccess;
import 'package:path/path.dart' as p;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show WorkflowGitPromotionSuccess, WorkflowGitPromotionHeld, WorkflowGitPromotionError, WorkflowPublishStatus;
import 'package:test/test.dart';

import '../task/task_executor_test_support.dart' show initGitRepo;
import '../task/task_review_test_support.dart' show installMarkerGitHook;

Future<ProcessResult> _git(String workingDirectory, List<String> arguments) {
  return Process.run('git', arguments, workingDirectory: workingDirectory);
}

void main() {
  // The standalone lane runs against the invocation repository, where a commit
  // is local by definition. Cutting the integration branch from `origin/<base>`
  // there bases every step on the last *pushed* state, so a just-committed file
  // is invisible to the whole run — which is how a live workflow reported a
  // seeded specification missing and re-synthesized it.
  group('workflowBranchFollowsRemote', () {
    test('the local posture never follows the remote, however remote-backed the project', () {
      expect(
        workflowBranchFollowsRemote(localFallbackDir: '/repo', projectRemoteUrl: 'https://example.com/org/repo.git'),
        isFalse,
      );
    });

    test('the connected lane follows the remote for a remote-backed project', () {
      expect(
        workflowBranchFollowsRemote(localFallbackDir: null, projectRemoteUrl: 'https://example.com/org/repo.git'),
        isTrue,
      );
    });

    test('a project with no remote is local-ref either way', () {
      expect(workflowBranchFollowsRemote(localFallbackDir: null, projectRemoteUrl: '  '), isFalse);
      expect(workflowBranchFollowsRemote(localFallbackDir: '/repo', projectRemoteUrl: ''), isFalse);
    });
  });

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_workflow_git_support_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  for (final hooksPath in ['.husky', '.githooks']) {
    test('host commit sweep runs no git hooks from $hooksPath', () async {
      final repo = await initGitRepo();
      addTearDown(() => repo.delete(recursive: true));
      await _git(repo.path, ['config', 'user.email', 'fixture@example.com']);
      await _git(repo.path, ['config', 'user.name', 'Fixture']);
      final marker = await installMarkerGitHook(repo.path, hooksPath: hooksPath);
      File('${repo.path}/work.txt').writeAsStringSync('work\n');
      await commitWorkflowWorktreeChangesIfNeeded(
        projectDir: repo.path,
        branch: 'main',
        commitMessage: 'fixture changes',
      );
      expect((await _git(repo.path, ['show', 'HEAD:work.txt'])).stdout, 'work\n');
      expect(marker.existsSync(), isFalse);
    });
  }

  test('commitWorkflowWorktreeChangesIfNeeded commits pending changes in the branch worktree', () async {
    final repoDir = Directory(p.join(tempDir.path, 'repo'))..createSync(recursive: true);
    final worktreeDir = p.join(tempDir.path, 'feature-worktree');

    expect((await _git(repoDir.path, ['init', '-b', 'main'])).exitCode, 0);
    expect((await _git(repoDir.path, ['config', 'user.name', 'Workflow Test'])).exitCode, 0);
    expect((await _git(repoDir.path, ['config', 'user.email', 'workflow@test.local'])).exitCode, 0);

    File(p.join(repoDir.path, 'README.md')).writeAsStringSync('base\n');
    expect((await _git(repoDir.path, ['add', 'README.md'])).exitCode, 0);
    expect((await _git(repoDir.path, ['commit', '-m', 'initial'])).exitCode, 0);

    expect((await _git(repoDir.path, ['branch', 'feature/story-1'])).exitCode, 0);
    expect((await _git(repoDir.path, ['worktree', 'add', worktreeDir, 'feature/story-1'])).exitCode, 0);

    File(p.join(worktreeDir, 'notes', 'note.md'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('# Note\n- Added from worktree.\n');

    await commitWorkflowWorktreeChangesIfNeeded(
      projectDir: repoDir.path,
      branch: 'feature/story-1',
      commitMessage: 'workflow(S01): prepare promotion',
    );

    final status = await _git(worktreeDir, ['status', '--short', '--untracked-files=all']);
    expect((status.stdout as String).trim(), isEmpty);

    final log = await _git(repoDir.path, ['log', '--format=%s', '-1', 'feature/story-1']);
    expect((log.stdout as String).trim(), 'workflow(S01): prepare promotion');

    final tree = await _git(repoDir.path, ['ls-tree', '-r', '--name-only', 'feature/story-1']);
    expect((tree.stdout as String).split('\n'), contains('notes/note.md'));
  });

  test('commitWorkflowWorktreeChangesIfNeeded is a no-op when the branch has no linked worktree', () async {
    final repoDir = Directory(p.join(tempDir.path, 'repo'))..createSync(recursive: true);

    expect((await _git(repoDir.path, ['init', '-b', 'main'])).exitCode, 0);
    expect((await _git(repoDir.path, ['config', 'user.name', 'Workflow Test'])).exitCode, 0);
    expect((await _git(repoDir.path, ['config', 'user.email', 'workflow@test.local'])).exitCode, 0);

    File(p.join(repoDir.path, 'README.md')).writeAsStringSync('base\n');
    expect((await _git(repoDir.path, ['add', 'README.md'])).exitCode, 0);
    expect((await _git(repoDir.path, ['commit', '-m', 'initial'])).exitCode, 0);

    await commitWorkflowWorktreeChangesIfNeeded(
      projectDir: repoDir.path,
      branch: 'missing/worktree',
      commitMessage: 'workflow(S99): prepare promotion',
    );

    final log = await _git(repoDir.path, ['log', '--format=%s', '-1']);
    expect((log.stdout as String).trim(), 'initial');
  });

  for (final approved in [false, true]) {
    test('execution-surface hold checks promotion before sweep (approved=$approved)', () async {
      final repo = await initGitRepo();
      addTearDown(() => repo.deleteSync(recursive: true));
      await _git(repo.path, ['config', 'user.name', 'Fixture']);
      await _git(repo.path, ['config', 'user.email', 'fixture@example.com']);
      await _git(repo.path, ['branch', 'integration']);
      final worktree = p.join(tempDir.path, 'source');
      expect((await _git(repo.path, ['worktree', 'add', '-b', 'story', worktree, 'main'])).exitCode, 0);
      File(p.join(worktree, '.mcp.json')).writeAsStringSync('{}');
      final before = (await _git(repo.path, ['rev-parse', 'integration'])).stdout;
      final result = await promoteWorkflowBranchLocally(
        projectDir: repo.path,
        runId: 'held',
        branch: 'story',
        integrationBranch: 'integration',
        strategy: 'merge',
        approved: approved,
      );
      if (approved) {
        expect(result, isA<WorkflowGitPromotionSuccess>());
        expect((await _git(repo.path, ['show', 'integration:.mcp.json'])).stdout, '{}');
      } else {
        expect(result, isA<WorkflowGitPromotionHeld>().having((hold) => hold.paths, 'paths', ['.mcp.json']));
        expect((await _git(repo.path, ['rev-parse', 'integration'])).stdout, before);
        expect((await _git(worktree, ['status', '--porcelain'])).stdout, contains('.mcp.json'));
      }
    });
  }
  test('execution-surface hold refuses promotion when metadata cannot be read', () async {
    final result = await promoteWorkflowBranchLocally(
      projectDir: tempDir.path,
      runId: 'bad',
      branch: 'story',
      integrationBranch: 'integration',
      strategy: 'merge',
    );
    expect(result, isA<WorkflowGitPromotionError>());
  });

  test('promoteWorkflowBranchLocally restores the original branch after merging into integration', () async {
    final repoDir = Directory(p.join(tempDir.path, 'repo'))..createSync(recursive: true);
    final worktreeDir = p.join(tempDir.path, 'feature-worktree');
    const integrationBranch = 'dartclaw/workflow/run123/integration';

    expect((await _git(repoDir.path, ['init', '-b', 'main'])).exitCode, 0);
    expect((await _git(repoDir.path, ['config', 'user.name', 'Workflow Test'])).exitCode, 0);
    expect((await _git(repoDir.path, ['config', 'user.email', 'workflow@test.local'])).exitCode, 0);

    File(p.join(repoDir.path, 'README.md')).writeAsStringSync('base\n');
    expect((await _git(repoDir.path, ['add', 'README.md'])).exitCode, 0);
    expect((await _git(repoDir.path, ['commit', '-m', 'initial'])).exitCode, 0);

    expect((await _git(repoDir.path, ['branch', integrationBranch])).exitCode, 0);
    expect((await _git(repoDir.path, ['branch', 'feature/story-1'])).exitCode, 0);
    expect((await _git(repoDir.path, ['worktree', 'add', worktreeDir, 'feature/story-1'])).exitCode, 0);

    File(p.join(worktreeDir, 'notes', 'note.md'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('# Note\n- Added from worktree.\n');

    final result = await promoteWorkflowBranchLocally(
      projectDir: repoDir.path,
      runId: 'run-123',
      branch: 'feature/story-1',
      integrationBranch: integrationBranch,
      strategy: 'squash',
      storyId: 'S01',
    );

    expect(result, isA<WorkflowGitPromotionSuccess>());

    final currentBranch = await _git(repoDir.path, ['rev-parse', '--abbrev-ref', 'HEAD']);
    expect((currentBranch.stdout as String).trim(), 'main');

    final tree = await _git(repoDir.path, ['ls-tree', '-r', '--name-only', integrationBranch]);
    expect((tree.stdout as String).split('\n'), contains('notes/note.md'));
  });

  test('promoteWorkflowBranchLocally serializes concurrent promotions into one integration worktree', () async {
    final repoDir = Directory(p.join(tempDir.path, 'repo'))..createSync(recursive: true);
    final storyOneWorktree = p.join(tempDir.path, 'story-one-worktree');
    final storyTwoWorktree = p.join(tempDir.path, 'story-two-worktree');
    const integrationBranch = 'dartclaw/workflow/run123/integration';

    expect((await _git(repoDir.path, ['init', '-b', 'main'])).exitCode, 0);
    expect((await _git(repoDir.path, ['config', 'user.name', 'Workflow Test'])).exitCode, 0);
    expect((await _git(repoDir.path, ['config', 'user.email', 'workflow@test.local'])).exitCode, 0);

    File(p.join(repoDir.path, 'README.md')).writeAsStringSync('base\n');
    expect((await _git(repoDir.path, ['add', 'README.md'])).exitCode, 0);
    expect((await _git(repoDir.path, ['commit', '-m', 'initial'])).exitCode, 0);

    expect((await _git(repoDir.path, ['branch', integrationBranch])).exitCode, 0);
    expect((await _git(repoDir.path, ['branch', 'feature/story-1'])).exitCode, 0);
    expect((await _git(repoDir.path, ['branch', 'feature/story-2'])).exitCode, 0);
    expect((await _git(repoDir.path, ['worktree', 'add', storyOneWorktree, 'feature/story-1'])).exitCode, 0);
    expect((await _git(repoDir.path, ['worktree', 'add', storyTwoWorktree, 'feature/story-2'])).exitCode, 0);

    File(p.join(storyOneWorktree, 'notes', 'story-one.md'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('# Story One\n');
    File(p.join(storyTwoWorktree, 'notes', 'story-two.md'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('# Story Two\n');

    final results = await Future.wait([
      promoteWorkflowBranchLocally(
        projectDir: repoDir.path,
        runId: 'run-123',
        branch: 'feature/story-1',
        integrationBranch: integrationBranch,
        strategy: 'squash',
        storyId: 'S01',
      ),
      promoteWorkflowBranchLocally(
        projectDir: repoDir.path,
        runId: 'run-123',
        branch: 'feature/story-2',
        integrationBranch: integrationBranch,
        strategy: 'squash',
        storyId: 'S02',
      ),
    ]);

    expect(results, everyElement(isA<WorkflowGitPromotionSuccess>()));

    final status = await _git(repoDir.path, ['status', '--porcelain', '--untracked-files=all']);
    expect((status.stdout as String).trim(), isEmpty);

    final tree = await _git(repoDir.path, ['ls-tree', '-r', '--name-only', integrationBranch]);
    final files = (tree.stdout as String).split('\n');
    expect(files, containsAll(['notes/story-one.md', 'notes/story-two.md']));
  });

  test('promoteWorkflowBranchLocally merges in a temporary integration worktree when checkout is dirty', () async {
    final repoDir = Directory(p.join(tempDir.path, 'repo'))..createSync(recursive: true);
    final worktreeDir = p.join(tempDir.path, 'feature-worktree');
    const integrationBranch = 'dartclaw/workflow/run123/integration';

    expect((await _git(repoDir.path, ['init', '-b', 'main'])).exitCode, 0);
    expect((await _git(repoDir.path, ['config', 'user.name', 'Workflow Test'])).exitCode, 0);
    expect((await _git(repoDir.path, ['config', 'user.email', 'workflow@test.local'])).exitCode, 0);

    File(p.join(repoDir.path, 'README.md')).writeAsStringSync('base\n');
    File(p.join(repoDir.path, 'docs', 'STATE.md'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('clean\n');
    expect((await _git(repoDir.path, ['add', 'README.md', 'docs/STATE.md'])).exitCode, 0);
    expect((await _git(repoDir.path, ['commit', '-m', 'initial'])).exitCode, 0);

    expect((await _git(repoDir.path, ['branch', integrationBranch])).exitCode, 0);
    expect((await _git(repoDir.path, ['branch', 'feature/story-1'])).exitCode, 0);
    expect((await _git(repoDir.path, ['worktree', 'add', worktreeDir, 'feature/story-1'])).exitCode, 0);

    File(p.join(worktreeDir, 'notes', 'note.md'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('# Note\n');
    File(p.join(repoDir.path, 'docs', 'STATE.md')).writeAsStringSync('dirty in main checkout\n');

    final result = await promoteWorkflowBranchLocally(
      projectDir: repoDir.path,
      runId: 'run-123',
      branch: 'feature/story-1',
      integrationBranch: integrationBranch,
      strategy: 'squash',
      storyId: 'S01',
    );

    expect(result, isA<WorkflowGitPromotionSuccess>());

    final tree = await _git(repoDir.path, ['ls-tree', '-r', '--name-only', integrationBranch]);
    expect((tree.stdout as String).split('\n'), contains('notes/note.md'));

    final status = await _git(repoDir.path, ['status', '--porcelain', '--untracked-files=all']);
    expect((status.stdout as String).trim(), 'M docs/STATE.md');
  });

  for (final remotePush in [false, true]) {
    for (final committed in [false, true]) {
      test('execution-surface publish hold (remotePush=$remotePush, committed=$committed)', () async {
        final repo = await initGitRepo();
        addTearDown(() => repo.deleteSync(recursive: true));
        await _git(repo.path, ['checkout', '-b', 'publish']);
        File(p.join(repo.path, '.mcp.json')).writeAsStringSync('{}');
        if (committed) {
          expect((await _git(repo.path, ['add', '.mcp.json'])).exitCode, 0);
          expect(
            (await _git(repo.path, [
              '-c',
              'user.name=Fixture',
              '-c',
              'user.email=fixture@example.com',
              'commit',
              '-m',
              'execution file',
            ])).exitCode,
            0,
          );
        }
        final before = (await _git(repo.path, ['rev-parse', 'HEAD'])).stdout;
        var pushed = false;
        var fetched = false;
        final result = remotePush
            ? await publishWorkflowBranchWithRemotePush(
                projectDir: repo.path,
                branch: 'publish',
                baseRef: 'main',
                pushBranch: () async {
                  pushed = true;
                  return const PushSuccess();
                },
                fetchRemoteTrackingRef: () async {
                  fetched = true;
                  return ProcessResult(0, 0, '', '');
                },
              )
            : await publishWorkflowBranchLocally(projectDir: repo.path, branch: 'publish', baseRef: 'main');
        expect(result.status, WorkflowPublishStatus.held);
        expect(result.heldPaths, ['.mcp.json']);
        expect((await _git(repo.path, ['rev-parse', 'HEAD'])).stdout, before);
        expect((await _git(repo.path, ['status', '--porcelain'])).stdout, committed ? isEmpty : contains('.mcp.json'));
        expect(pushed, isFalse);
        expect(fetched, isFalse);
      });
    }
    test('execution-surface publish metadata errors refuse push (remotePush=$remotePush)', () async {
      var pushed = false;
      final result = remotePush
          ? await publishWorkflowBranchWithRemotePush(
              projectDir: tempDir.path,
              branch: 'publish',
              baseRef: 'main',
              pushBranch: () async {
                pushed = true;
                return const PushSuccess();
              },
              fetchRemoteTrackingRef: () async => ProcessResult(0, 0, '', ''),
            )
          : await publishWorkflowBranchLocally(projectDir: tempDir.path, branch: 'publish', baseRef: 'main');
      expect(result.status, WorkflowPublishStatus.failed);
      expect(result.error, contains('inspect execution surface'));
      expect(pushed, isFalse);
    });
  }

  test('execution-surface publish ignores another checkout that will not be swept', () async {
    final repo = await initGitRepo();
    addTearDown(() => repo.deleteSync(recursive: true));
    final remote = p.join(tempDir.path, 'remote.git');
    expect((await _git(repo.path, ['init', '--bare', remote])).exitCode, 0);
    expect((await _git(repo.path, ['remote', 'add', 'origin', remote])).exitCode, 0);
    expect((await _git(repo.path, ['branch', 'publish'])).exitCode, 0);
    File(p.join(repo.path, '.envrc')).writeAsStringSync('unswept checkout changes');
    final result = await publishWorkflowBranchLocally(projectDir: repo.path, branch: 'publish', baseRef: 'main');
    expect(result.status, WorkflowPublishStatus.success);
    expect((await _git(repo.path, ['status', '--porcelain'])).stdout, contains('.envrc'));
    expect(
      (await _git(repo.path, ['ls-tree', '-r', '--name-only', 'origin/publish'])).stdout,
      isNot(contains('.envrc')),
    );
  });

  test('publishWorkflowBranchLocally refreshes the origin tracking ref after push', () async {
    final remoteDir = Directory(p.join(tempDir.path, 'remote.git'))..createSync(recursive: true);
    final repoDir = Directory(p.join(tempDir.path, 'repo'));

    expect((await _git(tempDir.path, ['init', '--bare', remoteDir.path])).exitCode, 0);
    expect((await _git(tempDir.path, ['clone', remoteDir.path, repoDir.path])).exitCode, 0);
    expect((await _git(repoDir.path, ['config', 'user.name', 'Workflow Test'])).exitCode, 0);
    expect((await _git(repoDir.path, ['config', 'user.email', 'workflow@test.local'])).exitCode, 0);

    File(p.join(repoDir.path, 'README.md')).writeAsStringSync('base\n');
    expect((await _git(repoDir.path, ['add', 'README.md'])).exitCode, 0);
    expect((await _git(repoDir.path, ['commit', '-m', 'initial'])).exitCode, 0);
    expect((await _git(repoDir.path, ['push', 'origin', 'HEAD:main'])).exitCode, 0);

    const branch = 'dartclaw/workflow/run123/integration';
    expect((await _git(repoDir.path, ['checkout', '-b', branch])).exitCode, 0);

    final result = await publishWorkflowBranchLocally(projectDir: repoDir.path, branch: branch, baseRef: 'origin/main');

    expect(result.status, WorkflowPublishStatus.success);

    final remoteTracking = await _git(repoDir.path, ['rev-parse', '--verify', 'origin/$branch']);
    expect(remoteTracking.exitCode, 0);
  });

  test('publishWorkflowBranchWithRemotePush delegates push and refreshes the origin tracking ref', () async {
    final remoteDir = Directory(p.join(tempDir.path, 'remote.git'))..createSync(recursive: true);
    final repoDir = Directory(p.join(tempDir.path, 'repo'));

    expect((await _git(tempDir.path, ['init', '--bare', remoteDir.path])).exitCode, 0);
    expect((await _git(tempDir.path, ['clone', remoteDir.path, repoDir.path])).exitCode, 0);
    expect((await _git(repoDir.path, ['config', 'user.name', 'Workflow Test'])).exitCode, 0);
    expect((await _git(repoDir.path, ['config', 'user.email', 'workflow@test.local'])).exitCode, 0);

    File(p.join(repoDir.path, 'README.md')).writeAsStringSync('base\n');
    expect((await _git(repoDir.path, ['add', 'README.md'])).exitCode, 0);
    expect((await _git(repoDir.path, ['commit', '-m', 'initial'])).exitCode, 0);
    expect((await _git(repoDir.path, ['push', 'origin', 'HEAD:main'])).exitCode, 0);

    const branch = 'dartclaw/workflow/run123/integration';
    expect((await _git(repoDir.path, ['checkout', '-b', branch])).exitCode, 0);
    File(p.join(repoDir.path, 'notes', 'publish.md'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('ready\n');

    var pushed = false;
    var fetched = false;
    final result = await publishWorkflowBranchWithRemotePush(
      projectDir: repoDir.path,
      branch: branch,
      baseRef: 'origin/main',
      pushBranch: () async {
        pushed = true;
        final push = await _git(repoDir.path, ['push', 'origin', branch]);
        expect(push.exitCode, 0);
        return const PushSuccess();
      },
      fetchRemoteTrackingRef: () {
        fetched = true;
        return _git(repoDir.path, ['fetch', '--no-tags', 'origin', 'refs/heads/$branch:refs/remotes/origin/$branch']);
      },
    );

    expect(result.status, WorkflowPublishStatus.success);
    expect(pushed, isTrue);
    expect(fetched, isTrue);

    final remoteTracking = await _git(repoDir.path, ['rev-parse', '--verify', 'origin/$branch']);
    expect(remoteTracking.exitCode, 0);
    final tree = await _git(repoDir.path, ['ls-tree', '-r', '--name-only', 'origin/$branch']);
    expect((tree.stdout as String).split('\n'), contains('notes/publish.md'));
    final log = await _git(repoDir.path, ['log', '--format=%s', '-1', 'origin/$branch']);
    expect((log.stdout as String).trim(), 'workflow: prepare publish');
  });

  test('publishWorkflowBranchWithRemotePush returns structured auth failures without fetching', () async {
    final repoDir = Directory(p.join(tempDir.path, 'repo'))..createSync(recursive: true);

    expect((await _git(repoDir.path, ['init', '-b', 'main'])).exitCode, 0);
    expect((await _git(repoDir.path, ['config', 'user.name', 'Workflow Test'])).exitCode, 0);
    expect((await _git(repoDir.path, ['config', 'user.email', 'workflow@test.local'])).exitCode, 0);
    File(p.join(repoDir.path, 'README.md')).writeAsStringSync('base\n');
    expect((await _git(repoDir.path, ['add', 'README.md'])).exitCode, 0);
    expect((await _git(repoDir.path, ['commit', '-m', 'initial'])).exitCode, 0);

    var fetched = false;
    final result = await publishWorkflowBranchWithRemotePush(
      projectDir: repoDir.path,
      branch: 'main',
      baseRef: 'main',
      pushBranch: () async => const PushAuthFailure('Authentication denied (credential: github-main).'),
      fetchRemoteTrackingRef: () {
        fetched = true;
        return _git(repoDir.path, ['fetch', '--no-tags', 'origin', 'main']);
      },
    );

    expect(result.status, WorkflowPublishStatus.failed);
    expect(result.error, contains('Authentication failed'));
    expect(result.error, contains('github-main'));
    expect(fetched, isFalse);
  });
}
