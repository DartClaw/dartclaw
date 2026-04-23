import 'package:dartclaw_server/src/task/merge_executor.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeGitGateway;
import 'package:test/test.dart';

void main() {
  test('fix 12 rejects untracked overlap with stash before mutation', () async {
    final fake = FakeGitGateway();
    fake
      ..initWorktree('/repo', files: {'README.md': 'base'})
      ..addUntracked('/repo', 'foo.md', content: 'local')
      ..addStash('/repo', ['foo.md']);

    final executor = MergeExecutor(projectDir: '/repo', gitPort: fake);

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

    expect(fake.stashPopAttempts, 0);
    expect(fake.events, isNot(contains('checkout main')));
    expect(fake.events, isNot(contains('stash pop')));
  });
}
