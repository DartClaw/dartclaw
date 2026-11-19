import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowGitMergeStrategy;
import 'package:dartclaw_workflow/testing.dart';
import 'package:test/test.dart';

void main() {
  group('FakeGitGateway', () {
    test('supports stash, checkout, merge, add, and commit round trip', () async {
      final fake = FakeGitGateway();
      fake.initWorktree('/repo', files: {'README.md': 'hello'});

      fake.addUntracked('/repo', 'notes.md', content: 'draft');
      expect((await fake.status('/repo', projectDir: '/repo')).untracked, ['notes.md']);

      expect(await fake.stashPush('/repo', projectDir: '/repo'), isTrue);
      expect((await fake.status('/repo', projectDir: '/repo')).untracked, isEmpty);

      await fake.stashPop('/repo', projectDir: '/repo');
      expect(fake.stashPopAttempts, 1);
      expect((await fake.status('/repo', projectDir: '/repo')).untracked, ['notes.md']);

      await fake.add('/repo', ['notes.md'], projectDir: '/repo');
      final firstCommit = await fake.commit('/repo', projectDir: '/repo', message: 'add notes');
      expect(await fake.pathExistsAtRef('/repo', projectDir: '/repo', ref: 'HEAD', path: 'notes.md'), isTrue);

      fake.commitRef('feature', {'README.md': 'updated', 'notes.md': 'draft'});
      await fake.checkout('/repo', firstCommit.sha, projectDir: '/repo');
      await fake.merge('/repo', projectDir: '/repo', ref: 'feature', strategy: WorkflowGitMergeStrategy.squash);

      expect(await fake.diffNameOnly('/repo', projectDir: '/repo', cached: true), ['README.md']);
    });
  });
}
