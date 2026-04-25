// Component-tier tests for the workflow git promotion pipeline.
//
// Drives `promoteWorkflowBranchLocally` and `commitWorkflowWorktreeChangesIfNeeded`
// directly against a real-git fixture, without a codex harness. These tests
// reproduce the failure modes that previously surfaced only in the 30–75-minute
// E2E run (Issue B from the 2026-04-24 e2e-plan-and-implement log — inline-mode
// integration worktree left dirty by upstream skills) and exercise explicit
// error paths the happy-path suite didn't cover.
//
// The existing `apps/dartclaw_cli/test/commands/workflow/workflow_git_support_test.dart`
// covers "temporary integration worktree" scenarios (integration not checked
// out anywhere). This file covers the **inline** mode (integration checked out
// at `projectDir`), which is where Issue B reproduces, plus the three failure
// taxonomies of `WorkflowGitPromotionResult`.
@Tags(['component'])
library;

import 'package:dartclaw_cli/src/commands/workflow/workflow_git_support.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:test/test.dart';

void main() {
  group('promoteWorkflowBranchLocally — inline integration worktree', () {
    late WorkflowGitFixture fixture;

    setUp(() async {
      fixture = await WorkflowGitFixture.create(runId: 'run-inline');
    });

    tearDown(() => fixture.dispose());

    test('Issue B — sweeps dirty integration worktree before merging (STATE.md / LEARNINGS.md)', () async {
      // Model the inline-mode state that broke Issue B: an upstream skill
      // (e.g. andthen-plan) wrote sibling docs into the integration worktree
      // outside its declared outputs. The artifact committer did not stage
      // them, so they linger as uncommitted modifications at promote time.
      fixture.writeUncommittedIntegrationFiles({
        'docs/STATE.md': 'updated by andthen-plan\n',
        'docs/LEARNINGS.md': '- learning emitted by plan step\n',
        'docs/.technical-research.md': 'notes\n',
      });

      // Story branch writes its own files and commits them (simulating the
      // artifact committer on the story worktree). This is the only path
      // that should end up in the integration merge commit.
      await fixture.createStoryBranch('S01', committedFiles: {
        'src/story.dart': 'void story() {}\n',
      });

      final result = await promoteWorkflowBranchLocally(
        projectDir: fixture.projectDir,
        runId: fixture.runId,
        branch: fixture.storyBranch('S01'),
        integrationBranch: fixture.integrationBranch,
        strategy: 'squash',
        storyId: 'S01',
      );

      expect(result, isA<WorkflowGitPromotionSuccess>());

      final integrationLog = await fixture.logSubjects(fixture.integrationBranch);
      expect(integrationLog, anyElement(contains('sweep integration worktree before promotion')));
      expect(integrationLog, anyElement(contains('promote S01')));

      // All four artifacts must be present in the integration tree: the
      // three previously-dirty sibling docs (swept in), plus the story code.
      final tree = await fixture.rawGit(
        ['ls-tree', '-r', '--name-only', fixture.integrationBranch],
      );
      final files = (tree.stdout as String).split('\n');
      expect(files, containsAll([
        'docs/STATE.md',
        'docs/LEARNINGS.md',
        'docs/.technical-research.md',
        'src/story.dart',
      ]));
    });

    test('clean integration worktree does not generate a spurious sweep commit', () async {
      await fixture.createStoryBranch('S02', committedFiles: {
        'src/story.dart': 'void story() {}\n',
      });

      final result = await promoteWorkflowBranchLocally(
        projectDir: fixture.projectDir,
        runId: fixture.runId,
        branch: fixture.storyBranch('S02'),
        integrationBranch: fixture.integrationBranch,
        strategy: 'squash',
        storyId: 'S02',
      );

      expect(result, isA<WorkflowGitPromotionSuccess>());

      final integrationLog = await fixture.logSubjects(fixture.integrationBranch);
      expect(
        integrationLog.where((s) => s.contains('sweep integration worktree')),
        isEmpty,
        reason: 'Sweep commit should only fire when the integration worktree has pending changes.',
      );
    });

    test('sweep commit uses the canonical commit message format', () async {
      fixture.writeUncommittedIntegrationFiles({
        'docs/LEARNINGS.md': 'append\n',
      });
      await fixture.createStoryBranch('S03', committedFiles: {'src/a.dart': 'a\n'});

      await promoteWorkflowBranchLocally(
        projectDir: fixture.projectDir,
        runId: fixture.runId,
        branch: fixture.storyBranch('S03'),
        integrationBranch: fixture.integrationBranch,
        strategy: 'squash',
        storyId: 'S03',
      );

      final integrationLog = await fixture.logSubjects(fixture.integrationBranch);
      final sweepSubject = integrationLog.firstWhere(
        (s) => s.contains('sweep integration worktree'),
        orElse: () => '',
      );
      expect(sweepSubject, 'workflow(${fixture.runId}): sweep integration worktree before promotion');
    });
  });

  group('promoteWorkflowBranchLocally — failure paths', () {
    late WorkflowGitFixture fixture;

    setUp(() async {
      fixture = await WorkflowGitFixture.create(runId: 'run-fail');
    });

    tearDown(() => fixture.dispose());

    test('returns WorkflowGitPromotionConflict naming the conflicting file when merge truly conflicts', () async {
      // Integration branch modifies shared.md to value A.
      fixture.writeUncommittedIntegrationFiles({'shared.md': 'integration version A\n'});
      await fixture.commitAll(
        worktreePath: fixture.projectDir,
        message: 'integration writes shared.md',
      );

      // Story branch, forked from integration BEFORE the A commit, modifies
      // shared.md to an incompatible value B. Easiest way to model this: create
      // the story branch from the fixture's initial integration tip by using
      // the fixture helper on an empty integration, then manually reset the
      // story branch to have a divergent history.
      // Here we use a simpler setup: create story branch from current integration
      // tip (which has A), then force the conflict by amending. We instead take
      // a different approach: create a second fixture with story branched
      // earlier. To keep the test readable, rebuild from scratch.
      await fixture.dispose();
      fixture = await WorkflowGitFixture.create(
        runId: 'run-fail',
        seedFiles: {'shared.md': 'base\n'},
      );

      // Now commit A on integration.
      fixture.writeUncommittedIntegrationFiles({'shared.md': 'integration version A\n'});
      await fixture.commitAll(
        worktreePath: fixture.projectDir,
        message: 'integration sets shared.md=A',
      );

      // Create story branch off the current integration tip (which has A),
      // reset story branch back to the initial commit so its history is
      // divergent, then commit B on story.
      await fixture.createStoryBranch('S01');
      await fixture.rawGit(
        ['reset', '--hard', 'main'],
        inDir: fixture.worktreeFor('S01'),
      );
      fixture.writeUncommittedStoryFiles('S01', {'shared.md': 'story version B\n'});
      await fixture.commitAll(
        worktreePath: fixture.worktreeFor('S01'),
        message: 'story sets shared.md=B',
      );

      final result = await promoteWorkflowBranchLocally(
        projectDir: fixture.projectDir,
        runId: fixture.runId,
        branch: fixture.storyBranch('S01'),
        integrationBranch: fixture.integrationBranch,
        strategy: 'squash',
        storyId: 'S01',
      );

      expect(result, isA<WorkflowGitPromotionConflict>());
      final conflict = result as WorkflowGitPromotionConflict;
      expect(conflict.conflictingFiles, contains('shared.md'));
      expect(conflict.details, isNotEmpty);
    });

    test('returns a non-success result when the story branch does not exist', () async {
      // Documents the actual failure taxonomy: a missing story branch does not
      // produce a `WorkflowGitPromotionError` — MergeExecutor surfaces it as a
      // conflict. Locking in this behaviour so we notice if MergeExecutor's
      // failure taxonomy ever changes.
      final result = await promoteWorkflowBranchLocally(
        projectDir: fixture.projectDir,
        runId: fixture.runId,
        branch: 'dartclaw/workflow/run-fail/story-does-not-exist',
        integrationBranch: fixture.integrationBranch,
        strategy: 'squash',
        storyId: 'S99',
      );

      expect(result, isNot(isA<WorkflowGitPromotionSuccess>()));
    });

    test('returns WorkflowGitPromotionError when the integration branch does not exist', () async {
      await fixture.createStoryBranch('S04', committedFiles: {'src/a.dart': 'a\n'});

      final result = await promoteWorkflowBranchLocally(
        projectDir: fixture.projectDir,
        runId: fixture.runId,
        branch: fixture.storyBranch('S04'),
        integrationBranch: 'dartclaw/workflow/run-fail/nonexistent-integration',
        strategy: 'squash',
        storyId: 'S04',
      );

      expect(result, isA<WorkflowGitPromotionError>());
    });
  });

  group('commitWorkflowWorktreeChangesIfNeeded — edge cases not covered by happy-path suite', () {
    late WorkflowGitFixture fixture;

    setUp(() async {
      fixture = await WorkflowGitFixture.create(runId: 'run-sweep');
    });

    tearDown(() => fixture.dispose());

    test('sweeps both tracked modifications AND new untracked files in one commit', () async {
      // Dirty the integration worktree with both a modified tracked file
      // (README.md, seeded in the fixture) and a new untracked file.
      fixture.writeUncommittedIntegrationFiles({
        'README.md': 'modified\n',
        'docs/new-unttracked.md': 'brand new\n',
      });

      await commitWorkflowWorktreeChangesIfNeeded(
        projectDir: fixture.projectDir,
        branch: fixture.integrationBranch,
        commitMessage: 'workflow(test): prep',
      );

      // After the sweep the worktree should be clean and BOTH paths should be
      // committed (ls-tree includes both files).
      final status = await fixture.rawGit(['status', '--porcelain', '--untracked-files=all']);
      expect((status.stdout as String).trim(), isEmpty);

      final tree = await fixture.rawGit(
        ['ls-tree', '-r', '--name-only', fixture.integrationBranch],
      );
      final files = (tree.stdout as String).split('\n');
      expect(files, containsAll(['README.md', 'docs/new-unttracked.md']));
    });

    test('does not create a commit when the worktree is already clean', () async {
      final beforeSha = await fixture.branchSha(fixture.integrationBranch);

      await commitWorkflowWorktreeChangesIfNeeded(
        projectDir: fixture.projectDir,
        branch: fixture.integrationBranch,
        commitMessage: 'workflow(test): should not run',
      );

      final afterSha = await fixture.branchSha(fixture.integrationBranch);
      expect(afterSha, beforeSha);
    });
  });
}
