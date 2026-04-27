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

// scenario-types: plain, map

void main() {
  test('artifact propagation commits plan, technical research, and story FIS paths together', () async {
    final harness = await ScenarioTaskHarness.create();
    addTearDown(harness.dispose);

    final repo = createArtifactRepo(
      harness.tempDir.path,
      paths: const [
        'docs/plans/p/plan.md',
        'docs/plans/p/.technical-research.md',
        'docs/plans/p/fis/s01.md',
        'docs/plans/p/fis/s02.md',
      ],
    );

    final result = await maybeCommitStepArtifacts(
      ArtifactCommitPolicy(
        run: WorkflowRun(
          id: 'run-1',
          definitionName: 'scenario',
          status: WorkflowRunStatus.running,
          startedAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
        definition: const WorkflowDefinition(
          name: 'scenario',
          description: 'artifact propagation',
          project: 'proj',
          gitStrategy: WorkflowGitStrategy(artifacts: WorkflowGitArtifactsStrategy(commit: true)),
          steps: [
            WorkflowStep(
              id: 'plan',
              name: 'Plan',
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
                {'id': 'S01', 'title': 'One', 'spec_path': 'fis/s01.md'},
                {'id': 'S02', 'title': 'Two', 'spec_path': 'fis/s02.md'},
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

    expect(result.failed, isFalse);
    expect(result.committedPaths, [
      'docs/plans/p/.technical-research.md',
      'docs/plans/p/fis/s01.md',
      'docs/plans/p/fis/s02.md',
      'docs/plans/p/plan.md',
    ]);
    for (final path in result.committedPaths) {
      expect(await repo.git.pathExistsAtRef(repo.repoDir, ref: 'HEAD', path: path), isTrue);
    }
  });
}
