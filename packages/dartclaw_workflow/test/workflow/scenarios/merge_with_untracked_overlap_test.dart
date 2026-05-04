import 'package:dartclaw_server/src/task/merge_executor.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeGitGateway;
import 'package:test/test.dart';

// scenario-types: loop, plain

void main() {
  test('untracked overlap with stash fails before any stash-pop mutation', () async {
    final git = FakeGitGateway();
    git
      ..initWorktree('/repo', files: {'README.md': 'base'})
      ..addUntracked('/repo', 'foo.md', content: 'local')
      ..addStash('/repo', ['foo.md']);

    final executor = MergeExecutor(projectDir: '/repo', gitPort: git);

    await expectLater(
      () => executor.merge(branch: 'feature', baseRef: 'main', taskId: 't1', taskTitle: 'Fix bug'),
      throwsA(
        isA<PreMergeInvariantException>().having((error) => error.reason, 'reason', isA<UntrackedOverlap>()).having(
          (error) => (error.reason as UntrackedOverlap).paths,
          'paths',
          ['foo.md'],
        ),
      ),
    );

    expect(git.stashPopAttempts, 0);
    expect(git.events, isNot(contains('stash pop')));
  });
}
