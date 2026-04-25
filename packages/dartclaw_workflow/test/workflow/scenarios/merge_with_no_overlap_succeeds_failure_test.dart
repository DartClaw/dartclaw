import 'package:dartclaw_server/src/task/merge_executor.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeGitGateway;
import 'package:test/test.dart';

// failure twin of: merge_with_untracked_overlap_test.dart
// Regression guard: an overlap check that is REMOVED would make the merge proceed
// and the stash-pop would be called. This twin verifies that a clean merge
// (stashed file does NOT overlap any incoming merge file) succeeds and stash-pop runs.
// scenario-types: loop, plain

void main() {
  test('clean merge with stash and no overlap succeeds and invokes stash-pop', () async {
    final git = FakeGitGateway();
    // Initialize repo with a README; feature branch adds a different file.
    git
      ..initWorktree('/repo', files: {'README.md': 'base'})
      ..addUntracked('/repo', 'local-notes.md', content: 'local notes');
    git.commitRef('feature', {'feature.md': 'feature content', 'README.md': 'base'});

    final executor = MergeExecutor(projectDir: '/repo', gitPort: git);

    // local-notes.md is untracked and does NOT overlap with feature.md — should succeed.
    await executor.merge(branch: 'feature', baseRef: 'main', taskId: 't1', taskTitle: 'Fix bug');

    // Stash must have been pushed (local-notes.md was stashed) and then popped.
    expect(git.stashPopAttempts, 1);
    expect(git.events, contains('stash push'));
    expect(git.events, contains('stash pop'));
  });
}
