import 'dart:io';

import 'package:dartclaw_runtime/src/task/host_worktree_git.dart' show TamperedWorktreeException;
import 'package:dartclaw_runtime/src/task/task_read_only_guard.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'host_worktree_tamper_fixture.dart';

void main() {
  late Directory repoDir;

  Future<ProcessResult> git(List<String> args) {
    return Process.run('git', args, workingDirectory: repoDir.path);
  }

  setUp(() async {
    repoDir = Directory.systemTemp.createTempSync('dartclaw_read_only_guard_test_');
    await git(['init']);
    await File(p.join(repoDir.path, 'tracked.txt')).writeAsString('initial');
    await git(['add', 'tracked.txt']);
    await git(['-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '-m', 'initial']);
  });

  tearDown(() {
    if (repoDir.existsSync()) {
      repoDir.deleteSync(recursive: true);
    }
  });

  test('returns clean when status snapshot is unchanged', () async {
    final guard = TaskReadOnlyGuard(worktreePath: repoDir.path);
    final baseline = await guard.baseline();

    final result = guard.evaluate(baseline, await guard.snapshot());

    expect(result, isA<ReadOnlyClean>());
  });

  test('detects new file mutations', () async {
    final guard = TaskReadOnlyGuard(worktreePath: repoDir.path);
    final baseline = await guard.baseline();
    await File(p.join(repoDir.path, 'new.txt')).writeAsString('new');

    final result = guard.evaluate(baseline, await guard.snapshot());

    expect(result, isA<ReadOnlyViolation>());
    expect((result as ReadOnlyViolation).mutatedPaths, ['new.txt']);
  });

  test('detects modified file mutations', () async {
    final guard = TaskReadOnlyGuard(worktreePath: repoDir.path);
    final baseline = await guard.baseline();
    await File(p.join(repoDir.path, 'tracked.txt')).writeAsString('changed');

    final result = guard.evaluate(baseline, await guard.snapshot());

    expect((result as ReadOnlyViolation).mutatedPaths, ['tracked.txt']);
  });

  test('detects deleted file mutations', () async {
    final guard = TaskReadOnlyGuard(worktreePath: repoDir.path);
    final baseline = await guard.baseline();
    await File(p.join(repoDir.path, 'tracked.txt')).delete();

    final result = guard.evaluate(baseline, await guard.snapshot());

    expect((result as ReadOnlyViolation).mutatedPaths, ['tracked.txt']);
  });

  test('formats mutation summary with path preview', () async {
    final guard = TaskReadOnlyGuard(worktreePath: repoDir.path);
    final baseline = await guard.baseline();
    await File(p.join(repoDir.path, 'new.txt')).writeAsString('new');

    expect(await guard.mutationSummary(baseline), 'Read-only task modified project files: new.txt');
  });

  group('in a task worktree', () {
    late HostWorktreeTamperFixture fixture;

    setUp(() async {
      fixture = await HostWorktreeTamperFixture.create();
    });
    tearDown(() => fixture.dispose());

    TaskReadOnlyGuard guard() => TaskReadOnlyGuard(worktreePath: fixture.worktreePath, projectDir: fixture.projectDir);

    test('reports a mutation in an untampered worktree', () async {
      final baseline = await guard().baseline();
      fixture.write('notes/leak.md');
      expect(await guard().mutationSummary(baseline), contains('notes/leak.md'));
    });

    test('baseline refuses a worktree whose gitlink names an agent gitdir', () async {
      await fixture.rewriteGitlinkToAgentGitdir();
      await expectLater(guard().baseline(), throwsA(isA<TamperedWorktreeException>()));
      expect(fixture.existingMarkers, isEmpty);
    });

    test('the mutation check refuses, rather than skips, a worktree tampered during the turn', () async {
      final baseline = await guard().baseline();
      await fixture.rewriteGitlinkToAgentGitdir();
      await expectLater(guard().mutationSummary(baseline), throwsA(isA<TamperedWorktreeException>()));
      expect(fixture.existingMarkers, isEmpty);
    });

    test('runs no config of a repository nested in an untampered worktree', () async {
      await fixture.nestRepository();
      try {
        final baseline = await guard().baseline();
        await guard().mutationSummary(baseline);
      } on TamperedWorktreeException {
        // Refusing the nested repository is the other admissible outcome.
      }
      expect(fixture.existingMarkers, isEmpty);
    });
  });
}
