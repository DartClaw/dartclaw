import 'dart:io';

import 'package:dartclaw_cli/src/commands/workflow/workflow_git_support.dart';
import 'package:path/path.dart' as p;
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
}
