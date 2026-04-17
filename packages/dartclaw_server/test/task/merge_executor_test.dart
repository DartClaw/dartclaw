import 'dart:io';

import 'package:dartclaw_server/src/task/merge_executor.dart';
import 'package:dartclaw_server/src/task/worktree_manager.dart';
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
      responses = {};
    });

    test('squash merge calls correct git commands in order', () async {
      executor = MergeExecutor(projectDir: '/project', processRunner: mockRunner);

      // rev-parse HEAD (record original)
      responses['rev-parse HEAD'] = pr('original-sha\n');
      responses['rev-parse --abbrev-ref HEAD'] = pr('main\n');
      responses['stash --include-untracked'] = pr('No local changes to save\n');
      responses['checkout main'] = pr('');
      responses['merge --squash dartclaw/task-t1'] = pr('');
      responses['commit -m task(t1): Fix bug'] = pr('');
      responses['checkout main'] = pr('');

      await executor.merge(branch: 'dartclaw/task-t1', baseRef: 'main', taskId: 't1', taskTitle: 'Fix bug');

      final gitArgs = calls.map((c) => c.args.join(' ')).toList();

      // Verify the order of git commands
      expect(gitArgs[0], 'rev-parse HEAD'); // record original HEAD
      expect(gitArgs[1], 'rev-parse --abbrev-ref HEAD'); // record original branch
      expect(gitArgs[2], 'stash --include-untracked'); // stash
      expect(gitArgs[3], 'checkout main'); // checkout base ref
      expect(gitArgs[4], 'merge --squash dartclaw/task-t1'); // squash merge
      expect(gitArgs[5], 'commit -m task(t1): Fix bug'); // commit
      expect(gitArgs[6], 'rev-parse HEAD'); // get commit SHA
      expect(gitArgs[7], 'checkout main'); // restore original branch
    });

    test('squash merge returns MergeSuccess with commit SHA', () async {
      executor = MergeExecutor(projectDir: '/project', processRunner: mockRunner);

      responses['rev-parse HEAD'] = pr('abc123\n');
      responses['rev-parse --abbrev-ref HEAD'] = pr('develop\n');
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
      executor = MergeExecutor(projectDir: '/project', processRunner: mockRunner);

      responses['rev-parse HEAD'] = pr('original-sha\n');
      responses['rev-parse --abbrev-ref HEAD'] = pr('main\n');
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
      executor = MergeExecutor(projectDir: '/project', processRunner: mockRunner);

      responses['rev-parse HEAD'] = pr('original-sha\n');
      responses['rev-parse --abbrev-ref HEAD'] = pr('main\n');
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
      executor = MergeExecutor(projectDir: '/project', processRunner: mockRunner);

      responses['rev-parse HEAD'] = pr('original-sha\n');
      responses['rev-parse --abbrev-ref HEAD'] = pr('main\n');
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
      executor = MergeExecutor(projectDir: '/project', processRunner: mockRunner);

      responses['rev-parse HEAD'] = pr('original-sha\n');
      responses['rev-parse --abbrev-ref HEAD'] = pr('main\n');
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
      executor = MergeExecutor(projectDir: '/project', processRunner: mockRunner);

      responses['rev-parse HEAD'] = pr('original-sha\n');
      responses['rev-parse --abbrev-ref HEAD'] = pr('develop\n');
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
      executor = MergeExecutor(projectDir: '/project', processRunner: mockRunner);

      responses['rev-parse HEAD'] = pr('original-sha\n');
      responses['rev-parse --abbrev-ref HEAD'] = pr('integration\n');
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
      executor = MergeExecutor(projectDir: '/project', processRunner: mockRunner);

      responses['rev-parse HEAD'] = pr('original-sha\n');
      responses['rev-parse --abbrev-ref HEAD'] = pr('main\n');
      responses['stash --include-untracked'] = pr('Saved working directory and index state\n');
      responses['checkout main'] = pr('');
      responses['merge --squash dartclaw/task-t1'] = pr('');
      responses['commit -m task(t1): Fix bug'] = pr('');
      responses['checkout main'] = pr('');
      responses['stash pop'] = pr(
        '',
        exitCode: 1,
        stderr: 'CONFLICT (content): Merge conflict in lib/main.dart\n',
      );

      await executor.merge(branch: 'dartclaw/task-t1', baseRef: 'main', taskId: 't1', taskTitle: 'Fix bug');

      final gitArgs = calls.map((c) => c.args.join(' ')).toList();
      expect(gitArgs, contains('stash pop'));
      expect(gitArgs, isNot(contains('stash drop')));
    });

    test('no stash pop when there were no uncommitted changes', () async {
      executor = MergeExecutor(projectDir: '/project', processRunner: mockRunner);

      responses['rev-parse HEAD'] = pr('original-sha\n');
      responses['rev-parse --abbrev-ref HEAD'] = pr('main\n');
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
      executor = MergeExecutor(projectDir: '/project', processRunner: mockRunner);

      responses['rev-parse HEAD'] = pr('original-sha\n');
      responses['rev-parse --abbrev-ref HEAD'] = pr('feature-x\n');
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
      executor = MergeExecutor(projectDir: '/project', processRunner: mockRunner);

      responses['rev-parse HEAD'] = pr('original-sha\n');
      responses['rev-parse --abbrev-ref HEAD'] = pr('feature-y\n');
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
      executor = MergeExecutor(projectDir: '/project', processRunner: mockRunner);

      responses['rev-parse HEAD'] = pr('deadbeef123\n');
      responses['rev-parse --abbrev-ref HEAD'] = pr('HEAD\n'); // detached
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
      executor = MergeExecutor(projectDir: '/project', processRunner: mockRunner);

      responses['rev-parse HEAD'] = pr('', exitCode: 128, stderr: 'fatal: not a git repository');

      expect(
        () => executor.merge(branch: 'dartclaw/task-t1', baseRef: 'main', taskId: 't1', taskTitle: 'Fix bug'),
        throwsA(isA<WorktreeException>()),
      );
    });

    test('git failure on checkout throws WorktreeException', () async {
      executor = MergeExecutor(projectDir: '/project', processRunner: mockRunner);

      responses['rev-parse HEAD'] = pr('original-sha\n');
      responses['rev-parse --abbrev-ref HEAD'] = pr('main\n');
      responses['stash --include-untracked'] = pr('No local changes to save\n');
      responses['checkout main'] = pr('', exitCode: 1, stderr: 'error: pathspec not found');

      expect(
        () => executor.merge(branch: 'dartclaw/task-t1', baseRef: 'main', taskId: 't1', taskTitle: 'Fix bug'),
        throwsA(isA<WorktreeException>()),
      );
    });

    test('commit message follows task(id): title format', () async {
      executor = MergeExecutor(projectDir: '/project', processRunner: mockRunner);

      responses['rev-parse HEAD'] = pr('sha\n');
      responses['rev-parse --abbrev-ref HEAD'] = pr('main\n');
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
      executor = MergeExecutor(projectDir: '/project', processRunner: mockRunner);

      responses['rev-parse HEAD'] = pr('sha\n');
      responses['rev-parse --abbrev-ref HEAD'] = pr('main\n');
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
      executor = MergeExecutor(projectDir: '/project', processRunner: mockRunner);

      responses['rev-parse HEAD'] = pr('sha\n');
      responses['rev-parse --abbrev-ref HEAD'] = pr('main\n');
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
