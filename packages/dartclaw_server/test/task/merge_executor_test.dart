import 'dart:io';

import 'package:dartclaw_server/src/task/merge_executor.dart';
import 'package:dartclaw_server/src/task/worktree_manager.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show GitStatus, WorkflowGitCommit, WorkflowGitException, WorkflowGitMergeStrategy, WorkflowGitPort;
import 'package:test/test.dart';

void main() {
  group('MergeExecutor', () {
    late MergeExecutor executor;
    late List<({String executable, List<String> args})> calls;
    late Map<String, ProcessResult> responses;

    ProcessResult pr(String stdout, {String stderr = '', int exitCode = 0}) {
      return ProcessResult(0, exitCode, stdout, stderr);
    }

    Future<ProcessResult> mockRunner(String executable, List<String> arguments, {String? workingDirectory}) async {
      calls.add((executable: executable, args: arguments));
      final key = arguments.join(' ');
      return responses[key] ?? pr('');
    }

    setUp(() {
      calls = [];
      responses = {'status --porcelain': pr('')};
    });

    test('throws PreMergeInvariantException when the index is already dirty', () async {
      executor = MergeExecutor(projectDir: '/project', gitPort: _ProcessRunnerGitPortForTest(mockRunner));

      responses['status --porcelain'] = pr(' M lib/main.dart\n');

      await expectLater(
        () => executor.merge(branch: 'dartclaw/task-t1', baseRef: 'main', taskId: 't1', taskTitle: 'Fix bug'),
        throwsA(
          isA<PreMergeInvariantException>()
              .having((error) => error.reason, 'reason', isA<UncleanIndex>())
              .having((error) => error.detail, 'detail', contains('clean index')),
        ),
      );

      final gitArgs = calls.map((c) => c.args.join(' ')).toList();
      expect(gitArgs, ['status --porcelain']);
    });

    test('throws PreMergeInvariantException when untracked files overlap with stash', () async {
      executor = MergeExecutor(projectDir: '/project', gitPort: _ProcessRunnerGitPortForTest(mockRunner));

      responses['status --porcelain'] = pr('?? foo.md\n');
      responses['stash show --name-only stash@{0}'] = pr('foo.md\nbar.md\n');

      await expectLater(
        () => executor.merge(branch: 'dartclaw/task-t1', baseRef: 'main', taskId: 't1', taskTitle: 'Fix bug'),
        throwsA(
          isA<PreMergeInvariantException>().having((error) => error.reason, 'reason', isA<UntrackedOverlap>()).having(
            (error) => (error.reason as UntrackedOverlap).paths,
            'paths',
            ['foo.md'],
          ),
        ),
      );

      final gitArgs = calls.map((c) => c.args.join(' ')).toList();
      expect(gitArgs, ['status --porcelain', 'stash show --name-only stash@{0}']);
    });

    test('throws PreMergeInvariantException when target branch SHA drifted', () async {
      executor = MergeExecutor(projectDir: '/project', gitPort: _ProcessRunnerGitPortForTest(mockRunner));

      responses['rev-parse main'] = pr('new-sha\n');

      await expectLater(
        () => executor.merge(
          branch: 'dartclaw/task-t1',
          baseRef: 'main',
          taskId: 't1',
          taskTitle: 'Fix bug',
          expectedBaseSha: 'old-sha',
        ),
        throwsA(
          isA<PreMergeInvariantException>()
              .having((error) => error.reason, 'reason', isA<TargetShaMismatch>())
              .having((error) => (error.reason as TargetShaMismatch).expected, 'expected', 'old-sha')
              .having((error) => (error.reason as TargetShaMismatch).actual, 'actual', 'new-sha'),
        ),
      );

      final gitArgs = calls.map((c) => c.args.join(' ')).toList();
      expect(gitArgs, ['status --porcelain', 'rev-parse main']);
    });

    test('PreMergeInvariantException reason is switch-exhaustive', () {
      const error = PreMergeInvariantException(
        reason: UncleanIndex(modified: ['lib/main.dart']),
        detail: 'index dirty',
      );

      final label = switch (error.reason) {
        UncleanIndex() => 'unclean-index',
        UntrackedOverlap() => 'untracked-overlap',
        TargetShaMismatch() => 'target-sha-mismatch',
      };

      expect(label, 'unclean-index');
      expect(error.detail, 'index dirty');
    });

    test('squash merge calls correct git commands in order', () async {
      executor = MergeExecutor(projectDir: '/project', gitPort: _ProcessRunnerGitPortForTest(mockRunner));

      responses['status --porcelain'] = pr('');
      // rev-parse HEAD (record original)
      responses['rev-parse HEAD'] = pr('original-sha\n');
      responses['current-branch'] = pr('main\n');
      responses['stash --include-untracked'] = pr('No local changes to save\n');
      responses['checkout main'] = pr('');
      responses['merge --squash dartclaw/task-t1'] = pr('');
      responses['commit -m task(t1): Fix bug'] = pr('');
      responses['checkout main'] = pr('');

      await executor.merge(branch: 'dartclaw/task-t1', baseRef: 'main', taskId: 't1', taskTitle: 'Fix bug');

      final gitArgs = calls.map((c) => c.args.join(' ')).toList();

      // Verify the order of git commands
      expect(gitArgs[0], 'status --porcelain'); // pre-merge invariant
      expect(gitArgs[1], 'rev-parse HEAD'); // record original HEAD
      expect(gitArgs[2], 'current-branch'); // record original branch
      expect(gitArgs[3], 'stash --include-untracked'); // stash
      expect(gitArgs[4], 'checkout main'); // checkout base ref
      expect(gitArgs[5], 'merge --squash dartclaw/task-t1'); // squash merge
      expect(gitArgs[6], 'commit -m task(t1): Fix bug'); // commit
      expect(gitArgs[7], 'rev-parse HEAD'); // get commit SHA
      expect(gitArgs[8], 'checkout main'); // restore original branch
    });

    test('squash merge returns MergeSuccess with commit SHA', () async {
      executor = MergeExecutor(projectDir: '/project', gitPort: _ProcessRunnerGitPortForTest(mockRunner));

      responses['status --porcelain'] = pr('');
      responses['rev-parse HEAD'] = pr('abc123\n');
      responses['current-branch'] = pr('develop\n');
      responses['stash --include-untracked'] = pr('No local changes to save\n');
      responses['checkout main'] = pr('');
      responses['merge --squash dartclaw/task-t1'] = pr('');
      responses['commit -m task(t1): Fix bug'] = pr('');
      responses['checkout develop'] = pr('');

      final result = await executor.merge(
        branch: 'dartclaw/task-t1',
        baseRef: 'main',
        taskId: 't1',
        taskTitle: 'Fix bug',
      );

      expect(result, isA<MergeSuccess>());
      final success = result as MergeSuccess;
      expect(success.commitSha, 'abc123'); // trimmed
      expect(success.commitMessage, 'task(t1): Fix bug');
    });

    test('merge strategy calls git merge --no-ff', () async {
      executor = MergeExecutor(projectDir: '/project', gitPort: _ProcessRunnerGitPortForTest(mockRunner));

      responses['status --porcelain'] = pr('');
      responses['rev-parse HEAD'] = pr('original-sha\n');
      responses['current-branch'] = pr('main\n');
      responses['stash --include-untracked'] = pr('No local changes to save\n');
      responses['checkout main'] = pr('');
      responses['merge --no-ff dartclaw/task-t1 -m task(t1): Fix bug'] = pr('');
      responses['checkout main'] = pr('');

      final result = await executor.merge(
        branch: 'dartclaw/task-t1',
        baseRef: 'main',
        taskId: 't1',
        taskTitle: 'Fix bug',
        strategy: MergeStrategy.merge,
      );

      expect(result, isA<MergeSuccess>());

      final gitArgs = calls.map((c) => c.args.join(' ')).toList();
      expect(gitArgs, contains('merge --no-ff dartclaw/task-t1 -m task(t1): Fix bug'));
    });

    test('merge conflict detected and returned with conflicting file list', () async {
      executor = MergeExecutor(projectDir: '/project', gitPort: _ProcessRunnerGitPortForTest(mockRunner));

      responses['status --porcelain'] = pr('');
      responses['rev-parse HEAD'] = pr('original-sha\n');
      responses['current-branch'] = pr('main\n');
      responses['stash --include-untracked'] = pr('No local changes to save\n');
      responses['checkout main'] = pr('');
      responses['merge --squash dartclaw/task-t1'] = pr(
        'CONFLICT (content): Merge conflict in lib/main.dart\n',
        exitCode: 1,
        stderr: 'Automatic merge failed; fix conflicts and then commit the result.',
      );
      responses['diff --name-only --diff-filter=U'] = pr('lib/main.dart\nlib/utils.dart\n');
      responses['reset --hard HEAD'] = pr('');
      responses['checkout main'] = pr('');

      final result = await executor.merge(
        branch: 'dartclaw/task-t1',
        baseRef: 'main',
        taskId: 't1',
        taskTitle: 'Fix bug',
      );

      expect(result, isA<MergeConflict>());
      final conflict = result as MergeConflict;
      expect(conflict.conflictingFiles, ['lib/main.dart', 'lib/utils.dart']);
      expect(conflict.details, contains('Automatic merge failed'));
    });

    test('squash conflict restores clean state with reset --hard', () async {
      executor = MergeExecutor(projectDir: '/project', gitPort: _ProcessRunnerGitPortForTest(mockRunner));

      responses['status --porcelain'] = pr('');
      responses['rev-parse HEAD'] = pr('original-sha\n');
      responses['current-branch'] = pr('main\n');
      responses['stash --include-untracked'] = pr('No local changes to save\n');
      responses['checkout main'] = pr('');
      responses['merge --squash dartclaw/task-t1'] = pr('', exitCode: 1, stderr: 'conflict');
      responses['diff --name-only --diff-filter=U'] = pr('lib/a.dart\n');
      responses['reset --hard HEAD'] = pr('');
      responses['checkout main'] = pr('');

      await executor.merge(branch: 'dartclaw/task-t1', baseRef: 'main', taskId: 't1', taskTitle: 'Fix bug');

      final gitArgs = calls.map((c) => c.args.join(' ')).toList();
      expect(gitArgs, contains('reset --hard HEAD'));
      expect(gitArgs, isNot(contains('merge --abort')));
    });

    test('non-squash conflict still aborts the merge', () async {
      executor = MergeExecutor(projectDir: '/project', gitPort: _ProcessRunnerGitPortForTest(mockRunner));

      responses['status --porcelain'] = pr('');
      responses['rev-parse HEAD'] = pr('original-sha\n');
      responses['current-branch'] = pr('main\n');
      responses['stash --include-untracked'] = pr('No local changes to save\n');
      responses['checkout main'] = pr('');
      responses['merge --no-ff dartclaw/task-t1 -m task(t1): Fix bug'] = pr('', exitCode: 1, stderr: 'conflict');
      responses['diff --name-only --diff-filter=U'] = pr('lib/a.dart\n');
      responses['merge --abort'] = pr('');
      responses['checkout main'] = pr('');

      await executor.merge(
        branch: 'dartclaw/task-t1',
        baseRef: 'main',
        taskId: 't1',
        taskTitle: 'Fix bug',
        strategy: MergeStrategy.merge,
      );

      final gitArgs = calls.map((c) => c.args.join(' ')).toList();
      expect(gitArgs, contains('merge --abort'));
    });

    test('uncommitted changes stashed before merge and restored after', () async {
      executor = MergeExecutor(projectDir: '/project', gitPort: _ProcessRunnerGitPortForTest(mockRunner));

      responses['status --porcelain'] = pr('');
      responses['rev-parse HEAD'] = pr('original-sha\n');
      responses['current-branch'] = pr('develop\n');
      responses['stash --include-untracked'] = pr('Saved working directory and index state\n');
      responses['checkout main'] = pr('');
      responses['merge --squash dartclaw/task-t1'] = pr('');
      responses['commit -m task(t1): Fix bug'] = pr('');
      responses['checkout develop'] = pr('');
      responses['stash pop'] = pr('');

      await executor.merge(branch: 'dartclaw/task-t1', baseRef: 'main', taskId: 't1', taskTitle: 'Fix bug');

      final gitArgs = calls.map((c) => c.args.join(' ')).toList();

      // Stash before merge
      final stashIndex = gitArgs.indexOf('stash --include-untracked');
      final mergeIndex = gitArgs.indexOf('merge --squash dartclaw/task-t1');
      expect(stashIndex, lessThan(mergeIndex));

      // Stash pop after checkout restore
      expect(gitArgs.last, 'stash pop');
    });

    test('stash pop "already exists" overlap drops the stash entry', () async {
      // Repro for the map/fan-in case: stashed untracked files collide with
      // the merge-introduced files. `git stash pop` fails and leaves the stash
      // in place unless we drop it.
      executor = MergeExecutor(projectDir: '/project', gitPort: _ProcessRunnerGitPortForTest(mockRunner));

      responses['status --porcelain'] = pr('');
      responses['rev-parse HEAD'] = pr('original-sha\n');
      responses['current-branch'] = pr('integration\n');
      responses['stash --include-untracked'] = pr('Saved working directory and index state\n');
      responses['checkout main'] = pr('');
      responses['merge --squash dartclaw/task-t1'] = pr('');
      responses['commit -m task(t1): Fix bug'] = pr('');
      responses['checkout integration'] = pr('');
      responses['stash pop'] = pr(
        '',
        exitCode: 1,
        stderr:
            'notes/e2e-plan-a.md already exists, no checkout\n'
            'notes/e2e-plan-b.md already exists, no checkout\n',
      );
      responses['stash drop'] = pr('Dropped refs/stash@{0}\n');

      await executor.merge(branch: 'dartclaw/task-t1', baseRef: 'main', taskId: 't1', taskTitle: 'Fix bug');

      final gitArgs = calls.map((c) => c.args.join(' ')).toList();
      expect(gitArgs, contains('stash pop'));
      expect(gitArgs, contains('stash drop'));
      // Drop must follow pop, not precede it.
      expect(gitArgs.indexOf('stash drop'), greaterThan(gitArgs.indexOf('stash pop')));
    });

    test('stash pop failure for unrelated reason keeps the stash entry', () async {
      executor = MergeExecutor(projectDir: '/project', gitPort: _ProcessRunnerGitPortForTest(mockRunner));

      responses['status --porcelain'] = pr('');
      responses['rev-parse HEAD'] = pr('original-sha\n');
      responses['current-branch'] = pr('main\n');
      responses['stash --include-untracked'] = pr('Saved working directory and index state\n');
      responses['checkout main'] = pr('');
      responses['merge --squash dartclaw/task-t1'] = pr('');
      responses['commit -m task(t1): Fix bug'] = pr('');
      responses['checkout main'] = pr('');
      responses['stash pop'] = pr('', exitCode: 1, stderr: 'CONFLICT (content): Merge conflict in lib/main.dart\n');

      await executor.merge(branch: 'dartclaw/task-t1', baseRef: 'main', taskId: 't1', taskTitle: 'Fix bug');

      final gitArgs = calls.map((c) => c.args.join(' ')).toList();
      expect(gitArgs, contains('stash pop'));
      expect(gitArgs, isNot(contains('stash drop')));
    });

    test('no stash pop when there were no uncommitted changes', () async {
      executor = MergeExecutor(projectDir: '/project', gitPort: _ProcessRunnerGitPortForTest(mockRunner));

      responses['status --porcelain'] = pr('');
      responses['rev-parse HEAD'] = pr('original-sha\n');
      responses['current-branch'] = pr('main\n');
      responses['stash --include-untracked'] = pr('No local changes to save\n');
      responses['checkout main'] = pr('');
      responses['merge --squash dartclaw/task-t1'] = pr('');
      responses['commit -m task(t1): Fix bug'] = pr('');
      responses['checkout main'] = pr('');

      await executor.merge(branch: 'dartclaw/task-t1', baseRef: 'main', taskId: 't1', taskTitle: 'Fix bug');

      final gitArgs = calls.map((c) => c.args.join(' ')).toList();
      expect(gitArgs, isNot(contains('stash pop')));
    });

    test('original branch restored after successful merge', () async {
      executor = MergeExecutor(projectDir: '/project', gitPort: _ProcessRunnerGitPortForTest(mockRunner));

      responses['rev-parse HEAD'] = pr('original-sha\n');
      responses['current-branch'] = pr('feature-x\n');
      responses['stash --include-untracked'] = pr('No local changes to save\n');
      responses['checkout main'] = pr('');
      responses['merge --squash dartclaw/task-t1'] = pr('');
      responses['commit -m task(t1): Fix bug'] = pr('');
      responses['checkout feature-x'] = pr('');

      await executor.merge(branch: 'dartclaw/task-t1', baseRef: 'main', taskId: 't1', taskTitle: 'Fix bug');

      final gitArgs = calls.map((c) => c.args.join(' ')).toList();
      // Last checkout should restore original branch
      final checkouts = gitArgs.where((a) => a.startsWith('checkout ')).toList();
      expect(checkouts.last, 'checkout feature-x');
    });

    test('original branch restored after conflict', () async {
      executor = MergeExecutor(projectDir: '/project', gitPort: _ProcessRunnerGitPortForTest(mockRunner));

      responses['rev-parse HEAD'] = pr('original-sha\n');
      responses['current-branch'] = pr('feature-y\n');
      responses['stash --include-untracked'] = pr('No local changes to save\n');
      responses['checkout main'] = pr('');
      responses['merge --squash dartclaw/task-t1'] = pr('', exitCode: 1, stderr: 'conflict');
      responses['diff --name-only --diff-filter=U'] = pr('a.dart\n');
      responses['reset --hard HEAD'] = pr('');
      responses['checkout feature-y'] = pr('');

      final result = await executor.merge(
        branch: 'dartclaw/task-t1',
        baseRef: 'main',
        taskId: 't1',
        taskTitle: 'Fix bug',
      );

      expect(result, isA<MergeConflict>());

      final gitArgs = calls.map((c) => c.args.join(' ')).toList();
      final checkouts = gitArgs.where((a) => a.startsWith('checkout ')).toList();
      expect(checkouts.last, 'checkout feature-y');
    });

    test('detached HEAD restored by SHA after merge', () async {
      executor = MergeExecutor(projectDir: '/project', gitPort: _ProcessRunnerGitPortForTest(mockRunner));

      responses['rev-parse HEAD'] = pr('deadbeef123\n');
      responses['current-branch'] = pr('HEAD\n'); // detached
      responses['stash --include-untracked'] = pr('No local changes to save\n');
      responses['checkout main'] = pr('');
      responses['merge --squash dartclaw/task-t1'] = pr('');
      responses['commit -m task(t1): Fix bug'] = pr('');
      responses['checkout deadbeef123'] = pr('');

      await executor.merge(branch: 'dartclaw/task-t1', baseRef: 'main', taskId: 't1', taskTitle: 'Fix bug');

      final gitArgs = calls.map((c) => c.args.join(' ')).toList();
      // When detached, restore by SHA
      final checkouts = gitArgs.where((a) => a.startsWith('checkout ')).toList();
      expect(checkouts.last, 'checkout deadbeef123');
    });

    test('git failure on rev-parse throws WorktreeException', () async {
      executor = MergeExecutor(projectDir: '/project', gitPort: _ProcessRunnerGitPortForTest(mockRunner));

      responses['rev-parse HEAD'] = pr('', exitCode: 128, stderr: 'fatal: not a git repository');

      expect(
        () => executor.merge(branch: 'dartclaw/task-t1', baseRef: 'main', taskId: 't1', taskTitle: 'Fix bug'),
        throwsA(isA<WorktreeException>()),
      );
    });

    test('git failure on checkout throws WorktreeException', () async {
      executor = MergeExecutor(projectDir: '/project', gitPort: _ProcessRunnerGitPortForTest(mockRunner));

      responses['rev-parse HEAD'] = pr('original-sha\n');
      responses['current-branch'] = pr('main\n');
      responses['stash --include-untracked'] = pr('No local changes to save\n');
      responses['checkout main'] = pr('', exitCode: 1, stderr: 'error: pathspec not found');

      expect(
        () => executor.merge(branch: 'dartclaw/task-t1', baseRef: 'main', taskId: 't1', taskTitle: 'Fix bug'),
        throwsA(isA<WorktreeException>()),
      );
    });

    test('commit message follows task(id): title format', () async {
      executor = MergeExecutor(projectDir: '/project', gitPort: _ProcessRunnerGitPortForTest(mockRunner));

      responses['rev-parse HEAD'] = pr('sha\n');
      responses['current-branch'] = pr('main\n');
      responses['stash --include-untracked'] = pr('No local changes to save\n');
      responses['checkout main'] = pr('');
      responses['merge --squash dartclaw/task-abc'] = pr('');
      responses['commit -m task(abc): Add search feature'] = pr('');
      responses['checkout main'] = pr('');

      final result = await executor.merge(
        branch: 'dartclaw/task-abc',
        baseRef: 'main',
        taskId: 'abc',
        taskTitle: 'Add search feature',
      );

      expect(result, isA<MergeSuccess>());
      expect((result as MergeSuccess).commitMessage, 'task(abc): Add search feature');

      final gitArgs = calls.map((c) => c.args.join(' ')).toList();
      expect(gitArgs, contains('commit -m task(abc): Add search feature'));
    });

    test('handles nothing-to-commit as empty merge success', () async {
      executor = MergeExecutor(projectDir: '/project', gitPort: _ProcessRunnerGitPortForTest(mockRunner));

      responses['rev-parse HEAD'] = pr('sha\n');
      responses['current-branch'] = pr('main\n');
      responses['stash --include-untracked'] = pr('No local changes to save\n');
      responses['checkout main'] = pr('');
      responses['merge --squash dartclaw/task-t1'] = pr('');
      responses['commit -m task(t1): Fix bug'] = pr('nothing to commit, working tree clean\n', exitCode: 1);
      responses['checkout main'] = pr('');

      final result = await executor.merge(
        branch: 'dartclaw/task-t1',
        baseRef: 'main',
        taskId: 't1',
        taskTitle: 'Fix bug',
      );

      expect(result, isA<MergeSuccess>());
    });

    test('default strategy is squash', () async {
      executor = MergeExecutor(projectDir: '/project', gitPort: _ProcessRunnerGitPortForTest(mockRunner));

      responses['rev-parse HEAD'] = pr('sha\n');
      responses['current-branch'] = pr('main\n');
      responses['stash --include-untracked'] = pr('No local changes to save\n');
      responses['checkout main'] = pr('');
      responses['merge --squash dartclaw/task-t1'] = pr('');
      responses['commit -m task(t1): Fix bug'] = pr('');
      responses['checkout main'] = pr('');

      await executor.merge(branch: 'dartclaw/task-t1', baseRef: 'main', taskId: 't1', taskTitle: 'Fix bug');

      final gitArgs = calls.map((c) => c.args.join(' ')).toList();
      expect(gitArgs, contains('merge --squash dartclaw/task-t1'));
    });
  });

  group('MergeConflict JSON', () {
    test('toJson includes conflicting files and details', () {
      final conflict = MergeConflict(conflictingFiles: ['lib/a.dart', 'lib/b.dart'], details: 'Automatic merge failed');

      final json = conflict.toJson();
      expect(json['conflictingFiles'], ['lib/a.dart', 'lib/b.dart']);
      expect(json['details'], 'Automatic merge failed');
    });
  });
}

final class _ProcessRunnerGitPortForTest implements WorkflowGitPort {
  final Future<ProcessResult> Function(String executable, List<String> arguments, {String? workingDirectory})
  processRunner;

  const _ProcessRunnerGitPortForTest(this.processRunner);

  @override
  Future<String> revParse(String worktreePath, String ref) async {
    final result = await _expect(['rev-parse', ref], worktreePath, 'Failed to resolve ref $ref');
    return _stdout(result).trim();
  }

  @override
  Future<String> currentBranch(String worktreePath) async {
    final result = await _expect(['current-branch'], worktreePath, 'Failed to record current branch');
    return _stdout(result).trim();
  }

  @override
  Future<List<String>> diffNameOnly(
    String worktreePath, {
    String? against,
    bool cached = false,
    String? diffFilter,
  }) async {
    final args = <String>['diff'];
    if (cached) {
      args.add('--cached');
    }
    args.add('--name-only');
    if (diffFilter != null && diffFilter.trim().isNotEmpty) {
      args.add('--diff-filter=$diffFilter');
    }
    if (against != null && against.trim().isNotEmpty) {
      args.add(against);
    }
    final result = await _expect(args, worktreePath, 'Failed to list changed paths');
    final paths = _lines(_stdout(result)).toSet();
    if (!cached && (diffFilter == null || diffFilter.trim().isEmpty)) {
      paths.addAll(await untrackedFiles(worktreePath));
    }
    return paths.toList()..sort();
  }

  @override
  Future<bool> pathExistsAtRef(String worktreePath, {required String ref, required String path}) async {
    final result = await _git(['cat-file', '-e', '$ref:$path'], worktreePath);
    return result.exitCode == 0;
  }

  @override
  Future<GitStatus> status(String worktreePath) async {
    final result = await _expect(['status', '--porcelain'], worktreePath, 'Failed to inspect status');
    final modified = <String>[];
    final untracked = <String>[];
    for (final line in _lines(_stdout(result))) {
      if (line.startsWith('?? ')) {
        untracked.add(line.substring(3).trim());
      } else if (line.length > 3) {
        modified.add(line.substring(3).trim());
      } else {
        modified.add(line.trim());
      }
    }
    return GitStatus(indexClean: modified.isEmpty, modified: modified, untracked: untracked);
  }

  @override
  Future<List<String>> untrackedFiles(String worktreePath) async {
    return (await status(worktreePath)).untracked;
  }

  @override
  Future<List<String>> stashedPaths(String worktreePath, {int index = 0}) async {
    final result = await _git(['stash', 'show', '--name-only', 'stash@{$index}'], worktreePath);
    if (result.exitCode != 0) return const <String>[];
    return _lines(_stdout(result));
  }

  @override
  Future<void> add(String worktreePath, List<String> paths, {bool all = false}) async {
    if (!all && paths.isEmpty) return;
    await _expect(all ? <String>['add', '-A'] : <String>['add', '--', ...paths], worktreePath, 'Failed to stage paths');
  }

  @override
  Future<WorkflowGitCommit> commit(
    String worktreePath, {
    required String message,
    String? authorName,
    String? authorEmail,
  }) async {
    final args = <String>[
      if (authorName != null && authorName.trim().isNotEmpty) ...['-c', 'user.name=$authorName'],
      if (authorEmail != null && authorEmail.trim().isNotEmpty) ...['-c', 'user.email=$authorEmail'],
      'commit',
      '-m',
      message,
    ];
    await _expect(args, worktreePath, 'Failed to commit staged changes');
    return WorkflowGitCommit(sha: await revParse(worktreePath, 'HEAD'), message: message);
  }

  @override
  Future<void> checkout(String worktreePath, String ref) async {
    await _expect(['checkout', ref], worktreePath, 'Failed to checkout $ref');
  }

  @override
  Future<bool> stashPush(String worktreePath, {bool includeUntracked = true}) async {
    final args = <String>['stash', if (includeUntracked) '--include-untracked'];
    final result = await _expect(args, worktreePath, 'Failed to stash local changes');
    return !_stdout(result).contains('No local changes to save');
  }

  @override
  Future<void> stashPop(String worktreePath) async {
    await _expect(['stash', 'pop'], worktreePath, 'Failed to restore stash');
  }

  @override
  Future<void> stashDrop(String worktreePath, {int index = 0}) async {
    await _expect(['stash', 'drop'], worktreePath, 'Failed to drop stash entry');
  }

  @override
  Future<void> merge(
    String worktreePath, {
    required String ref,
    required WorkflowGitMergeStrategy strategy,
    String? message,
  }) async {
    final args = switch (strategy) {
      WorkflowGitMergeStrategy.squash => <String>['merge', '--squash', ref],
      WorkflowGitMergeStrategy.merge => <String>['merge', '--no-ff', ref, '-m', message ?? 'Merge $ref'],
    };
    await _expect(args, worktreePath, 'Failed to merge $ref');
  }

  @override
  Future<void> mergeAbort(String worktreePath) async {
    await _expect(['merge', '--abort'], worktreePath, 'Failed to abort merge');
  }

  @override
  Future<void> resetHard(String worktreePath, String ref) async {
    await _expect(['reset', '--hard', ref], worktreePath, 'Failed to reset');
  }

  Future<ProcessResult> _expect(List<String> args, String worktreePath, String message) async {
    final result = await _git(args, worktreePath);
    if (result.exitCode == 0) return result;
    throw WorkflowGitException(
      message,
      args: args,
      stdout: _stdout(result),
      stderr: _stderr(result),
      exitCode: result.exitCode,
    );
  }

  Future<ProcessResult> _git(List<String> args, String worktreePath) {
    return processRunner('git', args, workingDirectory: worktreePath);
  }

  static List<String> _lines(String output) =>
      output.split('\n').map((line) => line.trim()).where((line) => line.isNotEmpty).toList();

  static String _stdout(ProcessResult result) => result.stdout as String;

  static String _stderr(ProcessResult result) => result.stderr as String;
}
