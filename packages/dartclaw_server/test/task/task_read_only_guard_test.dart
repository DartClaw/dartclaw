import 'dart:io';

import 'package:dartclaw_server/src/task/task_read_only_guard.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

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
}
