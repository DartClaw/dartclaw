import 'dart:async';

import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:test/test.dart';

import 'scenario_test_support.dart';

WorkflowRun _makeRun(WorkflowDefinition definition) {
  final now = DateTime.now();
  return WorkflowRun(
    id: 'run-${now.microsecondsSinceEpoch}',
    definitionName: definition.name,
    status: WorkflowRunStatus.running,
    startedAt: now,
    updatedAt: now,
    currentStepIndex: 0,
    definitionJson: definition.toJson(),
  );
}

Future<StreamSubscription<TaskStatusChangedEvent>> _completeQueuedTasks(
  ScenarioTaskHarness harness, {
  required FutureOr<String> Function(int index, String taskId) assistantMessageFor,
}) async {
  var queueIndex = 0;
  return harness.eventBus.on<TaskStatusChangedEvent>().where((event) => event.newStatus == TaskStatus.queued).listen((
    event,
  ) async {
    final message = await assistantMessageFor(queueIndex++, event.taskId);
    final session = await harness.sessions.getOrCreateMain();
    await harness.tasks.updateFields(event.taskId, sessionId: session.id);
    await harness.messages.insertMessage(sessionId: session.id, role: 'assistant', content: message);
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
}

void main() {
  test('dispatchStep returns a validation-failed handoff for missing story spec artifacts', () async {
    final harness = await ScenarioTaskHarness.create();
    addTearDown(harness.dispose);

    final definition = const WorkflowDefinition(
      name: 'plan-dispatch',
      description: 'Plan step dispatch test',
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
    final run = _makeRun(definition);
    final context = WorkflowContext(
      data: {
        'project_index': {'project_root': harness.tempDir.path},
      },
    );
    await harness.workflowRuns.insert(run);

    final completionSub = await _completeQueuedTasks(
      harness,
      assistantMessageFor: (_, _) =>
          'Done.\n\n<workflow-context>{"story_specs":["docs/plans/foo/fis/a.md","docs/plans/foo/fis/b.md"]}</workflow-context>',
    );
    addTearDown(completionSub.cancel);

    final handoff = await dispatchStep(
      definition.nodes.single,
      harness.buildExecutionContext(run: run, definition: definition, workflowContext: context),
    );

    expect(handoff, isA<StepHandoffValidationFailed>());
    expect(handoff.validationFailure?.missingPaths, ['docs/plans/foo/fis/a.md', 'docs/plans/foo/fis/b.md']);
    expect(handoff.outputs.keys.where((key) => key.startsWith('_dartclaw.internal')), isEmpty);
  });

  test('dispatchStep handles map nodes through the public contract', () async {
    final harness = await ScenarioTaskHarness.create();
    addTearDown(harness.dispose);

    final definition = const WorkflowDefinition(
      name: 'map-dispatch',
      description: 'Map step dispatch test',
      steps: [
        WorkflowStep(
          id: 'implement',
          name: 'Implement',
          type: 'coding',
          prompts: ['Implement {{map.item.id}}'],
          mapOver: 'stories',
          maxParallel: 1,
          contextOutputs: ['story_result'],
          outputs: {'story_result': OutputConfig(format: OutputFormat.text)},
        ),
      ],
    );
    final run = _makeRun(definition);
    final context = WorkflowContext(
      data: {
        'stories': [
          {'id': 'S01'},
        ],
      },
    );
    await harness.workflowRuns.insert(run);

    final completionSub = await _completeQueuedTasks(
      harness,
      assistantMessageFor: (_, _) => 'Done.\n\n<workflow-context>{"story_result":"ok-S01"}</workflow-context>',
    );
    addTearDown(completionSub.cancel);

    final handoff = await dispatchStep(
      definition.nodes.single,
      harness.buildExecutionContext(run: run, definition: definition, workflowContext: context),
    );

    expect(handoff, isA<StepHandoffSuccess>());
    expect(handoff.validationFailure, isNull);
    expect(handoff.outputs['story_result'], ['ok-S01']);
  });
}
