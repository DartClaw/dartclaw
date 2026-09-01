@Tags(['component'])
library;

import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:async';
import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:test/test.dart';

import 'workflow_executor_test_support.dart' show WorkflowExecutorHarness;

void main() {
  final h = WorkflowExecutorHarness();
  setUp(h.setUp);
  tearDown(h.tearDown);

  const storySpecsOutputs = <String, dynamic>{
    'story_specs': {
      'items': [
        {'id': 'S01', 'title': 'One', 'dependencies': <String>[], 'spec_path': 'fis/s01-a.md'},
        {
          'id': 'S02',
          'title': 'Two',
          'dependencies': ['S01'],
          'spec_path': 'fis/s02-b.md',
        },
      ],
    },
  };

  WorkflowDefinition parseDefinition(String yaml) => WorkflowDefinitionParser().parse(yaml);

  Future<void> executeDefinition(WorkflowDefinition definition, WorkflowContext context, {WorkflowRun? run}) async {
    final effectiveRun = run ?? h.makeRun(definition);
    await h.repository.insert(effectiveRun);
    await h.executor.execute(effectiveRun, definition, context);
  }

  StreamSubscription<TaskStatusChangedEvent> completeQueuedTasks({
    required FutureOr<Map<String, dynamic>> Function(int index, String taskId) outputsFor,
    Map<String, dynamic>? worktreeJson,
    TaskStatus finalStatus = TaskStatus.accepted,
  }) {
    var queueIndex = 0;
    return h.eventBus.on<TaskStatusChangedEvent>().where((event) => event.newStatus == TaskStatus.queued).listen((
      event,
    ) async {
      await Future<void>.delayed(Duration.zero);
      if (worktreeJson != null) {
        await h.taskService.updateFields(event.taskId, worktreeJson: worktreeJson);
      }
      await h.completeTaskWithOutcome(
        event.taskId,
        outputs: await outputsFor(queueIndex++, event.taskId),
        finalStatus: finalStatus,
      );
    });
  }

  test('execute() fails missing story spec artifacts without sentinel output keys', () async {
    const definition = WorkflowDefinition(
      name: 'plan-execute',
      description: 'Plan step execute test',
      steps: [
        WorkflowStep(
          id: 'plan',
          name: 'Plan',
          taskType: WorkflowTaskType.agent,
          prompts: ['Plan the work'],
          outputs: {'story_specs': OutputConfig(format: OutputFormat.json, schema: 'story_specs')},
        ),
      ],
    );
    final run = h
        .makeRun(definition)
        .copyWith(
          workflowWorktree: WorkflowWorktreeBinding(
            key: 'run-worktree',
            path: h.tempDir.path,
            branch: 'test',
            workflowRunId: 'run-worktree',
          ),
        );
    final context = WorkflowContext(data: const {});

    final completionSub = completeQueuedTasks(outputsFor: (_, _) => storySpecsOutputs);
    addTearDown(completionSub.cancel);

    await executeDefinition(definition, context, run: run);
    await completionSub.cancel();

    final stored = await h.repository.getById(run.id);
    expect(stored?.status, WorkflowRunStatus.failed);
    expect(stored?.errorMessage, contains('story_specs.spec_path values that do not exist on disk'));
    expect(stored?.errorMessage, contains('fis/s01-a.md'));
    expect(stored?.errorMessage, contains('fis/s02-b.md'));
    expect(context.data.keys.where((key) => key.startsWith('_dartclaw.internal')), isEmpty);
  });

  test('execute() validates story spec artifacts against the task worktree', () async {
    final activeRoot = Directory.systemTemp.createTempSync('dartclaw_active_root_');
    final taskWorktree = Directory.systemTemp.createTempSync('dartclaw_task_worktree_');
    addTearDown(() => activeRoot.deleteSync(recursive: true));
    addTearDown(() => taskWorktree.deleteSync(recursive: true));
    File('${taskWorktree.path}/fis/s01-a.md').createSync(recursive: true);
    File('${taskWorktree.path}/fis/s02-b.md').createSync(recursive: true);

    const definition = WorkflowDefinition(
      name: 'plan-execute-worktree',
      description: 'Plan step worktree validation test',
      steps: [
        WorkflowStep(
          id: 'plan',
          name: 'Plan',
          taskType: WorkflowTaskType.agent,
          prompts: ['Plan the work'],
          outputs: {'story_specs': OutputConfig(format: OutputFormat.json, schema: 'story_specs')},
        ),
      ],
    );
    final run = h
        .makeRun(definition)
        .copyWith(
          workflowWorktree: WorkflowWorktreeBinding(
            key: 'run-worktree',
            path: activeRoot.path,
            branch: 'test',
            workflowRunId: 'run-worktree',
          ),
        );
    final context = WorkflowContext(data: const {});

    final completionSub = completeQueuedTasks(
      worktreeJson: {'path': taskWorktree.path},
      outputsFor: (_, _) => storySpecsOutputs,
    );
    addTearDown(completionSub.cancel);

    await executeDefinition(definition, context, run: run);
    await completionSub.cancel();

    final stored = await h.repository.getById(run.id);
    expect(stored?.status, WorkflowRunStatus.completed);
    expect(context['story_specs'], isA<Map<String, dynamic>>());
  });

  test('execute() routes foreach nodes through production aggregation', () async {
    const definition = WorkflowDefinition(
      name: 'foreach-execute',
      description: 'Foreach step execute test',
      steps: [
        WorkflowStep(
          id: 'story-pipeline',
          name: 'Story Pipeline',
          taskType: WorkflowTaskType.foreach,
          mapOver: 'stories',
          maxParallel: 1,
          foreachSteps: ['implement'],
          outputs: {'story_result': OutputConfig(format: OutputFormat.text)},
        ),
        WorkflowStep(
          id: 'implement',
          name: 'Implement',
          taskType: WorkflowTaskType.agent,
          prompts: ['Implement {{map.item.id}}'],
          outputs: {'story_result': OutputConfig(format: OutputFormat.text)},
        ),
      ],
    );
    final context = WorkflowContext(
      data: {
        'stories': [
          {'id': 'S01'},
        ],
      },
    );

    final completionSub = completeQueuedTasks(outputsFor: (_, _) => {'story_result': 'ok-S01'});
    addTearDown(completionSub.cancel);

    await executeDefinition(definition, context);
    await completionSub.cancel();

    // The foreach aggregate is one object per item, keyed by child step id.
    final aggregate = context['story_result'] as List<dynamic>;
    expect(aggregate, hasLength(1));
    expect((aggregate.single as Map)['implement'], containsPair('story_result', 'ok-S01'));
    final tasks = await h.taskService.list();
    expect(tasks.single.configJson['displayScope'], 'S01');
  });

  test('execute() preserves approval outcome metadata without queueing a task', () async {
    const definition = WorkflowDefinition(
      name: 'approval-execute',
      description: 'Approval step execute test',
      steps: [
        WorkflowStep(
          id: 'approve',
          name: 'Approve',
          taskType: WorkflowTaskType.approval,
          prompts: ['Approve the change'],
        ),
      ],
    );
    final context = WorkflowContext();

    await executeDefinition(definition, context);

    final stored = await h.repository.getById('run-1');
    expect(stored?.status, WorkflowRunStatus.awaitingApproval);
    expect(stored?.errorMessage, 'approval required: approve');
    expect(context['approve.approval.status'], 'pending');
    expect((await h.taskService.list()).where((task) => task.workflowRunId == 'run-1'), isEmpty);
  });

  test('execute() applies foreach budget fail-fast before queueing work', () async {
    final definition = parseDefinition('''
name: foreach-budget
description: Foreach budget execute test
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
    final run = h.makeRun(definition).copyWith(totalTokens: 2);
    final context = WorkflowContext(
      data: {
        'stories': [
          {'id': 'S01'},
        ],
      },
    );
    var queuedTask = false;
    final queuedSub = h.eventBus
        .on<TaskStatusChangedEvent>()
        .where((event) => event.newStatus == TaskStatus.queued)
        .listen((_) => queuedTask = true);
    addTearDown(queuedSub.cancel);

    await executeDefinition(definition, context, run: run);
    await queuedSub.cancel();

    final stored = await h.repository.getById(run.id);
    expect(queuedTask, isFalse);
    expect(stored?.status, WorkflowRunStatus.failed);
    expect(stored?.errorMessage, contains('Workflow budget exceeded: 2 / 1 tokens'));
  });

  test('execute() reports failed loops as failed rather than needsInput', () async {
    final definition = parseDefinition('''
name: loop-failure
description: Loop failure execute test
steps:
  - id: remediation-loop
    name: Remediation Loop
    type: loop
    maxIterations: 1
    exitGate: remediate.status == rejected
    steps:
      - id: remediate
        name: Remediate
        prompt: Apply fixes
''');
    final context = WorkflowContext();
    final sub = completeQueuedTasks(outputsFor: (_, _) => const {});
    addTearDown(sub.cancel);

    await executeDefinition(definition, context);
    await sub.cancel();

    final stored = await h.repository.getById('run-1');
    expect(stored?.status, WorkflowRunStatus.failed);
    expect(stored?.errorMessage, contains("Loop 'remediation-loop' reached max iterations"));
    expect(stored?.status, isNot(WorkflowRunStatus.awaitingApproval));
  });
}
