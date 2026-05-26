@Tags(['component'])
library;

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show ContextExtractor, OutputConfig, OutputFormat, TaskType, WorkflowStep;
import 'package:test/test.dart';

import '../scenario_test_support.dart';

// scenario-types: inline-worktree, format-path
//
// Regression guard for the Phase-1 fix in task_executor.dart that populates
// `task.worktreeJson = {path: project.localPath, branch: ...}` immediately
// after `ensureInlineWorkflowBranchCheckedOut` succeeds. Without that fix,
// inline-mode workflows hit MissingArtifactFailure when a step emits a
// `format: path` output under the project's own local checkout, because the
// allowed-roots list excluded `project.localPath`.

void main() {
  test('inline-mode format: path output under project.localPath resolves to the claimed path', () async {
    final harness = await ScenarioTaskHarness.create();
    addTearDown(harness.dispose);

    final projectRoot = harness.createTempProjectRoot('inline-format-path');
    const claimedPath = 'docs/specs/inline/output.md';
    harness.writeProjectFile(projectRoot, claimedPath, '# inline output\n');

    final session = await harness.sessions.getOrCreateMainSession();
    await harness.messages.insertMessage(
      sessionId: session.id,
      role: 'assistant',
      content: '<workflow-context>{"artifact": "$claimedPath"}</workflow-context>',
    );

    final task = await harness.tasks.create(
      id: 'task-inline-format-path',
      title: 'Inline format: path',
      description: 'Emit a path output under project.localPath',
      type: TaskType.coding,
      autoStart: true,
    );
    // Mirror the Phase-1 fix: inline-mode tasks have worktreeJson populated
    // with the project's own local checkout path after the inline-branch
    // checkout succeeds.
    await harness.tasks.updateFields(
      task.id,
      sessionId: session.id,
      worktreeJson: {'path': projectRoot, 'branch': 'main'},
    );
    final taskWithSession = (await harness.tasks.get(task.id))!;

    final extractor = ContextExtractor(
      taskService: harness.tasks,
      messageService: harness.messages,
      dataDir: harness.tempDir.path,
      workflowStepExecutionRepository: harness.workflowStepExecutions,
    );

    final outputs = await extractor.extract(
      const WorkflowStep(
        id: 'emit-artifact',
        name: 'Emit Artifact',
        outputs: {'artifact': OutputConfig(format: OutputFormat.path)},
      ),
      taskWithSession,
    );

    expect(
      outputs['artifact'],
      claimedPath,
      reason: 'format: path output under project.localPath must round-trip without MissingArtifactFailure',
    );
  });
}
