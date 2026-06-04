@Tags(['component'])
library;

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

WorkflowDefinition _parseDefinition(String yaml) => WorkflowDefinitionParser().parse(yaml);

Future<StreamSubscription<TaskStatusChangedEvent>> _completeQueuedTasks(
  ScenarioTaskHarness harness, {
  required FutureOr<String> Function(int index, String taskId) assistantMessageFor,
  Map<String, dynamic>? worktreeJson,
}) async {
  var queueIndex = 0;
  return harness.eventBus.on<TaskStatusChangedEvent>().where((event) => event.newStatus == TaskStatus.queued).listen((
    event,
  ) async {
    final message = await assistantMessageFor(queueIndex++, event.taskId);
    final session = await harness.sessions.getOrCreateMainSession();
    await harness.tasks.updateFields(event.taskId, sessionId: session.id, worktreeJson: worktreeJson);
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
          type: WorkflowTaskType.agent,
          prompts: ['Plan the work'],
          outputs: {'story_specs': OutputConfig(format: OutputFormat.json, schema: 'story_specs')},
        ),
      ],
    );
    final run = _makeRun(definition).copyWith(
      workflowWorktree: WorkflowWorktreeBinding(
        key: 'run-worktree',
        path: harness.tempDir.path,
        branch: 'test',
        workflowRunId: 'run-worktree',
      ),
    );
    final context = WorkflowContext(data: const {});
    await harness.workflowRuns.insert(run);

    final completionSub = await _completeQueuedTasks(
      harness,
      assistantMessageFor: (_, _) =>
          'Done.\n\n<workflow-context>{"story_specs":{"items":[{"id":"S01","title":"One","dependencies":[],"spec_path":"fis/s01-a.md"},{"id":"S02","title":"Two","dependencies":["S01"],"spec_path":"fis/s02-b.md"}]}}</workflow-context>',
    );
    addTearDown(completionSub.cancel);

    final handoff = await dispatchStep(
      definition.nodes.single,
      harness.buildExecutionContext(run: run, definition: definition, workflowContext: context),
    );

    expect(handoff, isA<StepHandoffValidationFailed>());
    expect(handoff.validationFailure?.missingPaths, ['fis/s01-a.md', 'fis/s02-b.md']);
    expect(handoff.outputs.keys.where((key) => key.startsWith('_dartclaw.internal')), isEmpty);
  });

  test('dispatchStep validates story spec artifacts against the task worktree', () async {
    final harness = await ScenarioTaskHarness.create();
    addTearDown(harness.dispose);

    final activeRoot = harness.createTempProjectRoot('active-root');
    final taskWorktree = harness.createTempProjectRoot('task-worktree');
    harness.writeProjectFile(taskWorktree, 'fis/s01-a.md', '# Story 1\n');
    harness.writeProjectFile(taskWorktree, 'fis/s02-b.md', '# Story 2\n');

    final definition = const WorkflowDefinition(
      name: 'plan-dispatch-worktree',
      description: 'Plan step worktree validation test',
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
    final run = _makeRun(definition).copyWith(
      workflowWorktree: WorkflowWorktreeBinding(
        key: 'run-worktree',
        path: activeRoot,
        branch: 'test',
        workflowRunId: 'run-worktree',
      ),
    );
    final context = WorkflowContext(data: const {});
    await harness.workflowRuns.insert(run);

    final completionSub = await _completeQueuedTasks(
      harness,
      worktreeJson: {'path': taskWorktree},
      assistantMessageFor: (_, _) =>
          'Done.\n\n<workflow-context>{"story_specs":{"items":[{"id":"S01","title":"One","dependencies":[],"spec_path":"fis/s01-a.md"},{"id":"S02","title":"Two","dependencies":["S01"],"spec_path":"fis/s02-b.md"}]}}</workflow-context>',
    );
    addTearDown(completionSub.cancel);

    final handoff = await dispatchStep(
      definition.nodes.single,
      harness.buildExecutionContext(run: run, definition: definition, workflowContext: context),
    );

    expect(handoff, isA<StepHandoffSuccess>());
    expect((handoff as StepHandoffSuccess).outputs['story_specs'], isA<Map<String, dynamic>>());
  });

  test('dispatchStep returns a validation-failed handoff for invalid story_specs contract', () async {
    final harness = await ScenarioTaskHarness.create();
    addTearDown(harness.dispose);

    final definition = const WorkflowDefinition(
      name: 'plan-dispatch-invalid-contract',
      description: 'Plan step contract validation test',
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
    final run = _makeRun(definition);
    final context = WorkflowContext(data: const {});
    await harness.workflowRuns.insert(run);

    final completionSub = await _completeQueuedTasks(
      harness,
      assistantMessageFor: (_, _) =>
          'Done.\n\n<workflow-context>{"story_specs":{"items":[{"id":"S01","title":"One","spec_path":"fis/a.md"}]}}</workflow-context>',
    );
    addTearDown(completionSub.cancel);

    final handoff = await dispatchStep(
      definition.nodes.single,
      harness.buildExecutionContext(run: run, definition: definition, workflowContext: context),
    );

    expect(handoff, isA<StepHandoffValidationFailed>());
    expect(handoff.validationFailure?.reason, contains('missing `dependencies`'));
    expect(handoff.validationFailure?.missingPaths, isEmpty);
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
          type: WorkflowTaskType.agent,
          prompts: ['Implement {{map.item.id}}'],
          mapOver: 'stories',
          maxParallel: 1,
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
    final tasks = await harness.tasks.list();
    expect(tasks.single.configJson['displayScope'], 'S01');
  });

  test('dispatchStep preserves approval outcome metadata', () async {
    final harness = await ScenarioTaskHarness.create();
    addTearDown(harness.dispose);

    final definition = const WorkflowDefinition(
      name: 'approval-dispatch',
      description: 'Approval step dispatch test',
      steps: [
        WorkflowStep(id: 'approve', name: 'Approve', type: WorkflowTaskType.approval, prompts: ['Approve the change']),
      ],
    );
    final run = _makeRun(definition);
    final context = WorkflowContext();
    await harness.workflowRuns.insert(run);

    final handoff = await dispatchStep(
      definition.nodes.single,
      harness.buildExecutionContext(run: run, definition: definition, workflowContext: context),
    );

    expect(handoff, isA<StepHandoffRetrying>());
    final retrying = handoff as StepHandoffRetrying;
    expect(retrying.outcome?.outcome, 'needsInput');
    expect(retrying.outcome?.outcomeReason, 'approval required: approve');
    expect(retrying.outputs['approve.approval.status'], 'pending');
  });

  test('dispatchStep skips map nodes when entryGate fails before queueing work', () async {
    final harness = await ScenarioTaskHarness.create();
    addTearDown(harness.dispose);

    final definition = const WorkflowDefinition(
      name: 'map-entry-gate',
      description: 'Map entry gate dispatch test',
      steps: [
        WorkflowStep(
          id: 'implement',
          name: 'Implement',
          type: WorkflowTaskType.agent,
          prompts: ['Implement {{map.item.id}}'],
          mapOver: 'stories',
          maxParallel: 1,
          entryGate: 'run_map == true',
          outputs: {'story_result': OutputConfig(format: OutputFormat.text)},
        ),
      ],
    );
    final run = _makeRun(definition);
    final context = WorkflowContext(
      data: {
        'run_map': false,
        'stories': [
          {'id': 'S01'},
        ],
      },
    );
    await harness.workflowRuns.insert(run);

    var queuedTask = false;
    final queuedSub = harness.eventBus
        .on<TaskStatusChangedEvent>()
        .where((event) => event.newStatus == TaskStatus.queued)
        .listen((_) => queuedTask = true);
    addTearDown(queuedSub.cancel);

    final handoff = await dispatchStep(
      definition.nodes.single,
      harness.buildExecutionContext(run: run, definition: definition, workflowContext: context),
    );

    expect(handoff, isA<StepHandoffSuccess>());
    expect(queuedTask, isFalse);
    expect(handoff.outputs['step.implement.outcome'], 'skipped');
    expect(handoff.outputs['step.implement.outcome.reason'], 'run_map == true');
  });

  test('dispatchStep rejects parallel groups on step gate failure before queueing work', () async {
    final harness = await ScenarioTaskHarness.create();
    addTearDown(harness.dispose);

    final definition = const WorkflowDefinition(
      name: 'parallel-gate',
      description: 'Parallel gate dispatch test',
      steps: [
        WorkflowStep(
          id: 'p1',
          name: 'P1',
          type: WorkflowTaskType.agent,
          prompts: ['Do p1'],
          parallel: true,
          gate: 'allow_parallel == true',
        ),
        WorkflowStep(id: 'p2', name: 'P2', type: WorkflowTaskType.agent, prompts: ['Do p2'], parallel: true),
      ],
    );
    final run = _makeRun(definition);
    final context = WorkflowContext(data: {'allow_parallel': false});
    await harness.workflowRuns.insert(run);

    var queuedTask = false;
    final queuedSub = harness.eventBus
        .on<TaskStatusChangedEvent>()
        .where((event) => event.newStatus == TaskStatus.queued)
        .listen((_) => queuedTask = true);
    addTearDown(queuedSub.cancel);

    final handoff = await dispatchStep(
      definition.nodes.single,
      harness.buildExecutionContext(run: run, definition: definition, workflowContext: context),
    );

    expect(handoff, isA<StepHandoffValidationFailed>());
    expect(queuedTask, isFalse);
    expect(handoff.validationFailure?.reason, contains("Gate failed for parallel step 'P1'"));
  });

  test('dispatchStep applies foreach budget fail-fast before queueing work', () async {
    final harness = await ScenarioTaskHarness.create();
    addTearDown(harness.dispose);

    final definition = _parseDefinition('''
name: foreach-budget
description: Foreach budget dispatch test
maxTokens: 1
steps:
  - id: story-pipeline
    name: Story Pipeline
    type: foreach
    map_over: stories
    steps:
      - id: implement
        name: Implement
        type: agent
        prompt: Implement {{map.item.id}}
''');
    final run = _makeRun(definition).copyWith(totalTokens: 2);
    final context = WorkflowContext(
      data: {
        'stories': [
          {'id': 'S01'},
        ],
      },
    );
    await harness.workflowRuns.insert(run);

    var queuedTask = false;
    final queuedSub = harness.eventBus
        .on<TaskStatusChangedEvent>()
        .where((event) => event.newStatus == TaskStatus.queued)
        .listen((_) => queuedTask = true);
    addTearDown(queuedSub.cancel);

    final handoff = await dispatchStep(
      definition.nodes.single,
      harness.buildExecutionContext(run: run, definition: definition, workflowContext: context),
    );

    expect(handoff, isA<StepHandoffValidationFailed>());
    expect(queuedTask, isFalse);
    expect(handoff.validationFailure?.reason, contains('Workflow budget exceeded: 2 / 1 tokens'));
  });

  test('dispatchStep reports failed loops as failed rather than needsInput', () async {
    final harness = await ScenarioTaskHarness.create();
    addTearDown(harness.dispose);

    final definition = _parseDefinition('''
name: loop-failure
description: Loop failure dispatch test
steps:
  - id: remediation-loop
    name: Remediation Loop
    type: loop
    maxIterations: 1
    exitGate: remediate.status == accepted
    steps:
      - id: remediate
        name: Remediate
        prompt: Apply fixes
        gate: can_run == true
''');
    final run = _makeRun(definition);
    final context = WorkflowContext(data: {'can_run': false});
    await harness.workflowRuns.insert(run);

    final handoff = await dispatchStep(
      definition.nodes.single,
      harness.buildExecutionContext(run: run, definition: definition, workflowContext: context),
    );

    expect(handoff, isA<StepHandoffValidationFailed>());
    expect(handoff.validationFailure?.reason, contains("Gate failed in loop 'remediation-loop'"));
    expect(handoff, isNot(isA<StepHandoffRetrying>()));
  });

  test('dispatchStep does not fire setValue when entryGate skips the step', () async {
    final harness = await ScenarioTaskHarness.create();
    addTearDown(harness.dispose);

    final definition = const WorkflowDefinition(
      name: 'set-value-entry-gate',
      description: 'setValue must not fire when the step is skipped',
      steps: [
        WorkflowStep(
          id: 'gated',
          name: 'Gated',
          type: WorkflowTaskType.agent,
          prompts: ['Will not run'],
          entryGate: 'run_gated == true',
          outputs: {'gate_state': OutputConfig(setValue: 'fired')},
        ),
      ],
    );
    final run = _makeRun(definition);
    final context = WorkflowContext(data: {'run_gated': false});
    await harness.workflowRuns.insert(run);

    var queuedTask = false;
    final queuedSub = harness.eventBus
        .on<TaskStatusChangedEvent>()
        .where((event) => event.newStatus == TaskStatus.queued)
        .listen((_) => queuedTask = true);
    addTearDown(queuedSub.cancel);

    final handoff = await dispatchStep(
      definition.nodes.single,
      harness.buildExecutionContext(run: run, definition: definition, workflowContext: context),
    );

    expect(handoff, isA<StepHandoffSuccess>());
    expect(queuedTask, isFalse);
    expect(handoff.outputs.containsKey('gate_state'), isFalse);
    expect(handoff.outputs['step.gated.outcome'], 'skipped');
  });

  test('dispatchStep does not fire setValue when the task fails', () async {
    final harness = await ScenarioTaskHarness.create();
    addTearDown(harness.dispose);

    final definition = const WorkflowDefinition(
      name: 'set-value-failure',
      description: 'setValue must not fire when the step task fails',
      steps: [
        WorkflowStep(
          id: 'failing',
          name: 'Failing',
          type: WorkflowTaskType.agent,
          prompts: ['Will fail'],
          outputs: {'gate_state': OutputConfig(setValue: 'fired')},
        ),
      ],
    );
    final run = _makeRun(definition);
    final context = WorkflowContext(data: {'gate_state': 'unchanged'});
    await harness.workflowRuns.insert(run);

    final failureSub = harness.eventBus
        .on<TaskStatusChangedEvent>()
        .where((event) => event.newStatus == TaskStatus.queued)
        .listen((event) async {
          try {
            await harness.tasks.transition(event.taskId, TaskStatus.running, trigger: 'test');
          } on StateError {
            // Task may already be running.
          }
          await harness.tasks.transition(event.taskId, TaskStatus.failed, trigger: 'test');
        });
    addTearDown(failureSub.cancel);

    final handoff = await dispatchStep(
      definition.nodes.single,
      harness.buildExecutionContext(run: run, definition: definition, workflowContext: context),
    );

    expect(handoff, isA<StepHandoffSuccess>());
    final successHandoff = handoff as StepHandoffSuccess;
    expect(successHandoff.outcome?.success, isFalse);
    expect(context['gate_state'], 'unchanged');
    expect(successHandoff.outputs.containsKey('gate_state'), isFalse);
    expect(successHandoff.outcome?.task?.status, TaskStatus.failed);
  });
}
