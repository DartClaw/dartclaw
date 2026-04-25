import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        OutputConfig,
        OutputFormat,
        Task,
        TaskType,
        WorkflowContext,
        WorkflowDefinition,
        WorkflowGitArtifactsStrategy,
        WorkflowGitStrategy,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowStep;
import 'package:dartclaw_workflow/src/workflow/workflow_artifact_committer.dart';
import 'package:dartclaw_workflow/src/workflow/workflow_template_engine.dart';
import 'package:test/test.dart';

import '../scenario_test_support.dart';

// failure twin of: plan_artifacts_propagate_to_worktrees_test.dart
// Regression: if FIS paths are missing from the working tree, the commit must fail.
// scenario-types: plain, map

void main() {
  test('artifact propagation fails when plan output is missing from working tree', () async {
    final harness = await ScenarioTaskHarness.create();
    addTearDown(harness.dispose);

    // Only commit the plan file; the FIS specs are absent.
    final repo = createArtifactRepo(
      harness.tempDir.path,
      paths: const ['docs/plans/p/plan.md'],
      // fis/s01.md and fis/s02.md are deliberately missing.
    );

    final result = await maybeCommitStepArtifacts(
      ArtifactCommitPolicy(
        run: WorkflowRun(
          id: 'run-missing-fis',
          definitionName: 'scenario',
          status: WorkflowRunStatus.running,
          startedAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
        definition: const WorkflowDefinition(
          name: 'scenario',
          description: 'missing fis regression',
          project: 'proj',
          gitStrategy: WorkflowGitStrategy(artifacts: WorkflowGitArtifactsStrategy(commit: true)),
          steps: [
            WorkflowStep(
              id: 'plan',
              name: 'Plan',
              contextOutputs: ['story_specs', 'plan'],
              outputs: {
                'story_specs': OutputConfig(format: OutputFormat.json, schema: 'story-specs'),
                'plan': OutputConfig(format: OutputFormat.path),
              },
            ),
          ],
        ),
        step: const WorkflowStep(
          id: 'plan',
          name: 'Plan',
          contextOutputs: ['story_specs', 'plan'],
          outputs: {
            'story_specs': OutputConfig(format: OutputFormat.json, schema: 'story-specs'),
            'plan': OutputConfig(format: OutputFormat.path),
          },
        ),
        context: WorkflowContext(
          data: {
            'plan': 'docs/plans/p/plan.md',
            'story_specs': {
              'items': [
                // spec_path points to a file that was NOT written to the working tree.
                {'id': 'S01', 'title': 'One', 'spec_path': 'fis/s01.md'},
              ],
            },
          },
        ),
        task: Task(
          id: 'task-1',
          title: 'Plan',
          description: 'Plan',
          type: TaskType.coding,
          createdAt: DateTime(2026, 1, 1),
        ),
        projectService: null,
        dataDir: harness.tempDir.path,
        templateEngine: WorkflowTemplateEngine(),
        workflowGitPort: repo.git,
      ),
    );

    // The FIS file is missing from HEAD — the commit should report failure.
    // (plan.md was committed, but fis/s01.md was never written or staged.)
    expect(result.failed, isTrue);
    expect(result.failureReason, contains('missing at HEAD'));
    expect(result.skippedPaths.any((p) => p.contains('s01.md')), isTrue);
  });
}
