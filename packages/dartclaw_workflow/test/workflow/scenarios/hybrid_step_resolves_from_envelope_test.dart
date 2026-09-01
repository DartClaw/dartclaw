@Tags(['component'])
library;

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        ContextExtractor,
        OutputConfig,
        OutputFormat,
        WorkflowStep,
        executionEnvelopeMarkerKey,
        executionEnvelopeOutputsKey,
        executionEnvelopeVersion;
import 'package:test/test.dart';

import '../scenario_test_support.dart';

// scenario-types: hybrid, plain
//
// A hybrid step declares outputs of three shapes at once — narrative text, a
// schema'd JSON value and a `format: path` claim. All three come from one
// place: the validated execution envelope. The transcript here carries a
// well-formed `<workflow-context>` block naming *different* values for every
// key, and a second block after it, so a surviving prose reader (first-block
// wins, last-block wins, or a merge) fails this test rather than passing it
// silently.

void main() {
  test('a hybrid step resolves text, json and path outputs from the envelope alone', () async {
    final harness = await ScenarioTaskHarness.create();
    addTearDown(harness.dispose);

    final projectRoot = harness.createTempProjectRoot('hybrid-envelope');
    harness.writeProjectFile(projectRoot, 'docs/from-envelope.md', '# from envelope\n');
    harness.writeProjectFile(projectRoot, 'docs/from-prose.md', '# from prose\n');

    final session = await harness.sessions.getOrCreateMainSession();
    await harness.messages.insertMessage(
      sessionId: session.id,
      role: 'assistant',
      content:
          'Drafting…\n\n'
          '<workflow-context>{"summary":"FIRST_BLOCK","confidence":1,'
          '"artifact":"docs/from-prose.md"}</workflow-context>\n'
          'Revising…\n\n'
          '<workflow-context>{"summary":"SECOND_BLOCK","confidence":2,'
          '"artifact":"docs/from-prose.md"}</workflow-context>',
    );

    const taskId = 'task-hybrid-envelope';
    await harness.tasks.create(
      id: taskId,
      title: 'Hybrid step',
      description: 'Emit narrative, json and path outputs',
      configJson: const {'needsWorktree': true},
      autoStart: true,
      workflowRunId: 'run-hybrid-envelope',
    );
    await harness.tasks.updateFields(taskId, sessionId: session.id, worktreeJson: {'path': projectRoot});
    await harness.seedWorkflowExecution(
      taskId,
      workflowRunId: 'run-hybrid-envelope',
      stepId: 'produce',
      structuredOutput: {
        executionEnvelopeOutputsKey: {'summary': 'FROM_ENVELOPE', 'confidence': 9, 'artifact': 'docs/from-envelope.md'},
        'step_outcome': {'outcome': 'succeeded', 'reason': 'produced'},
        executionEnvelopeMarkerKey: executionEnvelopeVersion,
      },
    );

    final extractor = ContextExtractor(
      taskService: harness.tasks,
      messageService: harness.messages,
      dataDir: harness.tempDir.path,
      workflowStepExecutionRepository: harness.workflowStepExecutions,
    );
    const step = WorkflowStep(
      id: 'produce',
      name: 'Produce',
      outputs: {
        'summary': OutputConfig(format: OutputFormat.text),
        'confidence': OutputConfig(format: OutputFormat.json, schema: 'non_negative_integer'),
        'artifact': OutputConfig(format: OutputFormat.path),
      },
    );

    final outputs = await extractor.extract(step, (await harness.tasks.get(taskId))!);

    expect(outputs['summary'], 'FROM_ENVELOPE');
    expect(outputs['confidence'], 9);
    expect(outputs['artifact'], 'docs/from-envelope.md');
  });
}
