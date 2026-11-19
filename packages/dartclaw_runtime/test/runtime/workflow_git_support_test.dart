import 'dart:io';

import 'package:dartclaw_runtime/src/runtime/workflow_git_support.dart';
import 'package:dartclaw_runtime/src/task/host_worktree_git.dart' show TamperedWorktreeException;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show PushAuthFailure, PushSuccess;
import 'package:path/path.dart' as p;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        WorkflowGitPromotionResult,
        WorkflowGitPromotionSuccess,
        WorkflowGitPromotionHeld,
        WorkflowGitPromotionError,
        WorkflowGitPublishResult,
        WorkflowPublishStatus;
import 'package:test/test.dart';

import '../task/host_worktree_tamper_fixture.dart';
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

  test('workflow preview, sweep and merge keep worktree hooks disabled', () async {
    final repo = await initGitRepo();
    addTearDown(() => repo.deleteSync(recursive: true));
    final source = p.join(tempDir.path, 'source');
    expect((await _git(repo.path, ['worktree', 'add', '-b', 'story', source, 'main'])).exitCode, 0);
    final indexMarker = await installMarkerGitHook(source, hookName: 'post-index-change');
    final targetIndexMarker = await installMarkerGitHook(repo.path, hookName: 'post-index-change');
    final mergeMarker = await installMarkerGitHook(repo.path, hookName: 'pre-merge-commit');
    final monitorMarker = await installMarkerGitHook(repo.path, hookName: 'fixture-fsmonitor');
    expect(
      (await _git(repo.path, ['config', 'core.fsmonitor', p.join(repo.path, '.husky', 'fixture-fsmonitor')])).exitCode,
      0,
    );
    File(p.join(source, '.envrc')).writeAsStringSync('fixture\n');
    File(p.join(repo.path, 'unrelated.txt')).writeAsStringSync('fixture\n');

    Future<WorkflowGitPromotionResult> promote([String? approved]) => promoteWorkflowBranchLocally(
      projectDir: repo.path,
      runId: 'hook-fixture',
      branch: 'story',
      integrationBranch: 'main',
      strategy: 'merge',
      approvedCandidate: approved,
    );

    final held = await promote() as WorkflowGitPromotionHeld;
    expect(indexMarker.existsSync(), isFalse);
    expect(targetIndexMarker.existsSync(), isFalse);
    expect(await promote(held.candidate), isA<WorkflowGitPromotionSuccess>());
    expect(indexMarker.existsSync(), isFalse);
    expect(targetIndexMarker.existsSync(), isFalse);
    expect(mergeMarker.existsSync(), isFalse);
    expect(monitorMarker.existsSync(), isFalse);
  });

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

  for (final onIntegration in [false, true]) {
    test('execution-surface promotion approves the reviewed tree (onIntegration=$onIntegration)', () async {
      final repo = await initGitRepo();
      addTearDown(() => repo.deleteSync(recursive: true));
      final source = p.join(tempDir.path, 'source');
      final integration = p.join(tempDir.path, 'integration');
      expect((await _git(repo.path, ['worktree', 'add', '-b', 'story', source, 'main'])).exitCode, 0);
      expect((await _git(repo.path, ['worktree', 'add', '-b', 'integration', integration, 'main'])).exitCode, 0);
      final file = File(p.join(onIntegration ? integration : source, '.mcp.json'))..writeAsStringSync('{}');
      final before = (await _git(repo.path, ['rev-parse', 'integration'])).stdout;

      Future<WorkflowGitPromotionResult> promote([String? reviewed]) => promoteWorkflowBranchLocally(
        projectDir: repo.path,
        runId: 'held',
        branch: 'story',
        integrationBranch: 'integration',
        strategy: 'merge',
        approvedCandidate: reviewed,
      );

      final first = await promote() as WorkflowGitPromotionHeld;
      expect(first.paths, ['.mcp.json']);
      expect(first.destination, 'integration');
      expect((await _git(repo.path, ['rev-parse', 'integration'])).stdout, before);
      expect((await _git(file.parent.path, ['status', '--porcelain'])).stdout, contains('?? .mcp.json'));

      final publish = await publishWorkflowBranchLocally(
        projectDir: repo.path,
        branch: onIntegration ? 'integration' : 'story',
        baseRef: 'main',
        approvedCandidate: first.candidate,
      );
      expect(publish.status, WorkflowPublishStatus.held);
      expect(publish.heldCandidate, isNot(first.candidate));

      file.writeAsStringSync('{"changed": true}');
      final second = await promote(first.candidate) as WorkflowGitPromotionHeld;
      expect(second.paths, first.paths);
      expect(second.candidate, isNot(first.candidate));
      expect((await _git(repo.path, ['rev-parse', 'integration'])).stdout, before);

      expect(await promote(second.candidate), isA<WorkflowGitPromotionSuccess>());
      expect((await _git(repo.path, ['show', 'integration:.mcp.json'])).stdout, '{"changed": true}');
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
        final remote = p.join(tempDir.path, 'remote.git');
        expect((await _git(repo.path, ['init', '--bare', remote])).exitCode, 0);
        expect((await _git(repo.path, ['remote', 'add', 'origin', remote])).exitCode, 0);
        final before = (await _git(repo.path, ['rev-parse', 'HEAD'])).stdout;
        var pushed = 0;
        var fetched = 0;
        Future<WorkflowGitPublishResult> publish([String? reviewed]) => remotePush
            ? publishWorkflowBranchWithRemotePush(
                projectDir: repo.path,
                branch: 'publish',
                baseRef: 'main',
                destination: remote,
                approvedCandidate: reviewed,
                pushBranch: (revision) async {
                  pushed++;
                  expect((await _git(repo.path, ['push', 'origin', '$revision:refs/heads/publish'])).exitCode, 0);
                  return const PushSuccess();
                },
                fetchRemoteTrackingRef: () {
                  fetched++;
                  return _git(repo.path, ['fetch', 'origin', 'refs/heads/publish:refs/remotes/origin/publish']);
                },
              )
            : publishWorkflowBranchLocally(
                projectDir: repo.path,
                branch: 'publish',
                baseRef: 'main',
                approvedCandidate: reviewed,
              );
        final first = await publish();
        expect(first.status, WorkflowPublishStatus.held);
        expect(first.heldPaths, ['.mcp.json']);
        expect(first.heldCandidate, isNotNull);
        expect((await _git(repo.path, ['rev-parse', 'HEAD'])).stdout, before);
        expect(
          (await _git(repo.path, ['status', '--porcelain'])).stdout,
          committed ? isEmpty : contains('?? .mcp.json'),
        );
        expect(pushed, 0);
        expect(fetched, 0);

        File(p.join(repo.path, '.mcp.json')).writeAsStringSync('{"changed": true}');
        final second = await publish(first.heldCandidate);
        expect(second.status, WorkflowPublishStatus.held);
        expect(second.heldPaths, first.heldPaths);
        expect(second.heldCandidate, isNot(first.heldCandidate));
        expect((await _git(remote, ['show-ref', '--verify', 'refs/heads/publish'])).exitCode, isNot(0));

        final released = await publish(second.heldCandidate);
        expect(released.status, WorkflowPublishStatus.success, reason: released.error);
        expect((await _git(remote, ['show', 'publish:.mcp.json'])).stdout, '{"changed": true}');
        expect(pushed, remotePush ? 1 : 0);
        expect(fetched, remotePush ? 1 : 0);
      });
    }
    test('execution-surface publish metadata errors refuse push (remotePush=$remotePush)', () async {
      var pushed = false;
      final result = remotePush
          ? await publishWorkflowBranchWithRemotePush(
              projectDir: tempDir.path,
              branch: 'publish',
              baseRef: 'main',
              pushBranch: (revision) async {
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

  test('execution-surface publish approval does not follow a replacement push URL', () async {
    final repo = await initGitRepo();
    addTearDown(() => repo.deleteSync(recursive: true));
    final original = p.join(tempDir.path, 'original.git');
    final replacement = p.join(tempDir.path, 'replacement.git');
    expect((await _git(repo.path, ['remote', 'add', 'origin', original])).exitCode, 0);
    expect((await _git(repo.path, ['switch', '-c', 'publish'])).exitCode, 0);
    File(p.join(repo.path, '.envrc')).writeAsStringSync('fixture\n');

    Future<WorkflowGitPublishResult> publish([String? approved]) => publishWorkflowBranchLocally(
      projectDir: repo.path,
      branch: 'publish',
      baseRef: 'main',
      approvedCandidate: approved,
    );

    final held = await publish();
    expect(held.status, WorkflowPublishStatus.held, reason: held.error);
    expect((await _git(repo.path, ['remote', 'set-url', '--push', 'origin', replacement])).exitCode, 0);
    final changedDestination = await publish(held.heldCandidate);
    expect(changedDestination.status, WorkflowPublishStatus.held, reason: changedDestination.error);
    expect(changedDestination.heldCandidate, isNot(held.heldCandidate));
    expect(changedDestination.heldDestination, 'origin/publish');
  });

  Future<({Directory repo, Future<WorkflowGitPublishResult> Function([String?]) publish, bool Function() pushed})>
  filteredPublishFixture(String cleanFilter) async {
    final repo = await initGitRepo();
    addTearDown(() => repo.deleteSync(recursive: true));
    expect((await _git(repo.path, ['switch', '-c', 'publish'])).exitCode, 0);
    expect((await _git(repo.path, ['config', 'filter.fixture.clean', cleanFilter])).exitCode, 0);
    File(p.join(repo.path, '.gitattributes')).writeAsStringSync('.envrc filter=fixture\n');
    File(p.join(repo.path, '.envrc')).writeAsStringSync('original\n');
    var pushed = false;
    Future<WorkflowGitPublishResult> publish([String? approved]) => publishWorkflowBranchWithRemotePush(
      projectDir: repo.path,
      branch: 'publish',
      baseRef: 'main',
      approvedCandidate: approved,
      pushBranch: (_) async {
        pushed = true;
        return const PushSuccess();
      },
    );
    return (repo: repo, publish: publish, pushed: () => pushed);
  }

  test('execution-surface preview stages through configured filters, so the approved sweep publishes', () async {
    final fixture = await filteredPublishFixture("sed 's/original/changed/'");

    final held = await fixture.publish();
    expect(held.status, WorkflowPublishStatus.held, reason: held.error);
    expect((await _git(fixture.repo.path, ['status', '--porcelain'])).stdout, contains('?? .envrc'));
    final released = await fixture.publish(held.heldCandidate);
    expect(released.status, WorkflowPublishStatus.success, reason: released.error);
    expect(fixture.pushed(), isTrue);
    expect((await _git(fixture.repo.path, ['show', 'publish:.envrc'])).stdout, 'changed\n');
  });

  test('execution-surface sweep refuses a tree that differs from the approved preview', () async {
    // The preview stages into a scratch index named by GIT_INDEX_FILE; the
    // sweep uses the worktree's own index, so this filter cleans differently.
    final fixture = await filteredPublishFixture(
      r"""if [ -n "$GIT_INDEX_FILE" ]; then cat; else sed 's/original/changed/'; fi""",
    );
    final head = (await _git(fixture.repo.path, ['rev-parse', 'HEAD'])).stdout;

    final held = await fixture.publish();
    expect(held.status, WorkflowPublishStatus.held, reason: held.error);
    final released = await fixture.publish(held.heldCandidate);
    expect(released.status, WorkflowPublishStatus.failed);
    expect(released.error, contains('Git staged a different tree'));
    expect(fixture.pushed(), isFalse);
    expect((await _git(fixture.repo.path, ['rev-parse', 'HEAD'])).stdout, head);
  });

  for (final splitIndex in [true, false]) {
    test('execution-surface preview refuses an unusable index (split=$splitIndex)', () async {
      final repo = await initGitRepo();
      addTearDown(() => repo.deleteSync(recursive: true));
      expect((await _git(repo.path, ['switch', '-c', 'publish'])).exitCode, 0);
      if (splitIndex) {
        expect((await _git(repo.path, ['update-index', '--split-index'])).exitCode, 0);
      } else {
        File(p.join(repo.path, '.git', 'index')).deleteSync();
      }

      final result = await publishWorkflowBranchWithRemotePush(
        projectDir: repo.path,
        branch: 'publish',
        baseRef: 'main',
        pushBranch: (_) async => throw StateError('Push would deliver an unreadable index.'),
      );
      expect(result.status, WorkflowPublishStatus.failed);
      expect(result.error, contains(splitIndex ? 'cannot preview a split index' : 'index'));
    });
  }

  test('preview preserves tracked paths omitted by sparse checkout', () async {
    final repo = await initGitRepo(extraFiles: {'.github/workflows/example.yml': 'fixture\n', 'docs/note': 'base\n'});
    addTearDown(() => repo.deleteSync(recursive: true));
    expect((await _git(repo.path, ['switch', '-c', 'publish'])).exitCode, 0);
    expect((await _git(repo.path, ['sparse-checkout', 'set', '--cone', '--sparse-index', 'docs'])).exitCode, 0);
    expect(File(p.join(repo.path, '.github', 'workflows', 'example.yml')).existsSync(), isFalse);
    File(p.join(repo.path, 'docs', 'note')).writeAsStringSync('edited\n');

    final result = await publishWorkflowBranchWithRemotePush(
      projectDir: repo.path,
      branch: 'publish',
      baseRef: 'main',
      pushBranch: (revision) async {
        expect((await _git(repo.path, ['show', '$revision:.github/workflows/example.yml'])).stdout, 'fixture\n');
        expect((await _git(repo.path, ['show', '$revision:docs/note'])).stdout, 'edited\n');
        return const PushSuccess();
      },
    );
    expect(result.status, WorkflowPublishStatus.success, reason: result.error);
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
      pushBranch: (revision) async {
        pushed = true;
        File(p.join(repoDir.path, 'late-edit.md')).writeAsStringSync('added after validation\n');
        expect((await _git(repoDir.path, ['add', 'late-edit.md'])).exitCode, 0);
        expect((await _git(repoDir.path, ['commit', '-m', 'unrelated local edit'])).exitCode, 0);
        final push = await _git(repoDir.path, ['push', 'origin', '$revision:refs/heads/$branch']);
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
    expect((tree.stdout as String).split('\n'), isNot(contains('late-edit.md')));
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
      pushBranch: (revision) async => const PushAuthFailure('Authentication denied (credential: github-main).'),
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

  group('tampered worktree gitlink', () {
    late HostWorktreeTamperFixture fixture;

    setUp(() async {
      fixture = await HostWorktreeTamperFixture.create();
      fixture.write('work.txt');
      fixture.write('.envrc');
    });
    tearDown(() => fixture.dispose());

    Future<String> branchTip() async =>
        ((await HostWorktreeTamperFixture.git(fixture.projectDir, ['rev-parse', fixture.branch])).stdout as String)
            .trim();
    List<int> projectIndex() => File(p.join(fixture.projectDir, '.git', 'index')).readAsBytesSync();
    List<int> worktreeIndex() => File(p.join(fixture.adminDir, 'index')).readAsBytesSync();

    test('the sweep refuses a gitlink rewritten to an agent-built gitdir and runs none of its config', () async {
      await fixture.rewriteGitlinkToAgentGitdir();
      final tip = await branchTip();
      final index = projectIndex();
      final storyIndex = worktreeIndex();

      await expectLater(
        commitWorkflowWorktreeChangesIfNeeded(
          projectDir: fixture.projectDir,
          branch: fixture.branch,
          commitMessage: 'sweep',
        ),
        throwsA(isA<TamperedWorktreeException>().having((e) => e.worktreePath, 'worktreePath', fixture.worktreePath)),
      );

      expect(fixture.existingMarkers, isEmpty);
      expect(await branchTip(), tip);
      expect(projectIndex(), index);
      expect(worktreeIndex(), storyIndex);
    });

    for (final strategy in ['promote', 'publish']) {
      test('$strategy computes no execution-surface candidate for the tampered worktree', () async {
        await fixture.rewriteGitlinkToAgentGitdir();
        final tip = await branchTip();

        final String? error;
        if (strategy == 'promote') {
          final result = await promoteWorkflowBranchLocally(
            projectDir: fixture.projectDir,
            runId: 'tamper',
            branch: fixture.branch,
            integrationBranch: 'main',
            strategy: 'squash',
          );
          expect(result, isA<WorkflowGitPromotionError>());
          error = (result as WorkflowGitPromotionError).message;
        } else {
          final result = await publishWorkflowBranchLocally(
            projectDir: fixture.projectDir,
            branch: fixture.branch,
            baseRef: 'main',
          );
          expect(result.status, WorkflowPublishStatus.failed);
          expect(result.heldCandidate, isNull);
          error = result.error;
        }

        expect(error, contains('tampered worktree "${fixture.worktreePath}"'));
        expect(fixture.existingMarkers, isEmpty);
        expect(await branchTip(), tip);
      });
    }

    final variants = <String, Future<void> Function()>{
      'replaced by a repository': () => fixture.replaceGitlinkWithRepository(),
      'replaced by a symlink': () async => fixture.replaceGitlinkWithSymlink(),
      'deleted': () async => fixture.deleteGitlink(),
    };
    for (final MapEntry(key: name, value: tamper) in variants.entries) {
      test('the sweep refuses a gitlink $name and commits nothing anywhere', () async {
        await tamper();
        final tip = await branchTip();

        await expectLater(
          commitWorkflowWorktreeChangesIfNeeded(
            projectDir: fixture.projectDir,
            branch: fixture.branch,
            commitMessage: 'sweep',
          ),
          throwsA(isA<TamperedWorktreeException>()),
        );
        await expectLater(
          cleanupWorktreeForRetry(projectDir: fixture.projectDir, branch: fixture.branch, preAttemptSha: tip),
          throwsA(isA<TamperedWorktreeException>()),
        );

        expect(fixture.existingMarkers, isEmpty);
        expect(await branchTip(), tip);
        final agentRepo = Directory(p.join(fixture.worktreePath, '.git'));
        if (agentRepo.existsSync() &&
            FileSystemEntity.typeSync(agentRepo.path, followLinks: false) == FileSystemEntityType.directory) {
          final log = await Process.run('git', [
            'rev-parse',
            '--verify',
            'HEAD',
          ], workingDirectory: fixture.worktreePath);
          expect(log.exitCode, isNot(0), reason: 'nothing may be committed into the agent-created repository');
        }
      });
    }

    test('a nested repository recorded as a gitlink cannot run its filters through the sweep', () async {
      await fixture.nestRepository();

      try {
        await commitWorkflowWorktreeChangesIfNeeded(
          projectDir: fixture.projectDir,
          branch: fixture.branch,
          commitMessage: 'sweep',
        );
      } on TamperedWorktreeException {
        // Refusing is an allowed outcome; running the nested config is not.
      }

      expect(fixture.existingMarkers, isEmpty);
    });

    test('an untampered worktree still sweeps and promotes', () async {
      final result = await promoteWorkflowBranchLocally(
        projectDir: fixture.projectDir,
        runId: 'clean',
        branch: fixture.branch,
        integrationBranch: 'main',
        strategy: 'squash',
      );
      final held = result as WorkflowGitPromotionHeld;
      expect(held.paths, ['.envrc']);
      expect(
        await promoteWorkflowBranchLocally(
          projectDir: fixture.projectDir,
          runId: 'clean',
          branch: fixture.branch,
          integrationBranch: 'main',
          strategy: 'squash',
          approvedCandidate: held.candidate,
        ),
        isA<WorkflowGitPromotionSuccess>(),
      );
      final shown = await HostWorktreeTamperFixture.git(fixture.projectDir, ['show', 'main:work.txt']);
      expect(shown.stdout, 'changed\n');
    });
  });
}
