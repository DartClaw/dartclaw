// Component-tier reproducer for Issue C (2026-04-24 e2e-plan-and-implement log):
// two parallel stories touching shared scaffolding files (STATE.md,
// LEARNINGS.md, plan checklists, same test file) collide when their
// promotions hit integration in sequence.
//
// These tests exercise the failure surface **without** proposing a fix —
// they lock in the current behaviour so the upcoming agent-driven
// merge-resolve design has an executable specification to flip to green.
//
// Story promotions run serially (the repo lock inside
// `promoteWorkflowBranchLocally` enforces this), so the reproducer models
// the exact sequence that happens in production:
//
//   1. S01 promotes → integration advances.
//   2. S02 promotes. S02's story branch was forked from the pre-S01 tip, so
//      its merge base is stale. Any shared-file edits collide at this step.
@Tags(['component'])
library;

import 'package:dartclaw_cli/src/commands/workflow/workflow_git_support.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:test/test.dart';

void main() {
  group('parallel story promotion — disjoint file sets', () {
    late WorkflowGitFixture fixture;

    setUp(() async {
      fixture = await WorkflowGitFixture.create(runId: 'run-parallel-ok');
    });

    tearDown(() => fixture.dispose());

    test('two stories that modify disjoint paths both promote successfully', () async {
      await fixture.createStoryBranch(
        'S01',
        committedFiles: {'src/a.dart': 'void a() {}\n', 'test/a_test.dart': 'void aTest() {}\n'},
      );
      await fixture.createStoryBranch(
        'S02',
        committedFiles: {'src/b.dart': 'void b() {}\n', 'test/b_test.dart': 'void bTest() {}\n'},
      );

      final resultS01 = await promoteWorkflowBranchLocally(
        projectDir: fixture.projectDir,
        runId: fixture.runId,
        branch: fixture.storyBranch('S01'),
        integrationBranch: fixture.integrationBranch,
        strategy: 'squash',
        storyId: 'S01',
      );
      expect(resultS01, isA<WorkflowGitPromotionSuccess>());

      final resultS02 = await promoteWorkflowBranchLocally(
        projectDir: fixture.projectDir,
        runId: fixture.runId,
        branch: fixture.storyBranch('S02'),
        integrationBranch: fixture.integrationBranch,
        strategy: 'squash',
        storyId: 'S02',
      );
      expect(resultS02, isA<WorkflowGitPromotionSuccess>());

      // Both story deltas landed on integration.
      final tree = await fixture.rawGit(['ls-tree', '-r', '--name-only', fixture.integrationBranch]);
      final files = (tree.stdout as String).split('\n');
      expect(files, containsAll(['src/a.dart', 'test/a_test.dart', 'src/b.dart', 'test/b_test.dart']));
    });
  });

  group('parallel story promotion — shared scaffolding docs (Issue C reproducer)', () {
    late WorkflowGitFixture fixture;

    setUp(() async {
      fixture = await WorkflowGitFixture.create(
        runId: 'run-parallel-conflict',
        seedFiles: {'docs/STATE.md': '# State\n\n- phase 1: in-progress\n', 'docs/LEARNINGS.md': '# Learnings\n\n'},
      );
    });

    tearDown(() => fixture.dispose());

    test(
      'second promotion conflicts when both stories append to STATE.md (locks in current behaviour — spec for merge-resolve)',
      () async {
        // Both stories modify STATE.md — the append-only case a naive
        // mechanical strategy could arguably handle with merge=union, but
        // which git's default three-way merge treats as a conflict because
        // both sides added content at the same end-of-file anchor.
        await fixture.createStoryBranch(
          'S01',
          committedFiles: {
            'src/a.dart': 'void a() {}\n',
            'docs/STATE.md': '# State\n\n- phase 1: in-progress\n- s01: added A\n',
          },
        );
        await fixture.createStoryBranch(
          'S02',
          committedFiles: {
            'src/b.dart': 'void b() {}\n',
            'docs/STATE.md': '# State\n\n- phase 1: in-progress\n- s02: added B\n',
          },
        );

        final resultS01 = await promoteWorkflowBranchLocally(
          projectDir: fixture.projectDir,
          runId: fixture.runId,
          branch: fixture.storyBranch('S01'),
          integrationBranch: fixture.integrationBranch,
          strategy: 'squash',
          storyId: 'S01',
        );
        expect(resultS01, isA<WorkflowGitPromotionSuccess>(), reason: 'First promotion has a clean merge base.');

        final resultS02 = await promoteWorkflowBranchLocally(
          projectDir: fixture.projectDir,
          runId: fixture.runId,
          branch: fixture.storyBranch('S02'),
          integrationBranch: fixture.integrationBranch,
          strategy: 'squash',
          storyId: 'S02',
        );

        expect(resultS02, isA<WorkflowGitPromotionConflict>());
        final conflict = resultS02 as WorkflowGitPromotionConflict;
        expect(conflict.conflictingFiles, contains('docs/STATE.md'));
      },
    );

    test('second promotion conflicts when both stories flip the same STATE.md line in incompatible ways', () async {
      // Both stories modify the same line in STATE.md to different values —
      // a true semantic conflict that no mechanical strategy can resolve.
      // Agent-driven merge-resolve could look at the full story context and
      // decide which outcome is correct.
      await fixture.createStoryBranch(
        'S01',
        committedFiles: {'src/a.dart': 'void a() {}\n', 'docs/STATE.md': '# State\n\n- phase 1: complete\n'},
      );
      await fixture.createStoryBranch(
        'S02',
        committedFiles: {'src/b.dart': 'void b() {}\n', 'docs/STATE.md': '# State\n\n- phase 1: blocked\n'},
      );

      await promoteWorkflowBranchLocally(
        projectDir: fixture.projectDir,
        runId: fixture.runId,
        branch: fixture.storyBranch('S01'),
        integrationBranch: fixture.integrationBranch,
        strategy: 'squash',
        storyId: 'S01',
      );

      final resultS02 = await promoteWorkflowBranchLocally(
        projectDir: fixture.projectDir,
        runId: fixture.runId,
        branch: fixture.storyBranch('S02'),
        integrationBranch: fixture.integrationBranch,
        strategy: 'squash',
        storyId: 'S02',
      );

      expect(resultS02, isA<WorkflowGitPromotionConflict>());
      final conflict = resultS02 as WorkflowGitPromotionConflict;
      expect(conflict.conflictingFiles, contains('docs/STATE.md'));
    });

    test('second promotion conflicts when both stories added tests in the same file', () async {
      // Every AndThen story typically produces tests. If two stories add
      // tests to the same file, the mechanical merge conflicts on surrounding
      // context (e.g. a shared `}` closing brace, import lines at top).
      // Agent-driven merge-resolve is the only sane fix — union/theirs/ours
      // strategies all corrupt test code.
      await fixture.dispose();
      fixture = await WorkflowGitFixture.create(
        runId: 'run-parallel-conflict',
        seedFiles: {'test/shared_test.dart': "import 'package:test/test.dart';\n\nvoid main() {\n}\n"},
      );

      await fixture.createStoryBranch(
        'S01',
        committedFiles: {
          'test/shared_test.dart': "import 'package:test/test.dart';\n\nvoid main() {\n  test('s01', () {});\n}\n",
        },
      );
      await fixture.createStoryBranch(
        'S02',
        committedFiles: {
          'test/shared_test.dart': "import 'package:test/test.dart';\n\nvoid main() {\n  test('s02', () {});\n}\n",
        },
      );

      await promoteWorkflowBranchLocally(
        projectDir: fixture.projectDir,
        runId: fixture.runId,
        branch: fixture.storyBranch('S01'),
        integrationBranch: fixture.integrationBranch,
        strategy: 'squash',
        storyId: 'S01',
      );

      final resultS02 = await promoteWorkflowBranchLocally(
        projectDir: fixture.projectDir,
        runId: fixture.runId,
        branch: fixture.storyBranch('S02'),
        integrationBranch: fixture.integrationBranch,
        strategy: 'squash',
        storyId: 'S02',
      );

      expect(resultS02, isA<WorkflowGitPromotionConflict>());
      final conflict = resultS02 as WorkflowGitPromotionConflict;
      expect(conflict.conflictingFiles, contains('test/shared_test.dart'));
    });
  });

  group('parallel story promotion — .gitattributes merge=union mitigation (documented, not relied on)', () {
    late WorkflowGitFixture fixture;

    setUp(() async {
      // Install a .gitattributes that marks LEARNINGS.md as merge=union. This
      // is a cheap mitigation for truly append-only docs, but it silently
      // keeps both sides' lines — which would be wrong for STATE.md (status
      // flips) or plan.md (checkbox flips). The test documents what this
      // attribute DOES accomplish so anyone considering it knows the scope.
      fixture = await WorkflowGitFixture.create(
        runId: 'run-parallel-union',
        seedFiles: {'docs/LEARNINGS.md': '# Learnings\n\n'},
        gitAttributes: 'docs/LEARNINGS.md merge=union\n',
      );
    });

    tearDown(() => fixture.dispose());

    test('merge=union lets two stories each append their own learning without conflict', () async {
      await fixture.createStoryBranch(
        'S01',
        committedFiles: {'src/a.dart': 'void a() {}\n', 'docs/LEARNINGS.md': '# Learnings\n\n- S01 learning A\n'},
      );
      await fixture.createStoryBranch(
        'S02',
        committedFiles: {'src/b.dart': 'void b() {}\n', 'docs/LEARNINGS.md': '# Learnings\n\n- S02 learning B\n'},
      );

      final resultS01 = await promoteWorkflowBranchLocally(
        projectDir: fixture.projectDir,
        runId: fixture.runId,
        branch: fixture.storyBranch('S01'),
        integrationBranch: fixture.integrationBranch,
        strategy: 'squash',
        storyId: 'S01',
      );
      expect(resultS01, isA<WorkflowGitPromotionSuccess>());

      final resultS02 = await promoteWorkflowBranchLocally(
        projectDir: fixture.projectDir,
        runId: fixture.runId,
        branch: fixture.storyBranch('S02'),
        integrationBranch: fixture.integrationBranch,
        strategy: 'squash',
        storyId: 'S02',
      );

      expect(
        resultS02,
        isA<WorkflowGitPromotionSuccess>(),
        reason: 'merge=union prevents the conflict for true append-only edits.',
      );

      // Both learnings survive.
      final content = await fixture.rawGit(['show', '${fixture.integrationBranch}:docs/LEARNINGS.md']);
      final text = content.stdout as String;
      expect(text, contains('S01 learning A'));
      expect(text, contains('S02 learning B'));
    });
  });
}
