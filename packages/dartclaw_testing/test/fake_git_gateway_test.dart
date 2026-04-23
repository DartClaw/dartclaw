import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeGitGateway;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowGitMergeStrategy;
import 'package:test/test.dart';

void main() {
  group('FakeGitGateway', () {
    test('supports stash, checkout, merge, add, and commit round trip', () async {
      final fake = FakeGitGateway();
      fake.initWorktree('/repo', files: {'README.md': 'hello'});

      fake.addUntracked('/repo', 'notes.md', content: 'draft');
      expect((await fake.status('/repo')).untracked, ['notes.md']);

      expect(await fake.stashPush('/repo'), isTrue);
      expect((await fake.status('/repo')).untracked, isEmpty);

      await fake.stashPop('/repo');
      expect(fake.stashPopAttempts, 1);
      expect((await fake.status('/repo')).untracked, ['notes.md']);

      await fake.add('/repo', ['notes.md']);
      final firstCommit = await fake.commit('/repo', message: 'add notes');
      expect(await fake.pathExistsAtRef('/repo', ref: 'HEAD', path: 'notes.md'), isTrue);

      fake.commitRef('feature', {'README.md': 'updated', 'notes.md': 'draft'});
      await fake.checkout('/repo', firstCommit.sha);
      await fake.merge('/repo', ref: 'feature', strategy: WorkflowGitMergeStrategy.squash);

      expect(await fake.diffNameOnly('/repo', cached: true), ['README.md']);
    });
  });
}
