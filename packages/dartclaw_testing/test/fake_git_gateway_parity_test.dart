import 'dart:io';

import 'package:dartclaw_server/dartclaw_server.dart' show WorkflowGitPortProcess;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeGitGateway;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show WorkflowGitException, WorkflowGitMergeStrategy, WorkflowGitPort;
import 'package:test/test.dart';

void main() {
  group('FakeGitGateway contract parity', () {
    test('happy path commit and pathExistsAtRef agree with production', () async {
      final fake = _fakeHarness({'base.txt': 'base'});
      final production = await _processHarness({'base.txt': 'base'});
      addTearDown(production.dispose);

      final fakePreCommit = await _writeUntracked(fake.port, fake.worktreePath, 'draft.md', 'draft');
      final productionPreCommit = await _writeUntracked(production.port, production.worktreePath, 'draft.md', 'draft');

      expect(fakePreCommit, productionPreCommit);

      final fakeObserved = await _commitArtifact(fake.port, fake.worktreePath);
      final productionObserved = await _commitArtifact(production.port, production.worktreePath);

      expect(fakeObserved.changed, productionObserved.changed);
      expect(fakeObserved.exists, productionObserved.exists);
      expect(fakeObserved.absent, productionObserved.absent);
    });

    test('stash push/pop observables agree with production', () async {
      final fake = _fakeHarness({'base.txt': 'base'});
      final production = await _processHarness({'base.txt': 'base'});
      addTearDown(production.dispose);

      fake.port.addUntracked(fake.worktreePath, 'draft.md', content: 'draft');
      File('${production.worktreePath}/draft.md').writeAsStringSync('draft');

      final fakeObserved = await _stashRoundTrip(fake.port, fake.worktreePath);
      final productionObserved = await _stashRoundTrip(production.port, production.worktreePath);

      expect(fakeObserved.didStash, productionObserved.didStash);
      expect(fakeObserved.afterPushUntracked, productionObserved.afterPushUntracked);
      expect(fakeObserved.afterPopUntracked, productionObserved.afterPopUntracked);
    });

    test('merge conflict and abort observables agree with production', () async {
      final fake = _fakeHarness({'conflict.txt': 'base'});
      fake.port
        ..commitRef('feature', {'conflict.txt': 'feature'})
        ..conflictOnMerge('feature', ['conflict.txt']);

      final production = await _processHarness({'conflict.txt': 'base'});
      addTearDown(production.dispose);
      await _createConflictingBranch(production.worktreePath);

      final fakeObserved = await _mergeConflictAndAbort(fake.port, fake.worktreePath);
      final productionObserved = await _mergeConflictAndAbort(production.port, production.worktreePath);

      expect(fakeObserved.conflicts, productionObserved.conflicts);
      expect(fakeObserved.cleanAfterAbort, productionObserved.cleanAfterAbort);
    });
  });
}

Future<List<String>> _writeUntracked(WorkflowGitPort port, String worktreePath, String path, String content) async {
  if (port is FakeGitGateway) {
    port.addUntracked(worktreePath, path, content: content);
  } else {
    File('$worktreePath/$path').writeAsStringSync(content);
  }
  return port.diffNameOnly(worktreePath);
}

Future<_CommitObservation> _commitArtifact(WorkflowGitPort port, String worktreePath) async {
  if (port is FakeGitGateway) {
    port.addUntracked(worktreePath, 'plan.md', content: 'plan');
  } else {
    File('$worktreePath/plan.md').writeAsStringSync('plan');
  }
  await port.add(worktreePath, ['plan.md']);
  final changed = await port.diffNameOnly(worktreePath, cached: true);
  await port.commit(
    worktreePath,
    message: 'chore(workflow): artifacts',
    authorName: 'DartClaw Workflow',
    authorEmail: 'workflow@dartclaw.local',
  );
  return _CommitObservation(
    changed: changed,
    exists: await port.pathExistsAtRef(worktreePath, ref: 'HEAD', path: 'plan.md'),
    absent: await port.pathExistsAtRef(worktreePath, ref: 'HEAD', path: 'missing.md'),
  );
}

Future<_StashObservation> _stashRoundTrip(WorkflowGitPort port, String worktreePath) async {
  final didStash = await port.stashPush(worktreePath);
  final afterPush = (await port.status(worktreePath)).untracked;
  await port.stashPop(worktreePath);
  final afterPop = (await port.status(worktreePath)).untracked;
  return _StashObservation(didStash: didStash, afterPushUntracked: afterPush, afterPopUntracked: afterPop);
}

Future<_MergeObservation> _mergeConflictAndAbort(WorkflowGitPort port, String worktreePath) async {
  await expectLater(
    () => port.merge(worktreePath, ref: 'feature', strategy: WorkflowGitMergeStrategy.merge, message: 'merge feature'),
    throwsA(isA<WorkflowGitException>()),
  );
  final conflicts = await port.diffNameOnly(worktreePath, diffFilter: 'U');
  await port.mergeAbort(worktreePath);
  final cleanAfterAbort = (await port.status(worktreePath)).indexClean;
  return _MergeObservation(conflicts: conflicts, cleanAfterAbort: cleanAfterAbort);
}

_FakeHarness _fakeHarness(Map<String, String> files) {
  final fake = FakeGitGateway();
  fake.initWorktree('/repo', files: files);
  return _FakeHarness(port: fake, worktreePath: '/repo');
}

Future<_ProcessHarness> _processHarness(Map<String, String> files) async {
  final dir = Directory.systemTemp.createTempSync('fake_git_gateway_parity_');
  await _git(dir.path, ['init', '-q']);
  await _git(dir.path, ['checkout', '-qb', 'main']);
  for (final entry in files.entries) {
    File('${dir.path}/${entry.key}').writeAsStringSync(entry.value);
  }
  await _git(dir.path, ['add', '.']);
  await _git(dir.path, [
    '-c',
    'user.name=DartClaw Test',
    '-c',
    'user.email=test@example.com',
    'commit',
    '-qm',
    'initial',
  ]);
  return _ProcessHarness(
    port: WorkflowGitPortProcess(),
    worktreePath: dir.path,
    dispose: () => dir.delete(recursive: true),
  );
}

Future<void> _createConflictingBranch(String repoPath) async {
  await _git(repoPath, ['checkout', '-qb', 'feature']);
  File('$repoPath/conflict.txt').writeAsStringSync('feature');
  await _git(repoPath, ['add', 'conflict.txt']);
  await _git(repoPath, [
    '-c',
    'user.name=DartClaw Test',
    '-c',
    'user.email=test@example.com',
    'commit',
    '-qm',
    'feature change',
  ]);
  await _git(repoPath, ['checkout', 'main']);
  File('$repoPath/conflict.txt').writeAsStringSync('main');
  await _git(repoPath, ['add', 'conflict.txt']);
  await _git(repoPath, [
    '-c',
    'user.name=DartClaw Test',
    '-c',
    'user.email=test@example.com',
    'commit',
    '-qm',
    'main change',
  ]);
}

Future<void> _git(String workingDirectory, List<String> args) async {
  final result = await Process.run('git', args, workingDirectory: workingDirectory);
  if (result.exitCode != 0) {
    fail('git ${args.join(' ')} failed in $workingDirectory: ${result.stderr}');
  }
}

typedef _Dispose = Future<void> Function();

final class _FakeHarness {
  final FakeGitGateway port;
  final String worktreePath;

  const _FakeHarness({required this.port, required this.worktreePath});
}

final class _ProcessHarness {
  final WorkflowGitPort port;
  final String worktreePath;
  final _Dispose dispose;

  const _ProcessHarness({required this.port, required this.worktreePath, required this.dispose});
}

final class _CommitObservation {
  final List<String> changed;
  final bool exists;
  final bool absent;

  const _CommitObservation({required this.changed, required this.exists, required this.absent});
}

final class _StashObservation {
  final bool didStash;
  final List<String> afterPushUntracked;
  final List<String> afterPopUntracked;

  const _StashObservation({required this.didStash, required this.afterPushUntracked, required this.afterPopUntracked});
}

final class _MergeObservation {
  final List<String> conflicts;
  final bool cleanAfterAbort;

  const _MergeObservation({required this.conflicts, required this.cleanAfterAbort});
}
