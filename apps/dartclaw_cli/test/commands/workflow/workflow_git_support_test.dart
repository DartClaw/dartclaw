import 'dart:io';

import 'package:dartclaw_cli/src/commands/workflow/workflow_git_support.dart';
import 'package:path/path.dart' as p;
import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:test/test.dart';

Future<ProcessResult> _git(String workingDirectory, List<String> arguments) {
  return Process.run('git', arguments, workingDirectory: workingDirectory);
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_workflow_git_support_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
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

    final result = await publishWorkflowBranchLocally(projectDir: repoDir.path, branch: branch);

    expect(result.status, 'success');

    final remoteTracking = await _git(repoDir.path, ['rev-parse', '--verify', 'origin/$branch']);
    expect(remoteTracking.exitCode, 0);
  });
}
