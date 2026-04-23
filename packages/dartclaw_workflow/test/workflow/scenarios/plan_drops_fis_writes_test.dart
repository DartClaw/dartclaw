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
          type: 'coding',
          prompts: ['Plan the work'],
          contextOutputs: ['story_specs'],
          outputs: {'story_specs': OutputConfig(format: OutputFormat.json, schema: 'story-specs')},
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
    );
    final context = WorkflowContext(
      data: {
        'project_index': {'project_root': harness.tempDir.path},
      },
    );
    await harness.workflowRuns.insert(run);

    final completionSub = harness.eventBus
        .on<TaskStatusChangedEvent>()
        .where((event) => event.newStatus == TaskStatus.queued)
        .listen((event) async {
          final session = await harness.sessions.getOrCreateMain();
          await harness.tasks.updateFields(event.taskId, sessionId: session.id);
          await harness.messages.insertMessage(
            sessionId: session.id,
            role: 'assistant',
            content:
                'Done.\n\n<workflow-context>{"story_specs":["docs/plans/foo/fis/a.md","docs/plans/foo/fis/b.md"]}</workflow-context>',
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
    expect(handoff.validationFailure?.missingPaths, ['docs/plans/foo/fis/a.md', 'docs/plans/foo/fis/b.md']);
    expect(handoff.outputs.keys.where((key) => key.startsWith('_dartclaw.internal')), isEmpty);
  });
}
