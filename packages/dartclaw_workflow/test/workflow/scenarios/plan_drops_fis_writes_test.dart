import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:test/test.dart';

import '../scenario_test_support.dart';

// scenario-types: multi-prompt, map

void main() {
  test('missing story spec artifacts fail through the public dispatch contract', () async {
    final harness = await ScenarioTaskHarness.create();
    addTearDown(harness.dispose);

    final definition = const WorkflowDefinition(
      name: 'plan-missing-fis',
      description: 'Scenario coverage for missing FIS outputs',
      steps: [
        WorkflowStep(
          id: 'plan',
          name: 'Plan',
          type: WorkflowTaskType.agent,
          prompts: ['Plan the work'],
          outputs: {'story_specs': OutputConfig(format: OutputFormat.json, schema: 'story_specs')},
        ),
      ],
    );
    final now = DateTime.now();
    final run = WorkflowRun(
      id: 'run-plan-missing-fis',
      definitionName: definition.name,
      status: WorkflowRunStatus.running,
      startedAt: now,
      updatedAt: now,
      currentStepIndex: 0,
      definitionJson: definition.toJson(),
      workflowWorktree: WorkflowWorktreeBinding(
        key: 'run-plan-missing-fis',
        path: harness.tempDir.path,
        branch: 'test',
        workflowRunId: 'run-plan-missing-fis',
      ),
    );
    final context = WorkflowContext(data: {});
    await harness.workflowRuns.insert(run);

    final completionSub = harness.eventBus
        .on<TaskStatusChangedEvent>()
        .where((event) => event.newStatus == TaskStatus.queued)
        .listen((event) async {
          final session = await harness.sessions.getOrCreateMainSession();
          await harness.tasks.updateFields(event.taskId, sessionId: session.id);
          await harness.messages.insertMessage(
            sessionId: session.id,
            role: 'assistant',
            content:
                'Done.\n\n<workflow-context>{"story_specs":{"items":[{"id":"S01","title":"One","dependencies":[],"spec_path":"fis/s01-a.md"},{"id":"S02","title":"Two","dependencies":["S01"],"spec_path":"fis/s02-b.md"}]}}</workflow-context>',
          );
          try {
            await harness.tasks.transition(event.taskId, TaskStatus.running, trigger: 'test');
          } on StateError {
            // Task may already be running.
          }
          try {
            await harness.tasks.transition(event.taskId, TaskStatus.review, trigger: 'test');
          } on StateError {
            // Task may already be in review.
          }
          await harness.tasks.transition(event.taskId, TaskStatus.accepted, trigger: 'test');
        });
    addTearDown(completionSub.cancel);

    final handoff = await dispatchStep(
      definition.nodes.single,
      harness.buildExecutionContext(run: run, definition: definition, workflowContext: context),
    );

    expect(handoff, isA<StepHandoffValidationFailed>());
    expect(handoff.validationFailure?.missingPaths, ['fis/s01-a.md', 'fis/s02-b.md']);
    expect(handoff.outputs.keys.where((key) => key.startsWith('_dartclaw.internal')), isEmpty);
  });
}
